#!/usr/bin/env python3
"""태양광 인버터 센서 시뮬레이터 – 가짜 측정값을 HTTP로 수집 API에 전송한다 (표준 라이브러리만 사용).

예)
  cd terraform
  python3 ../scripts/simulator.py \
      --endpoint "$(terraform output -raw api_endpoint)" \
      --api-key "$(terraform output -raw api_key_value)" \
      --devices 5 --interval 10 --batch 6

  python3 scripts/simulator.py --dry-run --devices 1 --count 1     # 전송 없이 페이로드만 출력
"""
import argparse
import json
import math
import random
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))


class Inverter:
    def __init__(self, device_id, capacity_w):
        self.device_id = device_id
        self.capacity_w = capacity_w
        self.energy_today = 0.0
        self.day = None
        self.cloud = random.uniform(0.8, 1.0)

    def read(self, now, interval_s, fault_rate):
        local = now.astimezone(KST)
        if self.day != local.date():
            self.day, self.energy_today = local.date(), 0.0

        hour = local.hour + local.minute / 60 + local.second / 3600
        sun = max(0.0, math.sin(math.pi * (hour - 6) / 12))  # 06~18시
        self.cloud = min(1.0, max(0.3, self.cloud + random.uniform(-0.05, 0.05)))
        irradiance = 1000 * sun * self.cloud

        ambient = 12 + 8 * sun + random.uniform(-0.5, 0.5)
        panel_temp = ambient + irradiance * 0.03
        derate = 1 - 0.004 * (panel_temp - 25)
        dc_power = self.capacity_w * irradiance / 1000 * derate
        status = "OK" if irradiance > 0 else "IDLE"

        if random.random() < fault_rate:
            dc_power, status = 0.0, "FAULT"

        dc_voltage = (580 + 40 * sun + random.uniform(-3, 3)) if irradiance > 5 else random.uniform(0, 5)
        dc_current = dc_power / dc_voltage if dc_voltage > 1 else 0.0
        ac_power = dc_power * 0.97
        self.energy_today += ac_power * interval_s / 3600 / 1000

        return {
            "ts": now.isoformat(timespec="milliseconds"),
            "dc_voltage": round(dc_voltage, 2),
            "dc_current": round(dc_current, 3),
            "dc_power": round(dc_power, 1),
            "ac_power": round(ac_power, 1),
            "panel_temp": round(panel_temp, 2),
            "ambient_temp": round(ambient, 2),
            "irradiance": round(irradiance, 1),
            "energy_today": round(self.energy_today, 3),
            "status": status,
        }


def post(endpoint, api_key, payload, attempts=3):
    data = json.dumps(payload).encode()
    for attempt in range(attempts):
        req = urllib.request.Request(
            endpoint, data=data, method="POST",
            headers={"Content-Type": "application/json", "x-api-key": api_key},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            if e.code < 500 and e.code != 429:
                return e.code, body  # 재시도해도 소용없는 오류
            err = "%d %s" % (e.code, body)
        except (urllib.error.URLError, TimeoutError) as e:
            err = str(e)
        wait = 2 ** attempt
        print("  ! retry in %ds: %s" % (wait, err), file=sys.stderr)
        time.sleep(wait)
    return None, err


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--endpoint")
    p.add_argument("--api-key")
    p.add_argument("--site", default="site-sim")
    p.add_argument("--devices", type=int, default=3)
    p.add_argument("--capacity-w", type=float, default=6000, help="장치당 정격 용량(W)")
    p.add_argument("--interval", type=float, default=10, help="측정 주기(초)")
    p.add_argument("--batch", type=int, default=6, help="몇 개 측정값을 모아서 보낼지")
    p.add_argument("--count", type=int, default=0, help="전송 요청 횟수(장치별), 0이면 무한")
    p.add_argument("--fault-rate", type=float, default=0.0, help="FAULT 발생 확률 (0~1)")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    if not args.dry_run and not (args.endpoint and args.api_key):
        p.error("--endpoint 와 --api-key 가 필요합니다 (또는 --dry-run)")

    devices = [Inverter("inv-%03d" % (i + 1), args.capacity_w) for i in range(args.devices)]
    buffers = {d.device_id: [] for d in devices}
    sent = {d.device_id: 0 for d in devices}

    now = datetime.now(timezone.utc)
    try:
        while True:
            if not args.dry_run:
                now = datetime.now(timezone.utc)
            for d in devices:
                buffers[d.device_id].append(d.read(now, args.interval, args.fault_rate))
                if len(buffers[d.device_id]) < args.batch:
                    continue
                payload = {"device_id": d.device_id, "site_id": args.site, "readings": buffers[d.device_id]}
                buffers[d.device_id] = []
                sent[d.device_id] += 1
                if args.dry_run:
                    print(json.dumps(payload, ensure_ascii=False, indent=2))
                else:
                    status, body = post(args.endpoint, args.api_key, payload)
                    print("%s %s -> %s %s" % (now.astimezone(KST).strftime("%H:%M:%S"), d.device_id, status, body))
            if args.count and all(n >= args.count for n in sent.values()):
                break
            if args.dry_run:
                now += timedelta(seconds=args.interval)  # 시뮬레이션 시계만 진행
            else:
                time.sleep(args.interval)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
