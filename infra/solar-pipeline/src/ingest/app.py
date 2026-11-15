"""태양광 센서 텔레메트리 수집 Lambda.

API Gateway(REST, Lambda 프록시) → 이 함수 → Kinesis Data Firehose(PutRecordBatch) → S3(Parquet)

요청 형식 (POST /telemetry, 헤더 x-api-key 필요):
{
  "device_id": "inv-001",
  "site_id": "site-a",                      # 선택
  "readings": [
    {"ts": "2026-11-15T10:00:00+09:00",     # ISO8601(타임존 필수) 또는 epoch 초/밀리초
     "dc_voltage": 612.3, "dc_current": 8.1, "dc_power": 4960.0, "ac_power": 4810.0,
     "panel_temp": 41.2, "ambient_temp": 18.0, "irradiance": 820.5, "energy_today": 12.3,
     "status": "OK"}
  ]
}
정의되지 않은 필드는 버리지 않고 `extra` 컬럼(JSON 문자열)에 보관한다.
"""
import base64
import json
import logging
import math
import os
import re
import time
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MAX_READINGS_PER_REQUEST = 500
MAX_FUTURE_SKEW = timedelta(hours=1)
# 장치 RTC가 초기화되면 1970년 같은 값이 들어오므로 그보다 이전은 거부
MIN_VALID_TS = datetime(2020, 1, 1, tzinfo=timezone.utc)
MAX_EXTRA_BYTES = 4096
MAX_STATUS_LEN = 64

FIREHOSE_MAX_RECORDS = 500
FIREHOSE_MAX_BATCH_BYTES = 4 * 1024 * 1024
MAX_PUT_ATTEMPTS = 3
RETRY_BASE_SECONDS = 0.1

ID_RE = re.compile(r"^[A-Za-z0-9_.:\-]{1,64}$")

# 단위: V, A, W, W, °C, °C, W/m², kWh
NUMERIC_FIELDS = (
    "dc_voltage",
    "dc_current",
    "dc_power",
    "ac_power",
    "panel_temp",
    "ambient_temp",
    "irradiance",
    "energy_today",
)
KNOWN_FIELDS = set(NUMERIC_FIELDS) | {"ts", "status"}

_client = None


class ValidationError(ValueError):
    pass


def get_client():
    global _client
    if _client is None:
        import boto3
        from botocore.config import Config

        _client = boto3.client(
            "firehose",
            config=Config(retries={"mode": "standard", "max_attempts": 3}, connect_timeout=2, read_timeout=5),
        )
    return _client


# ---------------------------------------------------------------- 파싱/검증


def parse_ts(value):
    if isinstance(value, bool):
        raise ValidationError("ts must be ISO8601 string or epoch number")
    try:
        if isinstance(value, (int, float)):
            seconds = value / 1000.0 if abs(value) > 1e11 else float(value)
            dt = datetime.fromtimestamp(seconds, tz=timezone.utc)
        elif isinstance(value, str):
            s = value.strip()
            if s.endswith(("Z", "z")):
                s = s[:-1] + "+00:00"
            dt = datetime.fromisoformat(s)
            if dt.tzinfo is None:
                raise ValidationError("ts must include a timezone offset (e.g. +09:00 or Z)")
            dt = dt.astimezone(timezone.utc)
        else:
            raise ValidationError("ts is required (ISO8601 string or epoch number)")
    except ValidationError:
        raise
    except (ValueError, OverflowError, OSError):
        raise ValidationError("ts is not a valid timestamp")
    return dt


def format_ts(dt):
    # Firehose HiveJsonSerDe 기본 파서(java.sql.Timestamp)가 읽는 형식, UTC
    return dt.strftime("%Y-%m-%d %H:%M:%S.") + "%03d" % (dt.microsecond // 1000)


def parse_number(name, value):
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValidationError("%s must be a number" % name)
    if isinstance(value, (int, float)):
        num = float(value)
    elif isinstance(value, str):
        try:
            num = float(value.strip())
        except ValueError:
            raise ValidationError("%s must be a number" % name)
    else:
        raise ValidationError("%s must be a number" % name)
    if not math.isfinite(num):
        raise ValidationError("%s must be finite" % name)
    return num


def build_record(reading, device_id, site_id, now, request_id, api_key_id):
    if not isinstance(reading, dict):
        raise ValidationError("reading must be an object")

    ts = parse_ts(reading.get("ts"))
    if ts < MIN_VALID_TS:
        raise ValidationError("ts is before 2020-01-01 (device clock not set?)")
    if ts > now + MAX_FUTURE_SKEW:
        raise ValidationError("ts is more than 1h in the future")

    status = reading.get("status")
    if status is not None:
        if not isinstance(status, str) or len(status) > MAX_STATUS_LEN:
            raise ValidationError("status must be a string up to %d chars" % MAX_STATUS_LEN)

    extra_fields = {k: v for k, v in reading.items() if k not in KNOWN_FIELDS}
    extra = None
    if extra_fields:
        extra = json.dumps(extra_fields, separators=(",", ":"), ensure_ascii=False, sort_keys=True)
        if len(extra.encode("utf-8")) > MAX_EXTRA_BYTES:
            raise ValidationError("unknown fields exceed %d bytes" % MAX_EXTRA_BYTES)

    record = {
        "device_id": device_id,
        "site_id": site_id,
        "ts": format_ts(ts),
    }
    for name in NUMERIC_FIELDS:
        record[name] = parse_number(name, reading.get(name))
    record.update(
        {
            "status": status,
            "extra": extra,
            "ingest_ts": format_ts(now),
            "request_id": request_id,
            "api_key_id": api_key_id,
        }
    )
    return record


# ---------------------------------------------------------------- Firehose


def _chunks(blobs):
    chunk, size = [], 0
    for blob in blobs:
        if chunk and (len(chunk) >= FIREHOSE_MAX_RECORDS or size + len(blob) > FIREHOSE_MAX_BATCH_BYTES):
            yield chunk
            chunk, size = [], 0
        chunk.append(blob)
        size += len(blob)
    if chunk:
        yield chunk


def put_records(records, client=None):
    """레코드를 Firehose로 전송하고, 재시도 후에도 실패한 레코드 수를 반환한다."""
    client = client or get_client()
    stream = os.environ["DELIVERY_STREAM_NAME"]
    blobs = [
        (json.dumps(r, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8") for r in records
    ]

    failed = 0
    for chunk in _chunks(blobs):
        pending = chunk
        for attempt in range(MAX_PUT_ATTEMPTS):
            try:
                resp = client.put_record_batch(
                    DeliveryStreamName=stream, Records=[{"Data": b} for b in pending]
                )
            except Exception:  # 네트워크/스로틀 등 – 전부 실패로 보고 재시도
                logger.exception("PutRecordBatch call failed (attempt %d)", attempt + 1)
            else:
                if resp.get("FailedPutCount", 0) == 0:
                    pending = []
                    break
                pending = [
                    b for b, res in zip(pending, resp.get("RequestResponses", [])) if res.get("ErrorCode")
                ]
                logger.warning("PutRecordBatch partial failure: %d records (attempt %d)", len(pending), attempt + 1)
            if attempt + 1 < MAX_PUT_ATTEMPTS:
                time.sleep(RETRY_BASE_SECONDS * (2 ** attempt))
        failed += len(pending)
    return failed


# ---------------------------------------------------------------- 핸들러


def _response(status, **body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def handler(event, context, client=None):
    ctx = event.get("requestContext") or {}
    request_id = ctx.get("requestId", "")
    api_key_id = (ctx.get("identity") or {}).get("apiKeyId")

    raw = event.get("body")
    if not raw:
        return _response(400, error="request body is empty")
    try:
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode("utf-8")
        payload = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return _response(400, error="request body is not valid JSON")
    if not isinstance(payload, dict):
        return _response(400, error="request body must be a JSON object")

    device_id = payload.get("device_id")
    if not isinstance(device_id, str) or not ID_RE.match(device_id):
        return _response(400, error="device_id is required: 1-64 chars of [A-Za-z0-9_.:-]")
    site_id = payload.get("site_id")
    if site_id is not None and (not isinstance(site_id, str) or not ID_RE.match(site_id)):
        return _response(400, error="site_id must be 1-64 chars of [A-Za-z0-9_.:-]")

    readings = payload.get("readings")
    if not isinstance(readings, list) or not readings:
        return _response(400, error="readings must be a non-empty array")
    if len(readings) > MAX_READINGS_PER_REQUEST:
        return _response(400, error="readings must contain at most %d items" % MAX_READINGS_PER_REQUEST)

    now = datetime.now(timezone.utc)
    records, rejected = [], []
    for i, reading in enumerate(readings):
        try:
            records.append(build_record(reading, device_id, site_id, now, request_id, api_key_id))
        except ValidationError as e:
            rejected.append({"index": i, "reason": str(e)})

    if not records:
        return _response(400, error="no valid readings", rejected=rejected)

    failed = put_records(records, client=client)
    if failed:
        logger.error(
            json.dumps({"msg": "firehose_put_failed", "device_id": device_id, "failed": failed, "total": len(records)})
        )
        # 장치가 배치 전체를 재전송하도록 503 – 일부 중복 가능(분석 시 device_id+ts로 중복 제거)
        return _response(503, error="temporarily unable to store readings, retry later")

    logger.info(
        json.dumps(
            {"msg": "ingested", "device_id": device_id, "accepted": len(records), "rejected": len(rejected)}
        )
    )
    return _response(200, accepted=len(records), rejected=rejected)
