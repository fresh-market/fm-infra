/*
 * 2026-09-26 에 terraform/ 에서 여기로 옮겼다.
 *
 * destroy 가 이 자원들을 지우면 main 에 병합된 배포가 OIDC 검증 실패로 죽는다.
 * 오류가 "The web identity token provided could not be validated" 라 토큰을 가리키고,
 * 원인이 인프라 부재라는 것을 읽을 수 없다. 09-24 와 09-26 에 5회 실패했고 릴리스 둘이
 * 배포되지 않은 채 남았다. ECR 이미지 0개가 그 결과다.
 *
 * IAM 은 유지 비용이 0 이라 SSM 시크릿과 같은 근거로 파괴를 견디는 계층에 있어야 한다.
 * 그 근거는 이 파일 위 main.tf 머리와 apply.sh 2단계에 있다.
 */

/*
 * terraform/ssm.tf 와 같은 값이다. 두 구성이 같은 접두사를 가리켜야 정책이 실제 파라미터를 덮는다.
 * 양쪽이 var.project 하나에서 나오므로 어긋날 길은 project 를 다르게 주는 것뿐이다.
 */
locals {
  ssm_prefix = "/${var.project}"
}

variable "github_org" {
  description = "GitHub 조직. OIDC 신뢰 조건에 쓴다"
  type        = string
  default     = "fresh-market"
}

variable "github_org_id" {
  description = "GitHub 조직의 숫자 ID"
  type        = string
  default     = "311220188"
}

variable "github_backend_repo" {
  description = "배포를 트리거하는 저장소. 이 저장소의 main 브랜치만 배포 역할을 맡을 수 있다"
  type        = string
  default     = "fm-backend"
}

variable "github_backend_repo_id" {
  description = "fm-backend 저장소의 숫자 ID"
  type        = string
  default     = "1317781402"
}

variable "github_infra_repo" {
  description = "terraform plan 을 돌리는 저장소"
  type        = string
  default     = "fm-infra"
}

variable "github_infra_repo_id" {
  description = "fm-infra 저장소의 숫자 ID"
  type        = string
  default     = "1317795965"
}

data "aws_caller_identity" "current" {}

/*
 * GitHub Actions 에 장기 액세스 키를 두지 않는다.
 * OIDC 로 토큰을 받아 역할을 맡고, 신뢰 조건에 저장소와 브랜치를 못 박는다.
 *
 * 배포는 fm-backend 의 main 브랜치에서만 된다.
 * 다른 브랜치나 다른 저장소에서 이 역할을 맡으려 하면 STS 가 거부한다.
 */

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

/*
 * 주체를 두 형식으로 받는다.
 *
 * GitHub 이 OIDC 주체에 불변 ID 를 넣는 형식으로 옮겨 가는 중이라, 같은 저장소가
 * repo:org/repo 로도 오고 repo:org@<orgId>/repo@<repoId> 로도 온다.
 * 어느 쪽을 보내는지는 저장소의 actions/oidc/customization/sub 설정에 달려 있고 바뀔 수 있다.
 *
 * 한쪽만 적어 두면 GitHub 이 형식을 바꾸는 날 배포가 통째로 막힌다.
 * 둘 다 같은 저장소의 같은 ref 를 가리키므로 열어 두어도 넓어지는 범위가 없다.
 */
locals {
  github_roles = {
    deploy = {
      description = "deploy on merge to fm-backend main"
      subjects = [
        "repo:${var.github_org}/${var.github_backend_repo}:ref:refs/heads/main",
        "repo:${var.github_org}@${var.github_org_id}/${var.github_backend_repo}@${var.github_backend_repo_id}:ref:refs/heads/main",
      ]
    }
    tf_plan = {
      description = "terraform plan from fm-infra pull requests"
      subjects = [
        "repo:${var.github_org}/${var.github_infra_repo}:pull_request",
        "repo:${var.github_org}@${var.github_org_id}/${var.github_infra_repo}@${var.github_infra_repo_id}:pull_request",
      ]
    }
  }
}

data "aws_iam_policy_document" "github_assume" {
  for_each = local.github_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 이 조건이 없으면 GitHub 의 아무 저장소나 역할을 맡을 수 있다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.subjects
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = local.github_roles

  name               = "${var.project}-gha-${each.key}"
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.github_assume[each.key].json
}

/*
 * 배포 절차가 하는 일만 준다.
 * SSM 값 갱신, desired 조정, 대상 상태 조회, 구 인스턴스 종료다.
 * 인프라를 만들거나 지우는 권한은 주지 않는다. 그건 Terraform 이 한다.
 */
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "UpdateCurrentSha"
    effect    = "Allow"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/current-sha"]
  }

  statement {
    sid    = "RollInstances"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
    ]

    resources = ["*"]

    # 이 프로젝트의 ASG 만 건드릴 수 있다.
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/Project"
      values   = [var.project]
    }
  }

  /*
   * 구 인스턴스 종료만 태그 조건 없이 둔다.
   *
   * SetDesiredCapacity 는 ASG 이름으로 부르므로 AWS 가 그 ASG 의 태그를 조건에 채워 준다.
   * TerminateInstanceInAutoScalingGroup 은 인스턴스 ID 로 부르는 API 라 그 값이 채워지지 않고,
   * 같은 조건을 걸면 실제 호출이 AccessDenied 로 막힌다. 배포 9단계가 여기서 죽었다.
   * IAM 시뮬레이터는 태그 컨텍스트를 사람이 넣어 주므로 allowed 로 나와 차이가 드러나지 않는다.
   *
   * 대신 범위는 좁게 유지된다. 이 계정에는 ASG 가 하나뿐이고,
   * 이 역할은 fm-backend 의 main 브랜치에서만 맡을 수 있다.
   */
  statement {
    sid       = "TerminateRolledInstance"
    effect    = "Allow"
    actions   = ["autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = ["*"]
  }

  /*
   * 배치 인스턴스를 교체하는 데 쓴다.
   * 배치는 ASG 밖이라 desired 로 다룰 수 없고, SSM 으로 서비스를 재시작한다.
   * 대상을 이 프로젝트의 인스턴스로 좁힌다.
   */
  statement {
    sid       = "ReplaceBatch"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project]
    }
  }

  # 문서는 AWS 관리형이라 태그를 걸 수 없다.
  statement {
    sid       = "RunShellScriptDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "ReadCommandResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }

  /*
   * 이미지를 ECR 에 올린다. 전에는 GHCR 이라 이 권한이 필요 없었다.
   *
   * GetAuthorizationToken 만 리소스를 못 좁힌다. 계정 단위 호출이라 AWS 가 저장소 ARN 을
   * 안 받는다. 실제로 어디에 올릴 수 있는지는 아래 statement 가 정한다.
   */
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  /*
   * 지우는 권한은 주지 않는다. 오래된 이미지 정리는 수명주기 정책이 한다 (ecr.tf).
   * 저장소가 IMMUTABLE 이라 PutImage 가 기존 태그를 덮어쓰지도 못한다.
   */
  statement {
    sid    = "PushImage"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]

    /*
     * ECR ARN 을 문자열로 적는다. 이 구성은 terraform/ 의 aws_ecr_repository 를 모른다.
     * 이름이 var.project 로 결정되므로 ARN 도 결정적이다. 실제 값과 일치하는 것을 확인했다.
     * 자원이 아직 없어도 된다. 정책은 존재하지 않는 ARN 도 담을 수 있다.
     */
    resources = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.project}"]
  }

  statement {
    sid    = "ObserveOnly"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "ec2:DescribeInstances",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeLoadBalancers",
      "rds:DescribeDBInstances",
      "elasticache:DescribeReplicationGroups",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "route53:GetHealthCheckStatus",
      "cloudwatch:GetMetricStatistics",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.github["deploy"].id
  policy = data.aws_iam_policy_document.deploy.json
}

/*
 * plan 은 모든 리소스를 읽어야 실제 상태와 코드를 비교할 수 있다.
 * 서비스마다 읽기 액션 이름이 달라 직접 나열하면 계속 빠진다. AWS 관리형 정책을 쓴다.
 */
resource "aws_iam_role_policy_attachment" "tf_plan_readonly" {
  role       = aws_iam_role.github["tf_plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# 상태 파일을 읽고 쓰는 것은 잠금 때문에 필요하다. plan 이 잠금을 잡았다 푼다.
data "aws_iam_policy_document" "tf_plan_state" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::tfstate-${var.project}", "arn:aws:s3:::tfstate-${var.project}/*"]
  }
}

resource "aws_iam_role_policy" "tf_plan_state" {
  name   = "tf-plan-state"
  role   = aws_iam_role.github["tf_plan"].id
  policy = data.aws_iam_policy_document.tf_plan_state.json
}

output "github_role_arns" {
  description = "GitHub Actions 변수에 넣을 값. deploy 는 fm-backend, tf_plan 은 fm-infra"
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}
