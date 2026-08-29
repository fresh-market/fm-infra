/*
 * Ubuntu 24.04 LTS.
 * t3 와 t3a 는 x86, t4g 는 ARM 이라 이미지를 따로 찾는다.
 */
data "aws_ami" "ubuntu_x86" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

/*
 * 앱과 배치는 같은 jar 를 쓰고 프로필로만 갈린다.
 * 앱에는 batch 가 절대 들어가면 안 된다 (INF-12-07).
 * 들어가면 앱 대수만큼 스케줄러가 함께 돌고, 분산 락이 없어 아무것도 막지 못한다.
 */
locals {
  common_bootstrap = file("${path.module}/templates/common-bootstrap.sh")
  alloy_config     = file("${path.module}/../observability/alloy/config.alloy")

  # 최초 부팅과 재배포가 같은 코드를 쓴다
  refresh_env = templatefile("${path.module}/templates/refresh-env.sh.tftpl", {
    project    = var.project
    region     = var.region
    github_org = var.github_org
  })

  # 모니터링도 같은 이유로 갱신 경로가 필요하다. 다만 읽는 값과 쓰는 자리가 달라 별도다
  refresh_monitoring_env = templatefile("${path.module}/templates/refresh-monitoring-env.sh.tftpl", {
    project     = var.project
    region      = var.region
    db_username = var.db_username
  })

  /*
   * ASG 밖 인스턴스용이다. Docker 와 AWS CLI 만 깔고 끝난다.
   * 모니터링은 관측 스택을, 부하 생성은 k6 를 컨테이너로 돌리지만 그것을 올리는 것은 이 스크립트가 아니다.
   */
  standalone_user_data = "#!/bin/bash\n${local.common_bootstrap}"

  /*
   * 부하 생성기는 커널 기본값으로 2만 연결을 못 만든다.
   * 짧은 창에 열고 닫으므로 임시 포트와 파일 디스크립터가 먼저 마르고,
   * 그러면 서버가 아니라 생성기의 한계를 측정하게 된다. 값은 k6 공식 권고다.
   */
  load_test_user_data = <<-EOT
    #!/bin/bash
    ${local.common_bootstrap}

    cat > /etc/sysctl.d/99-k6.conf <<'SYSCTL'
    net.ipv4.ip_local_port_range = 1024 65535
    net.ipv4.tcp_tw_reuse = 1
    net.ipv4.tcp_timestamps = 1
    SYSCTL
    sysctl --system

    cat > /etc/security/limits.d/99-k6.conf <<'LIMITS'
    * soft nofile 250000
    * hard nofile 250000
    LIMITS

    # 로그인 셸과 systemd 양쪽에 걸어야 한다. 한쪽만 올리면 다른 경로에서 기본값이 걸린다.
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-k6.conf <<'SYSTEMD'
    [Manager]
    DefaultLimitNOFILE=250000
    SYSTEMD
    systemctl daemon-reexec
  EOT

  monitoring_user_data = templatefile("${path.module}/templates/monitoring-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    infra_repo       = var.github_infra_repo
    db_username      = var.db_username
    refresh_env      = local.refresh_monitoring_env
  })

  compose_args = {
    project     = var.project
    github_org  = var.github_org
    db_name     = var.db_name
    db_username = var.db_username
  }

  app_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod", role = "app" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod" })
  })

  /*
   * 전용 인스턴스는 같은 이미지를 coupon 프로파일로 띄운다.
   *
   * application-coupon.yml 이 커넥션 풀을 줄이는 자리다 (coupon.md 5장).
   * 그 파일이 아직 없어도 기동은 된다. Spring 은 없는 프로파일 파일을 무시한다.
   * 다만 파일이 생기기 전에는 풀이 앱과 같은 10 이라 3대를 올리면 예산을 넘긴다.
   */
  coupon_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod,coupon", role = "coupon" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod,coupon" })
  })

  batch_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod,batch", role = "batch" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod,batch" })
  })
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.ubuntu_x86.id
  instance_type = var.instance_types["app"]

  iam_instance_profile {
    name = aws_iam_instance_profile.instance["app"].name
  }

  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = base64encode(local.app_user_data)

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 토큰을 요구한다. SSRF 로 자격증명이 새는 경로를 막는다.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project}-app"
      Role = "app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * 트래픽에 따라 1~3 대로 움직인다. 고정 이중화가 아니라 오토스케일링이다.
 *
 * min_size 가 1 이다. 0 이면 트래픽이 없을 때 정책이 스케일 인으로 0 까지 내려
 * 서비스가 사라진다. 세션을 끝낼 때는 stop.sh 가 min 을 0 으로 내린 뒤 desired 를 0 으로 준다.
 *
 * max_size 3 이 확장 상한이자 배포 여유를 겸한다. deploy.sh 가 desired + 1 로 신규를 띄우므로,
 * 3 대까지 올라간 상태에서는 배포가 막힌다. 드문 경우이고 스케일 인을 기다리면 풀린다.
 * 4 로 올리지 않는 것은 커넥션 때문이다. 배포 중 4 대면 40 이고 배치와 익스포터를 더해 55,
 * 선착순 이벤트가 겹치면 61 로 실측 60 을 넘긴다.
 *
 * desired_capacity 는 배포 스크립트와 정책이 조절한다. Terraform 이 되돌리면 배포가 깨진다.
 */
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-app"
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  min_size         = 1
  desired_capacity = 1
  max_size         = 3

  # ELB 헬스체크를 본다. 프로세스는 살아 있는데 응답을 못 하는 경우를 잡는다.
  health_check_type         = "ELB"
  health_check_grace_period = 300

  /*
   * 새로 띄운 인스턴스가 제 몫을 하기까지 ASG 가 기다려 주는 시간이다.
   *
   * 이게 없으면 부팅 중인 대수를 계산에 안 넣어 정책이 같은 부하를 두 번 센다.
   * 1대에서 분당 12000 이 오면 2대로 늘리는데, 신규가 뜨는 4~6분 동안 지표가 그대로라
   * 3분 뒤 재판정에서 ceil(2 x 12000/6000) = 4 가 나온다. max 3 에서 잘려도 한 대를 더 띄운다.
   *
   * 300 은 실측이 아니다. 기동 시간을 아직 안 쟀고(오토스케일링 설계 6.2절 미정),
   * 같은 이유로 잡힌 health_check_grace_period 와 맞춰 둔 값이다.
   * 첫 배포에서 증설부터 healthy 까지를 재고 그 값으로 바꾼다.
   *
   * 길게 잡아서 손해 보는 것은 정당한 추가 확장이 늦어지는 것인데, 상한이 3이라 거의 없다.
   *
   * coupon ASG 에는 안 넣는다. 스케일링 정책이 없어 이 값이 쓰일 자리가 없다 (INF-40).
   */
  default_instance_warmup = 300

  target_group_arns = [
    aws_lb_target_group.app.arn,
    aws_lb_target_group.liveness.arn,
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

/*
 * 스케일 인 때 배치가 돌고 있으면 기다린다 (OPS-1-04).
 * heartbeat_timeout 은 배치 최대 실행 시간 + 여유여야 하는데 아직 측정 전이다.
 * 부하 시험 후 실제 값으로 줄인다.
 */
resource "aws_autoscaling_lifecycle_hook" "app_terminating" {
  name                   = "${var.project}-drain"
  autoscaling_group_name = aws_autoscaling_group.app.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300
  default_result         = "CONTINUE"
}

/*
 * 선착순 전용 ASG 다 (coupon.md 4장). coupon_dedicated_enabled 로 켜고 끈다.
 *
 * desired 0 으로 태어난다. 이벤트 전에 올리고 끝나면 내린다.
 * 평상시에 켜 두면 커넥션 예산만 먹는다.
 */
resource "aws_launch_template" "coupon" {
  count = var.coupon_dedicated_enabled ? 1 : 0

  name_prefix   = "${var.project}-coupon-"
  image_id      = data.aws_ami.ubuntu_x86.id
  instance_type = var.instance_types["app"]

  iam_instance_profile {
    name = aws_iam_instance_profile.instance["app"].name
  }

  # 앱과 같은 보안 그룹이다. 같은 곳(RDS, 캐시)을 같은 포트로 본다.
  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = base64encode(local.coupon_user_data)

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project}-coupon"
      Role = "coupon"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * liveness 대상 그룹에 넣지 않는다.
 * 그것은 Route 53 헬스체크가 밖에서 찌르는 자리이고, 전용 인스턴스는 그 대상이 아니다.
 *
 * desired_capacity 에 ignore_changes 를 건다.
 * 이벤트 운영과 스케일링 정책이 값의 주인이고 apply 가 되돌리면 안 된다.
 */
resource "aws_autoscaling_group" "coupon" {
  count = var.coupon_dedicated_enabled ? 1 : 0

  name                = "${var.project}-coupon"
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  min_size         = 0
  desired_capacity = 0
  max_size         = var.coupon_max_size

  health_check_type         = "ELB"
  health_check_grace_period = 300

  target_group_arns = [aws_lb_target_group.coupon[0].arn]

  launch_template {
    id      = aws_launch_template.coupon[0].id
    version = "$Latest"
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

/*
 * 전용 ASG 에는 스케일링 정책을 두지 않는다. 대수는 coupon-event.sh 가 이벤트 전에 직접 정한다.
 *
 * 반응형 확장이 이 이벤트에는 구조적으로 안 맞는다. 확장 판정이 1분 데이터포인트 3개 연속이라
 * 최소 3분이 걸리는데, 선착순 쇄도는 그보다 짧게 끝난다. 판정이 나기 전에 재고가 소진된다.
 *
 * 시작 시각을 아는 이벤트라 미리 여는 것이 맞다. 정책을 두면 표준 운용(open 3 = max_size)에서는
 * 올릴 자리가 없어 절대 안 돌고, 안 도는 것이 남아 있으면 읽는 사람이 대수를 정책이 정한다고 오해한다.
 *
 * 앱 ASG 는 다르다. 상시 서비스라 트래픽이 언제 붙을지 몰라 정책이 주 수단이다 (INF-39).
 */
/*
 * 트래픽으로 앱을 늘린다. 선착순 전용 ASG 의 정책과 같은 지표를 쓴다.
 *
 * 스케일 인을 막지 않는다. 선착순은 이벤트 중 잠깐 잦아들었다고 내리면 다음 파도를 못 받아
 * 막아 두었지만, 일반 경로는 상시 서비스라 부하가 빠지면 내려가는 것이 맞다.
 *
 * 이 정책이 CloudWatch 알람 2개를 자동으로 만든다. alarms.tf 의 4개와 합쳐 6개이고
 * INF-31 이 정한 상한과 정확히 같다. 알람을 더 만들려면 이 정책 몫을 먼저 빼야 한다.
 */
resource "aws_autoscaling_policy" "app_requests" {
  name                   = "${var.project}-app-requests"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }

    target_value = var.app_target_requests_per_instance
  }
}
