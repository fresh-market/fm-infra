/*
 * 파괴를 견디는 계층이다. destroy.sh 의 대상이 아니다.
 *
 * 상태 버킷이 여기 있는 것은 닭과 달걀이기 때문이다.
 * 상태 버킷 자체는 상태에 담을 수 없어 이 구성만 로컬 상태로 돌린다.
 *
 * 시크릿도 여기 둔다. SSM 표준 파라미터는 무료라 파괴해도 아끼는 것이 없는데,
 * 지우면 재구축 때 11개를 손으로 다시 넣어야 한다. 잃기만 한다.
 *
 * 한 번 만들면 다시 실행할 일이 없다.
 */

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # terraform/ 과 같은 계정을 가리켜야 한다. 상태 버킷이 거기 있기 때문이다.
  profile             = var.aws_profile != "" ? var.aws_profile : null
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}

variable "project" {
  description = "모든 리소스 이름의 접두사"
  type        = string
  default     = "freshmarket"
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로파일 이름. 비우면 기본 자격증명을 쓴다"
  type        = string
  default     = ""
}

variable "allowed_account_ids" {
  description = "이 구성을 적용해도 되는 AWS 계정 ID"
  type        = list(string)
  default     = []
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "tfstate-${var.project}"

  /*
   * 상태 파일을 잃으면 이미 만든 리소스를 Terraform 이 모르게 된다.
   * 전부 import 로 되찾거나 손으로 지워야 하므로 삭제를 막는다.
   */
  lifecycle {
    prevent_destroy = true
  }
}

# 잘못된 apply 로 상태가 깨졌을 때 되돌릴 유일한 수단이다.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 상태 파일에는 DB 비밀번호 같은 값이 평문으로 들어간다.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

/*
 * 시크릿 11개는 Terraform 이 관리하지 않는다. apply.sh 1단계가 CLI 로 만든다.
 *
 * Parameter Store 를 고른 이유는 그대로다 (INF-11). Secrets Manager 는 시크릿당 월 0.40 USD 이고
 * 표준 파라미터는 무료다.
 *
 * Terraform 에서 뺀 이유는 상태 파일 때문이다. 여기서 값을 넣지 않고 ignore_changes 를 걸어도
 * refresh 가 GetParameter 를 복호화까지 해서 읽어 상태에 적는다. ignore_changes 는 차이 계산에서만
 * 빼 줄 뿐 읽기를 막지 못한다. 그래서 CLI 로 실제 값을 채운 다음 apply 를 한 번만 돌려도
 * 이 로컬 상태 파일에 평문으로 남았다.
 *
 * Terraform 이 하던 일은 값이 아니라 이름의 존재 보장뿐이었다. 그건 스크립트가 더 싸게 한다.
 */

output "bucket" {
  description = "terraform/backend.hcl 의 bucket 값"
  value       = aws_s3_bucket.tfstate.id
}

/*
 * 아직 안 채운 시크릿은 output 이 아니라 CLI 로 본다.
 * 값을 참조하는 순간 sensitive 로 물들어, 이름 목록만 내보내려 해도 표시를 달아야 한다.
 * 민감하지 않은 것에 민감 표시를 달면 그 표시의 의미가 흐려진다.
 *
 *   aws ssm get-parameters-by-path --path /freshmarket --with-decryption \
 *     --query 'Parameters[?Value==`unset`].Name' --output text
 */
