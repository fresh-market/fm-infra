/*
 * 확정값은 기술 스택 확정 문서 4.7절에 있다.
 * 코어 버전보다 프로바이더 버전 고정이 실질적으로 더 중요하다. 리소스 스키마가 거기서 바뀐다.
 */

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  /*
   * bucket, key, region 은 backend.hcl 로 넘긴다.
   * backend 블록 안에서는 변수 보간이 안 되기 때문이다.
   * 잠금은 DynamoDB 테이블이 아니라 S3 네이티브 잠금을 쓴다.
   */
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

/*
 * Route 53 은 글로벌 서비스라 헬스체크 지표를 us-east-1 에만 올린다.
 * 그 알람 하나 때문에 프로바이더 별칭이 필요하다.
 */
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null

  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

provider "aws" {
  region = var.region

  /*
   * 프로파일을 비워 두면 기본 자격증명이나 환경변수를 쓴다.
   * 계정을 여럿 쓰는 환경에서는 tfvars 에 이름을 박아 두는 편이 안전하다.
   */
  profile = var.aws_profile != "" ? var.aws_profile : null

  /*
   * 잘못된 계정에 apply 하는 사고를 막는다.
   * 자격증명이 여기 없는 계정을 가리키면 plan 단계에서 멈춘다.
   * 비워 두면 검사하지 않는다.
   */
  allowed_account_ids = var.allowed_account_ids

  /*
   * 모든 리소스에 붙는다.
   * 비용 배분과 일괄 조회의 근거가 되고, 콘솔에서 손으로 만든 것과 구분된다.
   */
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
