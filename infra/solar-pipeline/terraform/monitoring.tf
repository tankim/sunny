resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# 수집 Lambda 오류
resource "aws_cloudwatch_metric_alarm" "ingest_errors" {
  alarm_name          = "${var.project_name}-ingest-errors"
  alarm_description   = "Ingest Lambda is throwing errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.ingest.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# API 5xx (Firehose 저장 실패 시 503 포함)
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name        = "${var.project_name}-api-5xx"
  alarm_description = "API Gateway is returning 5xx responses"
  namespace         = "AWS/ApiGateway"
  metric_name       = "5XXError"
  dimensions = {
    ApiName = aws_api_gateway_rest_api.this.name
    Stage   = aws_api_gateway_stage.this.stage_name
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# S3 전달 지연 (가장 오래된 미전달 레코드의 나이)
resource "aws_cloudwatch_metric_alarm" "firehose_freshness" {
  alarm_name          = "${var.project_name}-firehose-freshness"
  alarm_description   = "Firehose is falling behind delivering to S3"
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.DataFreshness"
  dimensions          = { DeliveryStreamName = aws_kinesis_firehose_delivery_stream.telemetry.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.firehose_buffer_interval_seconds + 600
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Parquet 변환 실패 (스키마 불일치 등) → errors/ 경로로 떨어짐
resource "aws_cloudwatch_metric_alarm" "firehose_conversion_failed" {
  alarm_name          = "${var.project_name}-firehose-conversion-failed"
  alarm_description   = "Firehose failed to convert records to Parquet (see errors/ prefix)"
  namespace           = "AWS/Firehose"
  metric_name         = "FailedConversion.Records"
  dimensions          = { DeliveryStreamName = aws_kinesis_firehose_delivery_stream.telemetry.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
