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
 * max_size 가 2여야 배포 절차가 성립한다.
 * 신규를 먼저 띄우므로 배포 중 일시적으로 2대가 된다. desired 를 2로 두면 띄울 자리가 없다.
 *
 * desired_capacity 는 배포 스크립트가 조절한다. Terraform 이 되돌리면 배포가 깨진다.
 */
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-app"
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  min_size         = 0
  desired_capacity = 1
  max_size         = 2

  # ELB 헬스체크를 본다. 프로세스는 살아 있는데 응답을 못 하는 경우를 잡는다.
  health_check_type         = "ELB"
  health_check_grace_period = 300

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
 * 대상당 요청 수로 늘린다. CPU 를 쓰지 않는 이유는 이 경로가 CPU 를 안 쓰기 때문이다.
 *
 * v4 의 요청 스레드는 순번을 받아 큐에 넣고 future 에서 park 한다. 가상 스레드라 캐리어를
 * 반납하고 자므로, 큐가 수천 건까지 자라고 p99 가 무너지는 동안에도 CPU 는 낮게 유지된다.
 * 포화가 CPU 에 안 나타나므로 CPU 기반 확장은 신호를 못 받는다.
 *
 * 크레딧은 이 판단과 무관하다. 인스턴스가 unlimited 모드라 크레딧이 말라도 스로틀링이 없다.
 *
 * 버스트에는 이 정책이 못 따라온다. 알람 평가와 부팅에 수 분이 걸려 이벤트가 먼저 끝난다.
 * 이벤트 전에 desired 를 미리 올려 두는 것이 본 수단이고, 이것은 길게 이어지는 부하의 안전망이다.
 *
 * 이 정책 하나가 CloudWatch 알람 2개를 자동으로 만든다. INF-31 의 한도에 함께 계산해야 한다.
 */
resource "aws_autoscaling_policy" "coupon_requests" {
  count = var.coupon_dedicated_enabled ? 1 : 0

  name                   = "${var.project}-coupon-requests"
  autoscaling_group_name = aws_autoscaling_group.coupon[0].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.coupon[0].arn_suffix}"
    }

    target_value = var.coupon_target_requests_per_instance

    # 줄이는 쪽을 늦게 잡는다. 이벤트 중 잠깐 잦아들었다고 내리면 다음 파도를 못 받는다.
    disable_scale_in = true
  }
}
