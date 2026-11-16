terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 팀에서 함께 쓰려면 상태 파일을 S3에 두세요 (버킷은 미리 생성 필요)
  # backend "s3" {
  #   bucket       = "my-tfstate-bucket"
  #   key          = "solar-telemetry/terraform.tfstate"
  #   region       = "ap-northeast-2"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
