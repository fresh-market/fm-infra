/*
 * 도메인이 없으면 만들지 않는다.
 * var.domain_name 을 채우면 호스팅 영역, 인증서, HTTPS 리스너가 함께 생긴다.
 *
 * stateless JWT 가 헤더로 오가므로 평문 구간을 둘 수 없다 (INF-17, 되돌릴 수 없음).
 * 즉 도메인이 없는 상태는 임시다.
 */

locals {
  has_domain = var.domain_name != ""

  # api.example.com 에서 example.com 을 뽑는다
  zone_name = local.has_domain ? join(".", slice(split(".", var.domain_name), 1, length(split(".", var.domain_name)))) : ""

  grafana_host = local.has_domain ? "${var.grafana_subdomain}.${local.zone_name}" : ""

  /*
   * Grafana 를 ALB 에 붙이는 조건이다.
   * OIDC 인증 액션은 HTTPS 리스너에만 붙일 수 있어 도메인이 전제다.
   * 클라이언트 ID 가 없으면 인증 없이 노출하게 되므로 그때도 붙이지 않는다.
   */
  has_grafana = local.has_domain && var.grafana_oidc_client_id != ""

  # 도메인을 사기 전까지 쓰는 임시 경로다. ALB 를 거치지 않는다.
  has_duckdns = var.duckdns_hostname != ""

  /*
   * Grafana 가 자기 주소를 아는 값이다. ALB 경로가 있으면 그쪽이 정본이다.
   * 틀리면 로그인 후 리디렉션과 패널 공유 링크가 localhost 로 간다.
   */
  grafana_root_url = (
    local.has_grafana ? "https://${local.grafana_host}/" :
    local.has_duckdns ? "https://${var.duckdns_hostname}/" :
    "unset"
  )
}

resource "aws_route53_zone" "main" {
  count = local.has_domain ? 1 : 0

  name    = local.zone_name
  comment = "${var.project} service domain"

  lifecycle {
    prevent_destroy = true
  }
}

/*
 * SAN 은 has_grafana 가 아니라 has_domain 을 따른다.
 * SAN 을 바꾸면 인증서가 새로 발급되는데, Grafana 를 켜고 끌 때마다 그것이 일어나면 안 된다.
 * 쓰지 않는 SAN 이 하나 남는 비용은 0 이다.
 */
resource "aws_acm_certificate" "main" {
  count = local.has_domain ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = [local.grafana_host]
  validation_method         = "DNS"

  # 인증서를 갈아끼울 때 리스너가 옛 인증서를 참조한 채로 남지 않게 한다.
  lifecycle {
    create_before_destroy = true
  }
}

/*
 * 검증 레코드를 Terraform 관리 대상에 넣는다 (INF-12-18).
 * ACM 자동 갱신은 이 레코드가 살아 있을 때만 된다.
 * 레코드가 사라지면 갱신이 조용히 실패하고 만료 시점에야 드러난다.
 */
resource "aws_route53_record" "cert_validation" {
  for_each = local.has_domain ? {
    for o in aws_acm_certificate.main[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = aws_route53_zone.main[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  count = local.has_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "alb" {
  count = local.has_domain ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

/*
 * 같은 ALB 를 가리킨다. 호스트 헤더로 리스너 규칙이 갈라 준다.
 * evaluate_target_health 를 끈다. 켜면 앱 대상 그룹의 건강까지 반영되어,
 * 앱이 죽었을 때 Grafana 이름도 함께 응답하지 않는다. 장애 때 가장 필요한 화면이 그때 사라진다.
 */
resource "aws_route53_record" "grafana" {
  count = local.has_grafana ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = local.grafana_host
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false
  }
}

/*
 * VPC 밖에서 보는 눈이다 (INF-19).
 * Prometheus 는 VPC 안이라 ALB 가 죽어도 앱 지표는 정상으로 보인다. 그 사각지대를 메운다.
 */
resource "aws_route53_health_check" "endpoint" {
  count = local.has_domain ? 1 : 0

  fqdn              = var.domain_name
  type              = "HTTPS"
  port              = 443
  resource_path     = "/actuator/health/liveness"
  request_interval  = 30
  failure_threshold = 2

  tags = {
    Name = "${var.project}-endpoint"
  }
}
