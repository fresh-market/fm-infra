/*
 * 삭제 방지를 두 겹으로 건다 (INF-18, 되돌릴 수 없음).
 * 잘못된 변수 파일로 destroy 를 돌리면 ALB 가 사라지고 DNS 이름이 바뀐다.
 */
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  subnets            = [for s in aws_subnet.public : s.id]
  security_groups    = [aws_security_group.alb.id]

  # 요청 타임아웃 계층의 가장 바깥이다. 안쪽이 더 짧아야 한다.
  idle_timeout = 60

  enable_deletion_protection = true

  tags = {
    Name = "${var.project}-alb"
  }

  lifecycle {
    prevent_destroy = true
  }
}

/*
 * 트래픽은 8080 으로 보내고 헬스체크만 8081 로 찌른다.
 * 액추에이터를 관리 포트로 뺐으므로 8080 에는 그 경로가 존재하지 않는다.
 *
 * readiness 를 본다. liveness 가 아니다.
 * readiness 에는 공유 의존성을 넣지 않는다 (INF-16). DB 가 흔들릴 때 전 인스턴스가 동시에 빠지는 것을 막는다.
 */
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # 종료 타임아웃 계층의 가장 안쪽이다. Spring graceful 30초와 짝을 이룬다.
  deregistration_delay = 30

  health_check {
    path                = "/actuator/health/readiness"
    port                = "8081"
    protocol            = "HTTP"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-app"
  }
}

/*
 * Route 53 헬스체크가 AWS 밖에서 liveness 를 찌른다 (INF-19).
 * Prometheus 는 VPC 안이라 ALB 가 죽어도 앱 지표는 정상으로 보인다. 그 사각지대를 메우는 눈이다.
 * 그 경로만 8081 로 보내려면 대상 그룹이 하나 더 있어야 한다.
 *
 * 이 대상 그룹이나 아래 규칙이 지워지면 외부 감시가 실패해 알람이 울린다.
 * 액추에이터가 열리는 방향으로는 고장 나지 않는다.
 */
resource "aws_lb_target_group" "liveness" {
  name        = "${var.project}-liveness"
  port        = 8081
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/actuator/health/liveness"
    protocol            = "HTTP"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-liveness"
  }
}

# 도메인이 없으면 80 이 그대로 서비스한다. 임시 상태다.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.has_domain ? [1] : []

    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.has_domain ? [] : [1]

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.has_domain ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

locals {
  # 도메인 유무에 따라 규칙을 걸 리스너가 달라진다
  public_listener_arn = local.has_domain ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}

/*
 * liveness 하나만 8081 로 보낸다.
 * show-details 가 never 라 응답은 status 뿐이고 드러나는 정보가 없다.
 * 나머지 액추에이터 경로는 규칙이 없어 8080 으로 가고, 거기에는 존재하지 않아 404 다.
 */
resource "aws_lb_listener_rule" "liveness" {
  listener_arn = local.public_listener_arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.liveness.arn
  }

  condition {
    path_pattern {
      values = ["/actuator/health/liveness"]
    }
  }
}

/*
 * 여기부터 Grafana 노출이다. domain_name 과 grafana_oidc_client_id 가 둘 다 채워질 때만 생긴다.
 *
 * 팀원이 브라우저로 지표를 보게 하는 것이 목적이다.
 * Grafana 의 3000 은 인터넷에 열지 않는다. 여는 것은 ALB 이고 인증도 ALB 가 끝낸다.
 */

resource "aws_lb_target_group" "grafana" {
  count = local.has_grafana ? 1 : 0

  name        = "${var.project}-grafana"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  /*
   * /api/health 는 인증 없이 200 을 준다.
   * 로그인 화면이 뜨는 / 로 검사하면 302 가 돌아와 대상이 계속 unhealthy 로 잡힌다.
   */
  health_check {
    path                = "/api/health"
    port                = "3000"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-grafana"
  }
}

# 모니터링은 ASG 밖 고정 인스턴스라 대상을 직접 붙인다.
resource "aws_lb_target_group_attachment" "grafana" {
  count = local.has_grafana ? 1 : 0

  target_group_arn = aws_lb_target_group.grafana[0].arn
  target_id        = aws_instance.monitoring.id
  port             = 3000
}

/*
 * ALB 가 Google 로 인증을 끝낸 뒤에만 뒤로 넘긴다 (authenticate-oidc).
 * 이 액션은 HTTPS 리스너에서만 동작한다. has_grafana 가 도메인을 전제로 삼는 이유가 이것이다.
 *
 * priority 는 liveness(10) 다음이다. 호스트 헤더가 갈라 주므로 서로 겹치지 않는다.
 *
 * client_secret 은 상태 파일에 평문으로 남는다. ALB 가 인라인 값만 받아서 피할 방법이 없다.
 * 상태 버킷이 비공개이고 SSE 와 버저닝이 켜져 있다는 것이 이것을 받아들이는 근거다.
 */
resource "aws_lb_listener_rule" "grafana" {
  count = local.has_grafana ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 20

  action {
    type = "authenticate-oidc"

    authenticate_oidc {
      issuer                 = "https://accounts.google.com"
      authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"
      token_endpoint         = "https://oauth2.googleapis.com/token"
      user_info_endpoint     = "https://openidconnect.googleapis.com/v1/userinfo"

      client_id     = var.grafana_oidc_client_id
      client_secret = data.aws_ssm_parameter.grafana_oidc_client_secret[0].value

      # 이메일만 받는다. Grafana 가 사용자를 만들 때 쓰는 값이 그것뿐이다.
      scope = "openid email"

      # 12시간마다 다시 로그인한다. 하루 한 번꼴이라 매일 아침에 걸린다.
      session_timeout            = 43200
      on_unauthenticated_request = "authenticate"
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana[0].arn
  }

  condition {
    host_header {
      values = [local.grafana_host]
    }
  }
}

/*
 * 시크릿은 apply.sh 가 만드는 8개 목록에 넣지 않았다.
 * 넣으면 그 스크립트 3단계가 값이 빌 때마다 apply 를 막아, Grafana 를 안 쓰는 동안에도 구축이 멈춘다.
 * grafana_oidc_client_id 를 채우기로 한 사람이 그때 이 파라미터도 함께 넣는다. README 에 명령이 있다.
 */
data "aws_ssm_parameter" "grafana_oidc_client_secret" {
  count = local.has_grafana ? 1 : 0

  name            = "${local.ssm_prefix}/grafana-oidc-client-secret"
  with_decryption = true
}

/*
 * 선착순 전용 경로다 (coupon.md 4장). coupon_dedicated_enabled 로 켜고 끈다.
 *
 * 분리하는 이유는 격벽이다. 안 나누면 선착순 트래픽이 톰캣 스레드와 커넥션 풀을 다 먹어
 * 상품 조회와 주문이 함께 죽는다. 부수 효과로 버전 비교가 깨끗해지고 되돌리기가 쉬워진다.
 *
 * 꺼 두면 발급 요청이 기본 동작을 타고 평상시 앱으로 간다. 규칙만 사라질 뿐 경로가 막히지 않는다.
 */
resource "aws_lb_target_group" "coupon" {
  count = var.coupon_dedicated_enabled ? 1 : 0

  name        = "${var.project}-coupon"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # 앱 대상 그룹과 같은 값이다. 같은 이미지를 프로파일만 바꿔 띄우므로 종료 특성이 같다.
  deregistration_delay = 30

  /*
   * 이 그룹만 앱보다 느슨하다. 바쁜 인스턴스를 죽은 것으로 오판하지 않기 위해서다.
   *
   * 이벤트 90초 동안 이 인스턴스들은 CPU 90% 를 친다. 그때 readiness 응답이 5초를 넘길 수
   * 있는데, 5초 x 2회면 20초 만에 퇴출이고 ASG 가 HealthCheckType = ELB 라 인스턴스를
   * 종료한다. 새 인스턴스는 기동에 4~6분이라 이벤트가 끝날 때까지 복구되지 않는다.
   *
   * 실제로 그렇게 무너졌다 (2026-08-30 부하 시험). 발급 수가 살아남은 대수를 그대로 따라갔다.
   *
   *   3대 유지  ->  10,000건
   *   2대로 감소 ->   8,870건
   *   1대까지    ->     538건
   *
   * 두 값을 함께 늘린다. 한 번의 여유는 5초에서 8초로, 퇴출까지는 20초에서 50초로 간다.
   * 느린 인스턴스는 느린 채로 계속 요청을 받는 편이 낫다. 빼 봐야 그 부하가 남은 대수로
   * 옮겨 갈 뿐이다.
   *
   * timeout 을 interval 과 같게 둘 수는 없다. ALB 가 "Health check interval must be
   * greater than the timeout" 으로 거절한다. 그래서 10 과 8 이다.
   *
   * 퇴출을 이벤트 길이(90초) 밖으로 밀지는 않았다. 그러면 정말로 죽은 인스턴스에도 100초
   * 동안 요청이 간다. 50초가 "바쁜 것은 봐주고 죽은 것은 뺀다" 의 절충이다.
   */
  health_check {
    path                = "/actuator/health/readiness"
    port                = "8081"
    protocol            = "HTTP"
    interval            = 10
    timeout             = 8
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-coupon"
  }
}

/*
 * priority 는 liveness(10) 다음, Grafana(20) 앞을 피해 15 로 둔다.
 * 경로 패턴이 서로 겹치지 않아 순서 자체는 결과를 바꾸지 않는다.
 */
resource "aws_lb_listener_rule" "coupon" {
  count = var.coupon_dedicated_enabled ? 1 : 0

  listener_arn = local.public_listener_arn
  priority     = 15

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.coupon[0].arn
  }

  condition {
    path_pattern {
      values = [var.coupon_path_pattern]
    }
  }
}
