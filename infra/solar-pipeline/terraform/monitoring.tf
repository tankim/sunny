resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
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
