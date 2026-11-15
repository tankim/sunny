import base64
import json
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "ingest"))
os.environ.setdefault("DELIVERY_STREAM_NAME", "test-stream")

import app  # noqa: E402

app.RETRY_BASE_SECONDS = 0


class FakeFirehose:
    """put_record_batch 호출을 기록하고, fail_plan 에 따라 실패를 흉내낸다."""

    def __init__(self, fail_plan=None):
        # fail_plan: 호출마다 실패시킬 레코드 인덱스 집합의 리스트, 또는 "raise"
        self.fail_plan = list(fail_plan or [])
        self.calls = []

    def put_record_batch(self, DeliveryStreamName, Records):
        self.calls.append(Records)
        plan = self.fail_plan.pop(0) if self.fail_plan else set()
        if plan == "raise":
            raise RuntimeError("boom")
        responses = [{"ErrorCode": "ServiceUnavailableException"} if i in plan else {"RecordId": str(i)}
                     for i in range(len(Records))]
        return {"FailedPutCount": len(plan), "RequestResponses": responses}

    def records(self):
        return [json.loads(r["Data"].decode()) for call in self.calls for r in call]


def event(body, b64=False):
    raw = json.dumps(body) if not isinstance(body, str) else body
    if b64:
        raw = base64.b64encode(raw.encode()).decode()
    return {
        "body": raw,
        "isBase64Encoded": b64,
        "requestContext": {"requestId": "req-1", "identity": {"apiKeyId": "key-1"}},
    }


def now_iso(delta=timedelta()):
    return (datetime.now(timezone.utc) + delta).isoformat()


class HandlerTest(unittest.TestCase):
    def call(self, body, client=None, **kw):
        client = client or FakeFirehose()
        resp = app.handler(event(body, **kw), None, client=client)
        return resp["statusCode"], json.loads(resp["body"]), client

    def test_valid_batch_is_normalized(self):
        status, body, fh = self.call({
            "device_id": "inv-001",
            "site_id": "site-a",
            "readings": [
                {"ts": "2026-11-15T10:00:00.123+09:00", "dc_voltage": 612.3, "ac_power": "4810",
                 "status": "OK", "string_count": 2},
                {"ts": 1794000000000, "irradiance": 800},
            ],
        })
        self.assertEqual(status, 200)
        self.assertEqual(body, {"accepted": 2, "rejected": []})
        r1, r2 = fh.records()
        self.assertEqual(r1["ts"], "2026-11-15 01:00:00.123")  # UTC 변환
        self.assertEqual(r1["device_id"], "inv-001")
        self.assertEqual(r1["site_id"], "site-a")
        self.assertEqual(r1["ac_power"], 4810.0)
        self.assertIsNone(r1["dc_current"])
        self.assertEqual(json.loads(r1["extra"]), {"string_count": 2})
        self.assertEqual(r1["api_key_id"], "key-1")
        self.assertEqual(r1["request_id"], "req-1")
        self.assertEqual(r2["ts"], "2026-11-06 21:20:00.000")  # epoch ms
        self.assertIsNone(r2["extra"])
        # 모든 레코드는 Glue 컬럼과 같은 키를 가진다
        self.assertEqual(set(r1), set(r2))

    def test_records_are_newline_delimited(self):
        _, _, fh = self.call({"device_id": "d", "readings": [{"ts": now_iso()}]})
        self.assertTrue(fh.calls[0][0]["Data"].endswith(b"\n"))

    def test_base64_body(self):
        status, _, _ = self.call({"device_id": "d", "readings": [{"ts": now_iso()}]}, b64=True)
        self.assertEqual(status, 200)

    def test_partial_rejection(self):
        status, body, fh = self.call({
            "device_id": "d",
            "readings": [
                {"ts": now_iso(), "dc_voltage": 1},
                {"ts": "2026-11-15T10:00:00"},                 # 타임존 없음
                {"ts": "1970-01-01T00:00:10Z"},               # 장치 시계 초기화
                {"ts": now_iso(timedelta(hours=2))},          # 미래
                {"ts": now_iso(), "dc_voltage": "abc"},
                {"ts": now_iso(), "dc_voltage": True},
                {"ts": now_iso(), "dc_voltage": float("nan")},
                {"dc_voltage": 1},                            # ts 없음
                "not-an-object",
            ],
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["accepted"], 1)
        self.assertEqual([r["index"] for r in body["rejected"]], [1, 2, 3, 4, 5, 6, 7, 8])
        self.assertEqual(len(fh.records()), 1)

    def test_all_invalid_returns_400(self):
        status, body, fh = self.call({"device_id": "d", "readings": [{"ts": "nope"}]})
        self.assertEqual(status, 400)
        self.assertEqual(len(body["rejected"]), 1)
        self.assertEqual(fh.calls, [])

    def test_request_level_validation(self):
        cases = [
            "",
            "not json",
            [1, 2],
            {"readings": [{"ts": now_iso()}]},
            {"device_id": "bad id!", "readings": [{"ts": now_iso()}]},
            {"device_id": "d", "site_id": 3, "readings": [{"ts": now_iso()}]},
            {"device_id": "d", "readings": []},
            {"device_id": "d", "readings": [{"ts": now_iso()}] * 501},
        ]
        for body in cases:
            with self.subTest(body=str(body)[:60]):
                status, _, _ = self.call(body)
                self.assertEqual(status, 400)

    def test_oversized_extra_rejected(self):
        status, body, _ = self.call({"device_id": "d", "readings": [{"ts": now_iso(), "blob": "x" * 5000}]})
        self.assertEqual(status, 400)
        self.assertIn("unknown fields", body["rejected"][0]["reason"])

    def test_retries_only_failed_records(self):
        fh = FakeFirehose(fail_plan=[{1}, set()])
        status, _, _ = self.call({"device_id": "d", "readings": [{"ts": now_iso(), "dc_voltage": i} for i in range(3)]},
                                 client=fh)
        self.assertEqual(status, 200)
        self.assertEqual(len(fh.calls), 2)
        self.assertEqual(len(fh.calls[1]), 1)
        self.assertEqual(json.loads(fh.calls[1][0]["Data"])["dc_voltage"], 1.0)

    def test_persistent_failure_returns_503(self):
        fh = FakeFirehose(fail_plan=["raise", {0}, {0}])
        status, _, _ = self.call({"device_id": "d", "readings": [{"ts": now_iso()}]}, client=fh)
        self.assertEqual(status, 503)
        self.assertEqual(len(fh.calls), app.MAX_PUT_ATTEMPTS)

    def test_chunking_respects_firehose_limits(self):
        blobs = [b"x" * 10] * 1200
        self.assertEqual([len(c) for c in app._chunks(blobs)], [500, 500, 200])
        big = [b"x" * (1024 * 1024)] * 5
        self.assertEqual([len(c) for c in app._chunks(big)], [4, 1])


if __name__ == "__main__":
    unittest.main()
