# Firehose가 Parquet 변환에 사용하는 스키마이자 Athena 조회용 테이블.
# 파티션 프로젝션을 사용하므로 크롤러나 MSCK REPAIR 없이 새 파티션이 바로 조회된다.

resource "aws_glue_catalog_database" "this" {
  name = var.glue_database_name
}

resource "aws_glue_catalog_table" "telemetry" {
  name          = "telemetry"
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"              = "parquet"
    "projection.enabled"          = "true"
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "2026-11-01,NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "projection.hour.type"        = "integer"
    "projection.hour.range"       = "0,23"
    "projection.hour.digits"      = "2"
    "storage.location.template"   = "s3://${aws_s3_bucket.data.bucket}/${local.raw_prefix}dt=$${dt}/hour=$${hour}/"
  }

  # dt/hour는 Firehose 도착 시각(UTC) 기준
  partition_keys {
    name = "dt"
    type = "string"
  }
  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data.bucket}/${local.raw_prefix}"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    # Firehose로 보내는 JSON 레코드의 키가 이 컬럼과 일치해야 한다 (README 참고)
    dynamic "columns" {
      for_each = [
        { name = "device_id", type = "string", comment = "장치 ID" },
        { name = "site_id", type = "string", comment = "발전소/사이트 ID" },
        { name = "ts", type = "timestamp", comment = "측정 시각 (UTC)" },
        { name = "dc_voltage", type = "double", comment = "DC 전압 (V)" },
        { name = "dc_current", type = "double", comment = "DC 전류 (A)" },
        { name = "dc_power", type = "double", comment = "DC 출력 (W)" },
        { name = "ac_power", type = "double", comment = "AC 출력 (W)" },
        { name = "panel_temp", type = "double", comment = "패널 온도 (C)" },
        { name = "ambient_temp", type = "double", comment = "외기 온도 (C)" },
        { name = "irradiance", type = "double", comment = "일사량 (W/m2)" },
        { name = "energy_today", type = "double", comment = "금일 누적 발전량 (kWh)" },
        { name = "status", type = "string", comment = "장치 상태 코드" },
        { name = "extra", type = "string", comment = "정의되지 않은 추가 필드 (JSON)" },
        { name = "ingest_ts", type = "timestamp", comment = "수집 시각 (UTC)" },
      ]
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }
}
