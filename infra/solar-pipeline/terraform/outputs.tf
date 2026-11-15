output "api_endpoint" {
  description = "장치가 데이터를 POST할 URL"
  value       = "${aws_api_gateway_stage.this.invoke_url}/telemetry"
}

output "api_key_id" {
  description = "기본 API 키 ID"
  value       = aws_api_gateway_api_key.default.id
}

output "api_key_value" {
  description = "기본 API 키 값 (terraform output -raw api_key_value)"
  value       = aws_api_gateway_api_key.default.value
  sensitive   = true
}

output "usage_plan_id" {
  description = "장치별 API 키를 추가할 사용량 계획 ID"
  value       = aws_api_gateway_usage_plan.devices.id
}

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
