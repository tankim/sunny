resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.project_name}-telemetry"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_stream" "firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid = "S3Write"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*",
    ]
  }

  statement {
    sid     = "GlueSchemaRead"
    actions = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
    resources = [
      "arn:${local.partition}:glue:${var.region}:${local.account_id}:catalog",
      aws_glue_catalog_database.this.arn,
      aws_glue_catalog_table.telemetry.arn,
    ]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.project_name}-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

resource "aws_iam_role_policy" "firehose" {
  name   = "delivery"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "telemetry" {
  name        = "${var.project_name}-telemetry"
  destination = "extended_s3"

  server_side_encryption {
    enabled  = true
    key_type = "AWS_OWNED_CMK"
  }

  extended_s3_configuration {
    bucket_arn = aws_s3_bucket.data.arn
    role_arn   = aws_iam_role.firehose.arn

    # 도착 시각(UTC) 기준 Hive 스타일 파티션 → Glue 테이블의 파티션 프로젝션과 일치
    prefix              = "${local.raw_prefix}dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/telemetry/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"

    buffering_interval = var.firehose_buffer_interval_seconds
    buffering_size     = var.firehose_buffer_size_mb

    # Parquet 변환 시 필수 (Parquet 내부에서 SNAPPY 압축)
    compression_format = "UNCOMPRESSED"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_s3.name
    }

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          hive_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.this.name
        table_name    = aws_glue_catalog_table.telemetry.name
        region        = var.region
        role_arn      = aws_iam_role.firehose.arn
        version_id    = "LATEST"
      }
    }
  }

  # 역할 정책이 붙기 전에 스트림이 만들어지면 Glue 스키마 조회가 실패할 수 있음
  depends_on = [aws_iam_role_policy.firehose]
}
