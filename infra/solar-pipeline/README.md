# 태양광 센서 데이터 수집 파이프라인

```
[장치/게이트웨이] --HTTPS POST (x-api-key)--> API Gateway (REST, 사용량 계획/스로틀)
      --> Lambda (검증·정규화) --PutRecordBatch--> Data Firehose (버퍼링, JSON→Parquet)
      --> S3 s3://<project>-data-<account>-<region>/raw/telemetry/dt=YYYY-MM-DD/hour=HH/
      --> Glue 테이블(파티션 프로젝션) --> Athena
실패 레코드: s3://.../errors/   알람: CloudWatch → SNS
```

## 구성
| 경로 | 내용 |
|---|---|
| `src/ingest/app.py` | 수집 Lambda (Python 3.13) |
| `tests/test_app.py` | Lambda 단위 테스트 (`python3 -m unittest discover -s tests`) |
| `terraform/` | 인프라 전체 (S3, Glue, Firehose, Lambda, API Gateway, Athena, 알람) |
| `scripts/simulator.py` | 가짜 인버터 데이터 전송기 |
| `scripts/add-device-key.sh` | 장치별 API 키 발급 |

## 배포
Terraform 1.6+ 필요 (https://developer.hashicorp.com/terraform/install).
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # 필요시 수정
terraform init
terraform plan
terraform apply
```

## 테스트 전송
```bash
cd terraform
python3 ../scripts/simulator.py \
  --endpoint "$(terraform output -raw api_endpoint)" \
  --api-key  "$(terraform output -raw api_key_value)" \
  --devices 3 --interval 10 --batch 6
```
직접 호출:
```bash
curl -X POST "$(terraform output -raw api_endpoint)" \
  -H "x-api-key: $(terraform output -raw api_key_value)" -H "Content-Type: application/json" \
  -d '{"device_id":"inv-001","site_id":"site-a","readings":[{"ts":"2026-11-15T12:00:00+09:00","ac_power":4810,"irradiance":820}]}'
```
S3 파일은 Firehose 버퍼 시간(기본 300초, 예시 tfvars는 60초)이 지난 뒤 생성됩니다.

## API 규격
`POST /v1/telemetry`, 헤더 `x-api-key`
- `device_id` (필수, `[A-Za-z0-9_.:-]{1,64}`), `site_id` (선택), `readings` (1~500개)
- `ts`: 타임존이 포함된 ISO8601 또는 epoch 초/밀리초. 2020년 이전, 1시간 이상 미래 값은 거부
- 수치 필드: `dc_voltage`(V) `dc_current`(A) `dc_power`(W) `ac_power`(W) `panel_temp`(°C) `ambient_temp`(°C) `irradiance`(W/m²) `energy_today`(kWh), `status`(문자열)
- 그 외 필드는 `extra` 컬럼에 JSON 문자열로 보관(4KB 이하)

응답
- `200 {"accepted": n, "rejected": [{"index", "reason"}]}`: 유효한 건만 저장. 장치는 재전송하지 않음
- `400`: 요청 전체가 잘못됨. 재전송해도 같은 결과
- `403`: API 키 없음/잘못됨, `429`: 스로틀
- `503`: 저장 일시 실패. **배치 전체를 재전송** (일부 중복 가능 → 분석 시 `device_id, ts`로 중복 제거)

## Athena 쿼리 예시 (워크그룹 `solar-telemetry`)
```sql
-- 최근 1시간 장치별 평균 출력 (dt/hour 조건을 걸어야 스캔 비용이 줄어듭니다)
SELECT device_id, avg(ac_power) AS avg_ac_w, max(panel_temp) AS max_panel_c
FROM solar_telemetry.telemetry
WHERE dt = date_format(current_date, '%Y-%m-%d')
  AND ts > current_timestamp - INTERVAL '1' HOUR
GROUP BY device_id;

-- 재전송 중복 제거
SELECT * FROM (
  SELECT *, row_number() OVER (PARTITION BY device_id, ts ORDER BY ingest_ts) AS rn
  FROM solar_telemetry.telemetry WHERE dt = '2026-11-15'
) WHERE rn = 1;
```
`dt`/`hour`는 **서버 도착 시각(UTC)** 기준입니다. 장치가 지연 전송한 데이터는 측정일과 다른 파티션에 있을 수 있습니다.

## 운영 메모
- 장치별 키: `./scripts/add-device-key.sh <이름>` (Terraform state 밖에서 관리)
- 스키마에 컬럼 추가 시: `glue.tf` 컬럼 + `app.py`의 `NUMERIC_FIELDS`를 함께 수정. Firehose는 Glue 테이블 최신 버전을 읽음
- 데이터 버킷은 `force_destroy_data_bucket=false`면 데이터가 남아 있는 한 `terraform destroy`로 삭제되지 않음
