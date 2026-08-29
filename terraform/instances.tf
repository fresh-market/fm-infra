/*
 * ASG 밖의 인스턴스들이다.
 *
 * 모니터링은 ASG 에 넣지 않는다 (INF-24).
 * desired 0 이 EBS 까지 지워 Prometheus 와 Loki 데이터가 사라진다.
 *
 * 배치는 ASG 밖 단독이다 (INF-05).
 * 롤링으로 바꾸면 구버전과 신버전 배치가 겹쳐 "프로세스는 항상 하나" 전제가 깨진다.
 */

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = var.instance_types["monitoring"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.mon.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["monitoring"].name

  # 관측 데이터가 쌓인다. 앱보다 크게 잡는다.
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  /*
   * observability/ 를 클론해 스택을 올린다.
   * 설정을 Terraform 이 아니라 Git 이 갖는 이유는 INF-32 와 OPS-2-18 에 있다.
   * 임계값을 고칠 때마다 apply 를 하지 않기 위해서다.
   */
  user_data_base64 = base64encode(local.monitoring_user_data)

  tags = {
    Name = "${var.project}-monitoring"
    Role = "monitoring"
  }

  lifecycle {
    # EBS 에 관측 데이터가 있다. 태우면 되돌릴 수 없다.
    prevent_destroy = true
  }
}

/*
 * 앱과 같은 jar 를 prod,batch 프로필로 띄운다. ALB 에 붙지 않는다.
 *
 * AMI 가 x86 인 것은 앱과 같은 컨테이너 이미지를 받기 때문이다.
 * 빌드가 러너(x86_64)에서 단일 아키텍처로 나오므로 앱이 x86 인 한 배치도 x86 이어야 한다.
 * arm 으로 두었을 때 컨테이너가 exec format error 로 계속 재시작했다.
 */
resource "aws_instance" "batch" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.instance_types["batch"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.batch.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["batch"].name
  user_data_base64       = base64encode(local.batch_user_data)

  /*
   * user-data 는 최초 부팅에만 돈다. 템플릿을 고쳐도 떠 있는 인스턴스의 compose.yaml 과 systemd 유닛은 그대로다.
   * 배치는 상태를 디스크에 두지 않으므로 재생성이 안전하고, 그래야 Terraform 이 설정의 주인이 된다.
   * SSM 에서 오는 값(SHA, DB 엔드포인트)은 재생성 없이 refresh-env 가 맡는다.
   */
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project}-batch"
    Role = "batch"
  }
}

/*
 * 시험 시간에만 기동한다 (월 약 40시간).
 * 상시 가동 전제의 예외라 count 로 끈다.
 */
resource "aws_instance" "load_test" {
  count = var.load_test_enabled ? 1 : 0

  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.instance_types["load_test"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.loadtest.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["loadtest"].name
  user_data_base64       = base64encode(local.load_test_user_data)

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project}-load-test"
    Role = "load-test"
  }
}

/*
 * DuckDNS 는 A 레코드만 받는다. stop.sh 로 인스턴스를 내렸다 올리면 공인 IP 가 바뀌므로
 * 그때마다 DuckDNS 를 손으로 갱신해야 한다. 주소를 고정해 그 일을 없앤다.
 *
 * 인스턴스가 켜져 있는 동안에는 원래 내던 공인 IPv4 요금을 대신 낸다.
 * 멈춰 둔 시간만큼은 EIP 요금이 따로 붙는다. 시간당 0.005 USD 수준이다.
 */
resource "aws_eip" "monitoring" {
  count = local.has_duckdns ? 1 : 0

  instance = aws_instance.monitoring.id
  domain   = "vpc"

  tags = {
    Name = "${var.project}-monitoring"
  }
}
