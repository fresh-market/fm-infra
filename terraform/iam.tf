/*
 * 인스턴스에는 액세스 키를 두지 않는다 (INF-11-07).
 * 전부 인스턴스 프로파일로 받고, 운영 접근도 22번이 아니라 SSM Session Manager 로 한다 (INF-12).
 *
 * GitHub Actions 에도 장기 키를 두지 않는다. OIDC 로 역할을 맡는다.
 */

data "aws_caller_identity" "current" {}

locals {
  media_bucket = var.media_bucket_name != "" ? var.media_bucket_name : "${var.project}-media"

  # 역할별로 필요한 것이 달라 하나로 묶지 않는다
  instance_roles = {
    app        = "app. read parameters and access media bucket"
    monitoring = "monitoring. read parameters and CloudWatch metrics"
    batch      = "batch. read parameters"
    loadtest   = "load test. read parameters"
  }
}

resource "aws_iam_role" "instance" {
  for_each = local.instance_roles

  name        = "${var.project}-${each.key}"
  description = each.value

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM Session Manager 접속과 에이전트 동작에 필요하다.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = local.instance_roles

  role       = aws_iam_role.instance[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  for_each = local.instance_roles

  name = "${var.project}-${each.key}"
  role = aws_iam_role.instance[each.key].name
}

/*
 * user-data 가 current-sha 와 db-endpoint 를 읽는다.
 * SecureString 은 복호화가 필요해 기본 KMS 키 사용 권한을 함께 준다.
 */
data "aws_iam_policy_document" "read_params" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:${var.region}:${data.aws_caller_identity.current.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

/*
 * 부하 생성기만 범위를 좁힌다. 파라미터 두 개만 읽는다.
 *
 *   jwt-signing-key       mint-tokens.py 가 앱과 같은 키로 2만 장을 찍는다
 *   prometheus-endpoint   결과를 remote write 로 밀 주소다
 *
 * 시나리오를 받는 데는 자격증명이 필요 없다. fm-backend 가 public 이라 그냥 클론된다.
 *
 * 토큰을 밖에서 만들어 넣지 않는 이유는 그것이 3.7 MB 이고 실제 서명된 자격증명이기 때문이다.
 * 현장에서 찍으면 네트워크를 건너지 않고 시험이 끝나면 인스턴스와 함께 사라진다.
 *
 * 전에는 이 역할도 /project/* 를 통째로 읽었고, 좁히지 않는 근거를 "어차피 jwt-signing-key 를
 * 줘야 하니 나머지를 막아 버는 것이 크지 않다" 로 적어 두었다. 그 논리는 db-password 에만 맞다.
 * 그것은 SG 가 RDS 3306 을 막아 못 쓰지만, github-token 과 ghcr-token 과 kakao-admin-key 는
 * 인터넷만 있으면 쓰이므로 SG 가 아무것도 막지 못한다.
 *
 * 부하 생성기는 설계상 2만 명을 사칭하는 기계다. 거기에 조직 레포 쓰기 권한과 카카오 관리 키를
 * 함께 두는 것과, 서명 키 하나만 두는 것은 사고가 났을 때 크기가 다르다.
 */
data "aws_iam_policy_document" "read_params_loadtest" {
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]

    resources = [
      for n in ["jwt-signing-key", "prometheus-endpoint"] :
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/${n}"
    ]
  }

  # jwt-signing-key 가 SecureString 이라 이것 없이는 못 읽는다.
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:${var.region}:${data.aws_caller_identity.current.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

/*
 * 나머지 셋은 값 목록이 자주 늘어 통째로 준다. 앱은 12개를 거의 다 읽고,
 * 하나 추가할 때마다 정책을 고치면 빠뜨려서 기동이 막히는 쪽이 더 잦다.
 */
resource "aws_iam_role_policy" "read_params" {
  for_each = {
    app        = data.aws_iam_policy_document.read_params.json
    monitoring = data.aws_iam_policy_document.read_params.json
    batch      = data.aws_iam_policy_document.read_params.json
    loadtest   = data.aws_iam_policy_document.read_params_loadtest.json
  }

  name   = "read-params"
  role   = aws_iam_role.instance[each.key].id
  policy = each.value
}

# presigned URL 발급과 이미지 삭제에 쓴다. 버킷 전체를 나열할 이유는 없다.
data "aws_iam_policy_document" "media" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.media_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "media" {
  name   = "media-bucket"
  role   = aws_iam_role.instance["app"].id
  policy = data.aws_iam_policy_document.media.json
}

/*
 * cloudwatch_exporter 가 관리형 서비스의 호스트 지표를 긁는다.
 * RDS 와 ElastiCache 는 OS 레벨 접근이 안 되므로 이 경로가 유일하다.
 */
data "aws_iam_policy_document" "cloudwatch_read" {
  statement {
    effect = "Allow"

    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "tag:GetResources",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cloudwatch_read" {
  name   = "cloudwatch-read"
  role   = aws_iam_role.instance["monitoring"].id
  policy = data.aws_iam_policy_document.cloudwatch_read.json
}

/*
 * Prometheus 가 스크레이프 대상을 EC2 에서 찾는다 (prometheus.yml 의 ec2_sd_configs).
 * 인스턴스는 ASG 가 교체할 때마다 바뀌므로 주소를 고정해 둘 수 없다.
 *
 * 이 권한이 없으면 app, batch, node, cadvisor 잡이 통째로 죽는다.
 * 조용히 죽는다는 것이 문제다. 대상이 0개인 잡은 경보를 내지 않고,
 * 그 지표에 걸린 알람은 발동 조건을 영영 만족하지 못한다.
 * HikariPendingHigh, HighFiveXXRate, CpuCreditLow, ContainerRestartLoop 이 그렇게 죽어 있었다.
 *
 * DescribeInstances 는 리소스 단위 제한을 지원하지 않아 * 로 둔다.
 * 읽기 전용이고 반환값은 이 계정의 인스턴스 목록뿐이다.
 */
data "aws_iam_policy_document" "ec2_discovery" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_discovery" {
  name   = "ec2-discovery"
  role   = aws_iam_role.instance["monitoring"].id
  policy = data.aws_iam_policy_document.ec2_discovery.json
}
