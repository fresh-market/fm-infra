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
  ami           = data.aws_ami.ubuntu_arm.id
  instance_type = var.instance_types["monitoring"]

  /*
   * 자리가 DuckDNS 사용 여부로 갈린다.
   *
   * Caddy 가 Let's Encrypt 에서 인증서를 받으려면 80 으로 들어오는 검증 요청을 받아야 한다
   * (HTTP-01). 사설 서브넷에는 들어올 길이 없어 발급이 반복 실패하고, Let's Encrypt 는
   * 실패에도 한도가 있어 금방 막힌다. 그래서 둘을 함께 켤 수 없다.
   *
   * 도메인을 사면 ALB + OIDC 경로(has_grafana)가 열리고, 그때는 사설이어도 볼 수 있다.
   * 그 전까지 사설 상태에서 보는 방법은 SSM 포트 포워딩이다 (observability/README.md).
   */
  subnet_id              = local.has_duckdns ? aws_subnet.public["a"].id : aws_subnet.private["a"].id
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

  /*
   * 모니터링이 읽을 SSM 값이 먼저 있어야 한다. 근거는 aws_instance.batch 의 같은 자리에 있다.
   *
   * 이쪽은 user-data 에 set -e 가 없어 2026-09-26 에 ParameterNotFound 를 두 번 맞고도 떴다.
   * 죽지 않았을 뿐이고 값이 빈 채로 뜬 것이라 오히려 찾기 어렵다. 그 둘이 db-endpoint 와
   * cache-endpoint 이고, mysqld-exporter 와 redis-exporter 가 그 값으로 대상을 잡는다.
   *
   * loki-endpoint 와 prometheus-endpoint 는 넣지 않는다. 그 둘의 값이 이 인스턴스의 private_ip
   * 라서 넣으면 순환이 된다. 다른 인스턴스가 모니터링을 찾는 값이고 모니터링 자신은 안 읽는다.
   */
  depends_on = [
    aws_ssm_parameter.db_endpoint,
    aws_ssm_parameter.cache_endpoint,
    aws_ssm_parameter.grafana_root_url,
    aws_ssm_parameter.grafana_auth_proxy,
    aws_ssm_parameter.duckdns_hostname,
  ]

  lifecycle {
    # EBS 에 관측 데이터가 있다. 태우면 되돌릴 수 없다.
    prevent_destroy = true

    /*
     * AMI 가 바뀌어도 이 인스턴스를 갈아엎지 않는다.
     *
     * data.aws_ami 가 most_recent 라 Canonical 이 새 Ubuntu 를 올리면 교체 대상이 되는데,
     * 위 prevent_destroy 가 그것을 거부해 **모든 apply 가 그 자리에서 죽는다.**
     * 무관한 변경 하나를 넣으려 해도 못 넣게 된다. 실제로 그렇게 막혔다 (2026-09-23).
     *
     * 이 인스턴스는 ASG 밖이라 AMI 갱신이 자동으로 필요하지 않다. 커널을 올려야 하면
     * 사람이 판단해서 replace 한다. 그때는 관측 데이터를 먼저 챙긴다.
     */
    ignore_changes = [ami]
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
  subnet_id              = aws_subnet.private["a"].id
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

  /*
   * 인스턴스가 읽을 SSM 값이 먼저 있어야 한다.
   *
   * Terraform 은 user-data 안의 문자열을 읽지 않으므로 이 의존을 스스로 세우지 못한다.
   * 2026-09-26 에 배치가 RDS 보다 16분 먼저 떠서 db-endpoint 가 없었고, refresh-env 가
   * 거기서 죽어 systemd 유닛조차 안 쓰였다. 인스턴스는 살아 있는데 아무것도 안 돌았다.
   *
   * refresh-env 에도 대기를 넣었지만 그것은 나중 기동을 위한 안전망이다. apply 를 10분
   * 기다리게 둘 이유가 없으므로 순서는 여기서 못 박는다.
   */
  depends_on = [
    aws_ssm_parameter.current_sha,
    aws_ssm_parameter.db_endpoint,
    aws_ssm_parameter.cache_endpoint,
    aws_ssm_parameter.cdn_domain,
    aws_ssm_parameter.loki_endpoint,
  ]

  /*
   * 모니터링과 같은 이유로 AMI 변경을 무시한다.
   *
   * 여기는 prevent_destroy 가 없어 apply 가 막히지는 않지만, Canonical 이 새 AMI 를 올릴
   * 때마다 무관한 apply 가 배치를 갈아엎는다. 돌고 있던 작업이 그때 끊긴다.
   *
   * 위 user_data_replace_on_change 는 그대로 둔다. 그쪽은 우리가 템플릿을 고쳤을 때만
   * 걸리므로 의도한 교체다.
   */
  lifecycle {
    ignore_changes = [ami]
  }
}

/*
 * 시험 시간에만 기동한다 (월 약 40시간).
 * 상시 가동 전제의 예외라 count 로 끈다.
 */
resource "aws_instance" "load_test" {
  /*
   * 한 대로는 2만 VU 를 못 낸다. 근거는 variable "load_test_count" 주석에 있다.
   * 요약하면 k6 가 VU 당 약 369 KB 를 쓰고 8 GB 가 이 계정의 상한이다.
   */
  count = var.load_test_enabled ? var.load_test_count : 0

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

  /*
   * 세그먼트 번호를 태그로 심는다.
   *
   * k6 의 execution-segment 는 VU 번호 공간을 대별로 나눠 주는 값이고, 이 인스턴스가
   * 자기 몫을 알아야 그것을 인자로 줄 수 있다. 태그로 두는 이유는 인스턴스가 스스로
   * 자기 태그를 읽을 수 있어서다. SSM 에 두면 대수가 바뀔 때마다 파라미터를 늘려야 한다.
   *
   * 이 값이 어긋나면 두 대가 같은 토큰을 써서 1인 1매 위반이 난다. 앱이 아니라 생성기
   * 탓인데 지표에서는 구분이 안 되므로, loadtest-box.sh 가 띄운 뒤 이 값을 검산한다.
   */
  tags = {
    Name = "${var.project}-load-test-${count.index + 1}"
    Role = "load-test"
    # k6 의 --execution-segment 표기 그대로다. 구간이지 번호가 아니다.
    # 0:1/2 과 1/2:1 처럼 시작과 끝을 콜론으로 잇는다.
    Segment = "${count.index == 0 ? "0" : "${count.index}/${var.load_test_count}"}:${count.index + 1 == var.load_test_count ? "1" : "${count.index + 1}/${var.load_test_count}"}"
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
