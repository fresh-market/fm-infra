# 값의 근거는 전부 docs/system-design/ 에 있다. 여기서 새로 정하지 않는다.

/*
 * 계정을 여럿 쓰는 환경에서 어느 자격증명을 쓸지 고른다.
 * 비우면 기본 자격증명이나 환경변수를 쓴다.
 */
variable "aws_profile" {
  description = "AWS CLI 프로파일 이름"
  type        = string
  default     = ""
}

/*
 * 잘못된 계정에 apply 하는 사고를 막는 마지막 방어다.
 * 프로파일을 잘못 잡거나 환경변수가 남아 있으면 plan 단계에서 멈춘다.
 * 비워 두면 검사하지 않는다.
 */
variable "allowed_account_ids" {
  description = "이 구성을 적용해도 되는 AWS 계정 ID"
  type        = list(string)
  default     = []
}

variable "project" {
  description = "모든 리소스 이름과 SSM 경로의 접두사"
  type        = string
  default     = "freshmarket"
}

variable "region" {
  description = "AWS 리전. 범위가 단일 리전이다 (INF-01)"
  type        = string
  default     = "ap-northeast-2"
}

/*
 * AWS 는 계정마다 AZ 이름을 다른 물리 영역에 매핑한다.
 * 그래서 이 값은 이 계정 기준이며 변수로 둔다.
 */
variable "azs" {
  description = "논리 AZ 이름을 실제 AZ 에 매핑한다"
  type        = map(string)

  default = {
    a = "ap-northeast-2a"
    c = "ap-northeast-2c"
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

/*
 * 앱을 퍼블릭 서브넷에 두는 이유는 NAT Gateway 를 쓰지 않기 위해서다 (INF-09).
 * 보안은 서브넷이 아니라 보안 그룹으로 확보한다.
 */
variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷. ALB, 앱, 모니터링, 배치, 부하 생성"
  type        = map(string)

  default = {
    a = "10.0.1.0/24"
    c = "10.0.2.0/24"
  }
}

variable "private_subnet_cidrs" {
  description = "프라이빗 서브넷. RDS 와 ElastiCache"
  type        = map(string)

  default = {
    a = "10.0.11.0/24"
    c = "10.0.12.0/24"
  }
}

/*
 * 비어 있으면 Route 53 과 ACM 과 HTTPS 리스너를 만들지 않는다.
 * 도메인이 생기면 이 값만 채워 apply 한다.
 */
variable "domain_name" {
  description = "서비스 도메인. 예: api.example.com"
  type        = string
  default     = ""
}

/*
 * 역할별 인스턴스 타입. 기술 스택 확정 문서 2.6절.
 *
 * batch 는 app 과 같은 아키텍처여야 한다. 같은 컨테이너 이미지를 batch 프로필로 띄우기 때문이다.
 * t4g 계열(ARM64)로 두었을 때 배포 이미지가 amd64 라 컨테이너가
 * "exec /opt/java/openjdk/bin/java: exec format error" 로 계속 재시작했다.
 * 빌드가 러너(x86_64)에서 단일 아키텍처로 나오므로 app 이 t3 인 한 batch 도 t3 여야 한다.
 *
 * monitoring 은 관계없다. 자기 이미지를 따로 받고 전부 멀티아키를 제공한다.
 */
variable "instance_types" {
  description = "역할별 인스턴스 타입. 기술 스택 확정 문서 2.6절"
  type        = map(string)

  default = {
    app        = "t3.small"
    monitoring = "t4g.small"
    batch      = "t3.micro"
    load_test  = "t3a.small"
  }
}

variable "db_instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = "db.t4g.micro"
}

variable "cache_node_type" {
  description = "ElastiCache 노드 타입"
  type        = string
  default     = "cache.t4g.micro"
}

variable "db_name" {
  description = "데이터베이스 이름. backend 의 compose.yaml 과 같아야 한다"
  type        = string
  default     = "freshmarket"
}

variable "db_username" {
  description = "DB 마스터 사용자"
  type        = string
  default     = "freshmarket"
}

variable "github_org" {
  description = "GitHub 조직. OIDC 신뢰 조건과 GHCR 이미지 경로에 쓴다"
  type        = string
  default     = "fresh-market"
}

variable "github_backend_repo" {
  description = "배포를 트리거하는 저장소. 이 저장소의 main 브랜치만 배포 역할을 맡을 수 있다"
  type        = string
  default     = "fm-backend"
}

variable "github_infra_repo" {
  description = "terraform plan 을 돌리는 저장소"
  type        = string
  default     = "fm-infra"
}

variable "media_bucket_name" {
  description = "이미지 버킷 이름. 비우면 {project}-media 를 쓴다"
  type        = string
  default     = ""
}

/*
 * 확정값은 true 다 (기술 스택 확정 문서 2.6절).
 * 구축 초기에는 false 로 시작한다. multi_az 는 제자리 변경이라 나중에 올려도 인스턴스를 다시 만들지 않는다.
 * 장애 주입 시험(OPS-2-03 reboot with failover) 착수 전에는 반드시 true 여야 한다.
 */
variable "db_multi_az" {
  description = "RDS Multi-AZ 여부. false 인 동안은 RTO 2분과 RPO 0 목표가 성립하지 않는다"
  type        = bool
  default     = false
}

# 문서가 "트래픽이 가장 적은 시간대" 로만 정해 두었다. 실제 패턴을 보고 확정한다.
variable "db_backup_window" {
  description = "RDS 자동 백업 창 (UTC). 기본값은 KST 새벽 3시다"
  type        = string
  default     = "18:00-19:00"
}

variable "db_maintenance_window" {
  description = "RDS 유지보수 창 (UTC). 백업 창과 겹치지 않게 둔다"
  type        = string
  default     = "sun:19:30-sun:20:30"
}

# 시험 시간에만 켠다. 상시 가동 전제의 명시적 예외다.
variable "load_test_enabled" {
  description = "부하 생성 인스턴스를 띄울지 여부"
  type        = bool
  default     = false
}

# Chatbot 이 죽었을 때의 대체 경로다. 비우면 이메일 구독을 만들지 않는다.
variable "alert_email" {
  description = "critical 알림을 받을 이메일"
  type        = string
  default     = ""
}

# presigned PUT 이 브라우저에서 직접 간다. 프론트 도메인이 정해지면 좁힌다.
variable "media_cors_origins" {
  description = "이미지 업로드를 허용할 오리진"
  type        = list(string)
  default     = ["*"]
}

/*
 * 월 예산. 기술 스택 확정 문서 5.2절의 추정 총액이 근거다.
 * 프리 티어 크레딧으로 도는 동안에도 소진 속도를 봐야 하므로 값을 둔다.
 */
variable "monthly_budget_usd" {
  description = "월 예산 상한. 50, 80, 100% 와 예측 100% 에서 알린다"
  type        = string
  default     = "140"
}

/*
 * 확정값은 7일이다 (백업과복원 설계 3.1절). PITR 로 되돌릴 수 있는 범위를 정한다.
 *
 * 프리 티어 FREE 플랜은 이 값에 상한이 있어 7을 거부한다.
 *   FreeTierRestrictionError: The specified backup retention period exceeds
 *   the maximum available to free tier customers.
 *
 * 유료 플랜으로 올린 뒤 7로 되돌린다. 그 전까지는 복구 가능 범위가 그만큼 좁다.
 */
variable "db_backup_retention_days" {
  description = "RDS 자동 백업 보존 기간. 확정값은 7이고 프리 티어에서만 낮춘다"
  type        = number
  default     = 7
}

/*
 * GitHub 의 불변 식별자다. 이름을 바꿔도 변하지 않아 OIDC 주체의 새 형식에 쓰인다.
 * gh api orgs/<org> 와 gh api repos/<org>/<repo> 의 id 값이다.
 */
variable "github_org_id" {
  description = "GitHub 조직의 숫자 ID"
  type        = string
  default     = "311220188"
}

variable "github_backend_repo_id" {
  description = "fm-backend 저장소의 숫자 ID"
  type        = string
  default     = "1317781402"
}

variable "github_infra_repo_id" {
  description = "fm-infra 저장소의 숫자 ID"
  type        = string
  default     = "1317795965"
}
