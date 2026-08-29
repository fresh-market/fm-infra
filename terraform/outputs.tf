# 배포 스크립트와 preflight 스크립트가 이 값들을 읽는다.

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID. ASG 와 인스턴스가 쓴다"
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID. RDS 와 캐시 서브넷 그룹이 쓴다"
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "security_group_ids" {
  description = "역할별 보안 그룹 ID"

  value = {
    alb      = aws_security_group.alb.id
    app      = aws_security_group.app.id
    db       = aws_security_group.db.id
    cache    = aws_security_group.cache.id
    mon      = aws_security_group.mon.id
    batch    = aws_security_group.batch.id
    loadtest = aws_security_group.loadtest.id
  }
}

output "db_endpoint" {
  description = "SSM db-endpoint 파라미터에 넣을 값"
  value       = aws_db_instance.main.address
}

output "cache_endpoint" {
  description = "앱이 접속할 캐시 주소"
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "alb_dns_name" {
  description = "도메인이 없을 때 접속할 주소"
  value       = aws_lb.main.dns_name
}

output "asg_name" {
  description = "배포 스크립트가 desired 를 조절할 대상"
  value       = aws_autoscaling_group.app.name
}

output "target_group_arn" {
  description = "배포 스크립트가 healthy 수를 확인할 대상"
  value       = aws_lb_target_group.app.arn
}

output "media_bucket" {
  description = "이미지 버킷 이름"
  value       = aws_s3_bucket.media.id
}

output "cdn_domain" {
  description = "앱의 cdn.base-url 에 넣을 값"
  value       = aws_cloudfront_distribution.media.domain_name
}

/*
 * 팀원에게 알려줄 주소다.
 * 비어 있으면 아직 SSM 포트 포워딩으로만 볼 수 있다는 뜻이다.
 */
output "grafana_url" {
  description = "Grafana 접속 주소. 비어 있으면 SSM 포트 포워딩으로만 볼 수 있다"
  value       = local.grafana_root_url == "unset" ? "" : local.grafana_root_url
}

# DuckDNS 화면의 current ip 에 넣을 값이다. 이 주소로 인증서가 발급된다.
output "monitoring_public_ip" {
  description = "모니터링 인스턴스 고정 IP. DuckDNS 를 쓸 때만 값이 생긴다"
  value       = local.has_duckdns ? aws_eip.monitoring[0].public_ip : ""
}

/*
 * 이벤트 운영이 대수를 조절할 대상이다.
 * 버스트에는 스케일링 정책이 못 따라오므로 이벤트 전에 이 ASG 의 desired 를 직접 올린다.
 *
 *   aws autoscaling set-desired-capacity --auto-scaling-group-name <이 값> --desired-capacity 3
 */
output "coupon_asg_name" {
  description = "선착순 전용 ASG 이름. 전용 경로를 끄면 비어 있다"
  value       = var.coupon_dedicated_enabled ? aws_autoscaling_group.coupon[0].name : ""
}
