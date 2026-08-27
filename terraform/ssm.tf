/*
 * 런타임에 바뀌는 값들이다. 스크립트가 채우고 Terraform 은 자리만 만든다.
 *
 * 시크릿(SecureString 8개)은 여기 없다. bootstrap/ 이 갖는다.
 * 파괴해도 살아남아야 재구축 때 다시 넣지 않는다. 표준 파라미터라 유지 비용도 0 이다.
 */

locals {
  ssm_prefix = "/${var.project}"
}

/*
 * ASG 가 인스턴스를 교체할 때 어느 버전을 띄울지 여기서 읽는다 (INF-25).
 * 값은 배포 스크립트가 갱신하므로 Terraform 이 건드리면 안 된다.
 * ignore_changes 가 없으면 다음 apply 가 bootstrap 으로 되돌려 전 인스턴스가 구버전으로 기동한다.
 */
resource "aws_ssm_parameter" "current_sha" {
  name        = "${local.ssm_prefix}/current-sha"
  description = "currently deployed commit SHA"
  type        = "String"
  value       = "bootstrap"

  lifecycle {
    ignore_changes = [value]
  }
}

/*
 * RDS 복원은 항상 새 인스턴스를 만들어 엔드포인트가 바뀐다 (INF-26).
 * 초기값은 Terraform 이 넣지만 복원 후 갱신은 CLI 가 한다.
 */
resource "aws_ssm_parameter" "db_endpoint" {
  name        = "${local.ssm_prefix}/db-endpoint"
  description = "DB endpoint for app and batch"
  type        = "String"
  value       = "unset"

  lifecycle {
    ignore_changes = [value]
  }
}

/*
 * 앱이 이미지 URL 을 조립할 때 붙이는 CDN 주소 (이미지 저장소 설계 3장).
 * 도메인을 안 붙인 배포는 CloudFront 가 매번 새 dxxxx.cloudfront.net 을 발급한다.
 * 재구축마다 앱 설정을 손으로 고치지 않으려고 여기를 거친다.
 */
resource "aws_ssm_parameter" "cdn_domain" {
  name        = "${local.ssm_prefix}/cdn-domain"
  description = "CloudFront domain for image URLs"
  type        = "String"
  value       = "unset"

  lifecycle {
    ignore_changes = [value]
  }
}

/*
 * 앱과 redis_exporter 가 붙을 주소. RDS 와 같은 이유로 복원 시 바뀔 수 있다.
 * 앱에는 VALKEY_HOST 라는 이름으로 들어간다. 앱이 로컬 compose 와 변수명을 맞춰 둔 것을 따른다.
 */
resource "aws_ssm_parameter" "cache_endpoint" {
  name        = "${local.ssm_prefix}/cache-endpoint"
  description = "cache endpoint for app and monitoring"
  type        = "String"
  value       = "unset"

  lifecycle {
    ignore_changes = [value]
  }
}

/*
 * Alloy 가 로그를 밀어 넣을 주소다.
 * 모니터링은 ASG 밖 고정 인스턴스라 Terraform 이 IP 를 안다.
 * 앱 시작 템플릿에 박지 않고 SSM 을 거치는 이유는, 박으면 IP 가 바뀔 때 템플릿을 다시 렌더링해야 하기 때문이다.
 */
resource "aws_ssm_parameter" "loki_endpoint" {
  name        = "${local.ssm_prefix}/loki-endpoint"
  description = "Loki address for Alloy log push"
  type        = "String"
  value       = aws_instance.monitoring.private_ip
}

/*
 * Grafana 가 자기 주소를 아는 경로다.
 * ROOT_URL 이 틀리면 로그인 후 리디렉션과 패널 공유 링크가 localhost 로 간다.
 *
 * 값을 인스턴스에 박지 않고 SSM 을 거치는 이유는 loki-endpoint 와 같다.
 * 박으면 도메인을 붙이거나 떼는 것이 user-data 재렌더링과 인스턴스 재생성이 된다.
 * 여기를 거치면 refresh-monitoring-env 가 읽어 .env 를 다시 쓰고 컨테이너만 재시작하면 된다.
 */
resource "aws_ssm_parameter" "grafana_root_url" {
  name        = "${local.ssm_prefix}/grafana-root-url"
  description = "Grafana external URL. unset means SSM port forwarding only"
  type        = "String"
  value       = local.grafana_root_url
}

/*
 * 인증 프록시를 켤지 여기서 정한다.
 *
 * 주소가 있다고 켜면 안 된다. DuckDNS 경로에는 ALB 가 없어 X-Amzn-Oidc-Identity 헤더가
 * 오지 않고, 켜 두면 아무도 로그인하지 못한다. 헤더를 실어 주는 것은 OIDC 리스너 규칙뿐이다.
 */
resource "aws_ssm_parameter" "grafana_auth_proxy" {
  name        = "${local.ssm_prefix}/grafana-auth-proxy"
  description = "whether ALB puts the OIDC identity header in front of Grafana"
  type        = "String"
  value       = local.has_grafana ? "true" : "false"
}

# Caddy 가 어느 이름으로 인증서를 받을지 알아야 한다. 비어 있으면 Caddy 를 띄우지 않는다.
resource "aws_ssm_parameter" "duckdns_hostname" {
  name        = "${local.ssm_prefix}/duckdns-hostname"
  description = "DuckDNS hostname for the Caddy TLS front. unset when unused"
  type        = "String"
  value       = local.has_duckdns ? var.duckdns_hostname : "unset"
}
