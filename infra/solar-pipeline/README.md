# 태양광 센서 데이터 파이프라인 – 저장 계층

```
[수집부: MQTT 연동 예정] --PutRecord(Batch)--> Data Firehose (버퍼링, JSON→Parquet)
      --> S3 s3://<project>-data-<account>-<region>/raw/telemetry/dt=YYYY-MM-DD/hour=HH/
      --> Glue 테이블(파티션 프로젝션) --> Athena
실패 레코드: s3://.../errors/   알람: CloudWatch → SNS
```

태양광 업체가 MQTT만 제공하므로 HTTP 수집부(API Gateway + Lambda)는 제거했습니다.
현재는 Firehose 이후의 저장·조회 계층만 있고, MQTT 수집부는 이 Firehose 스트림에 연결할 예정입니다.

## 구성
| 파일 | 내용 |
|---|---|
| `terraform/s3.tf` | 데이터 버킷 (퍼블릭 차단, SSE-S3, HTTPS 강제, 수명주기) |
| `terraform/glue.tf` | Glue DB/테이블 – Parquet 변환 스키마이자 Athena 테이블 |
| `terraform/firehose.tf` | Firehose 전달 스트림 (JSON → Parquet) |
| `terraform/athena.tf` | Athena 워크그룹 (쿼리당 10GB 스캔 제한) |
| `terraform/monitoring.tf` | Firehose 전달 지연 / Parquet 변환 실패 알람 → SNS |

## 배포
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # 필요시 수정
terraform init && terraform plan && terraform apply
```

## Firehose 입력 레코드 형식
Firehose(`terraform output -raw delivery_stream_name`)에 넣는 레코드는 줄 단위 JSON 객체이며, 키가 Glue 컬럼과 일치해야 합니다.

| 키 | 타입 | 설명 |
|---|---|---|
| `device_id`, `site_id` | string | 장치 / 사이트 ID |
| `ts` | timestamp | 측정 시각, **UTC `yyyy-MM-dd HH:mm:ss.SSS`** 형식 |
| `dc_voltage` `dc_current` `dc_power` `ac_power` | double | V, A, W, W |
| `panel_temp` `ambient_temp` `irradiance` `energy_today` | double | °C, °C, W/m², kWh |
| `status` | string | 장치 상태 코드 |
| `extra` | string | 정의되지 않은 필드 (JSON 문자열) |
| `ingest_ts` | timestamp | 수집 시각, `ts`와 같은 형식 |

타임스탬프 형식이 맞지 않거나 타입이 다르면 Parquet 변환에 실패해 `errors/` 경로로 떨어지고 알람이 울립니다.

## Athena 쿼리 예시 (워크그룹 `solar-telemetry`)
```sql
SELECT device_id, avg(ac_power) AS avg_ac_w, max(panel_temp) AS max_panel_c
FROM solar_telemetry.telemetry
WHERE dt = date_format(current_date, '%Y-%m-%d')
  AND ts > current_timestamp - INTERVAL '1' HOUR
GROUP BY device_id;
```
`dt`/`hour`는 **Firehose 도착 시각(UTC)** 기준입니다. 늦게 들어온 데이터는 측정일과 다른 파티션에 있을 수 있습니다.

## 운영 메모
- 컬럼 추가 시 `glue.tf`만 수정하면 Firehose가 최신 테이블 버전을 읽습니다.
- 데이터 버킷은 `force_destroy_data_bucket=false`면 데이터가 남아 있는 한 `terraform destroy`로 삭제되지 않습니다.
