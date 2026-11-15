# REST API를 쓰는 이유: 장치별 API 키 + 사용량 계획(스로틀링)을 기본 제공
# (HTTP API는 API 키/사용량 계획이 없음)

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.project_name}-api"
  description = "Solar panel sensor telemetry ingestion"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "telemetry" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "telemetry"
}

resource "aws_api_gateway_method" "post_telemetry" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.telemetry.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_telemetry" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.telemetry.id
  http_method             = aws_api_gateway_method.post_telemetry.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.ingest.invoke_arn
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # API 구성이 바뀌면 새 배포를 만든다
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.telemetry,
      aws_api_gateway_method.post_telemetry,
      aws_api_gateway_integration.post_telemetry,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
  }
}

resource "aws_api_gateway_usage_plan" "devices" {
  name = "${var.project_name}-devices"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = var.throttle_rate_limit
    burst_limit = var.throttle_burst_limit
  }
}

# 초기 테스트용 키 1개. 장치/사이트별 키는 scripts/add-device-key.sh 로 추가
resource "aws_api_gateway_api_key" "default" {
  name    = "${var.project_name}-default"
  enabled = true
}

resource "aws_api_gateway_usage_plan_key" "default" {
  key_id        = aws_api_gateway_api_key.default.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.devices.id
}
