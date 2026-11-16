variable "region" {
  description = "배포 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름 접두사 (소문자, 숫자, 하이픈)"
  type        = string
  default     = "solar-telemetry"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name은 3-32자의 소문자, 숫자, 하이픈이어야 합니다."
  }
}

variable "glue_database_name" {
  description = "Glue/Athena 데이터베이스 이름 (소문자, 언더스코어)"
  type        = string
  default     = "solar_telemetry"
}

variable "firehose_buffer_interval_seconds" {
  description = "Firehose가 S3에 파일을 쓰기 전 최대 대기 시간"
  type        = number
  default     = 300

  validation {
    condition     = var.firehose_buffer_interval_seconds >= 60 && var.firehose_buffer_interval_seconds <= 900
    error_message = "60~900초 사이여야 합니다."
  }
}

variable "firehose_buffer_size_mb" {
  description = "Firehose 버퍼 크기 (Parquet 변환 사용 시 최소 64MB)"
  type        = number
  default     = 128

  validation {
    condition     = var.firehose_buffer_size_mb >= 64 && var.firehose_buffer_size_mb <= 128
    error_message = "64~128MB 사이여야 합니다."
  }
}

variable "raw_transition_to_ia_days" {
  description = "원본 데이터를 S3 Standard-IA로 옮기는 시점(일)"
  type        = number
  default     = 30
}

variable "raw_transition_to_glacier_days" {
  description = "원본 데이터를 Glacier Instant Retrieval로 옮기는 시점(일)"
  type        = number
  default     = 180
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보관 기간(일)"
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = "알람을 받을 이메일 (비우면 구독 생성 안 함)"
  type        = string
  default     = ""
}

variable "force_destroy_data_bucket" {
  description = "true면 terraform destroy 시 데이터가 있어도 버킷 삭제 (운영 환경에서는 false 유지)"
  type        = bool
  default     = false
}
