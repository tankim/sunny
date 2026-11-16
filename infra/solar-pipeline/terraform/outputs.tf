output "data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "delivery_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.telemetry.name
}

output "glue_database" {
  value = aws_glue_catalog_database.this.name
}

output "athena_workgroup" {
  value = aws_athena_workgroup.this.name
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}
