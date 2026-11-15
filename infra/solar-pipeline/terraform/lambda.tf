data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.module}/../src/ingest"
  output_path = "${path.module}/build/ingest.zip"
  excludes    = ["__pycache__", "**/__pycache__/**", "**/*.pyc"]
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.project_name}-ingest"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "FirehosePut"
    actions   = ["firehose:PutRecordBatch"]
    resources = [aws_kinesis_firehose_delivery_stream.telemetry.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.project_name}-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${var.project_name}-ingest"
  role             = aws_iam_role.ingest.arn
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  handler          = "app.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 15

  environment {
    variables = {
      DELIVERY_STREAM_NAME = aws_kinesis_firehose_delivery_stream.telemetry.name
      LOG_LEVEL            = "INFO"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.ingest.name
  }

  depends_on = [aws_iam_role_policy.ingest]
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/telemetry"
}
