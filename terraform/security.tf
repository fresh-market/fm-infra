/*
 * 앱이 퍼블릭 서브넷에 있으므로 보안은 서브넷이 아니라 보안 그룹이 확보한다.
 * 그래서 인바운드는 CIDR 이 아니라 보안 그룹 참조로만 연다. 인터넷을 받는 ALB 만 예외다.
 * 22번 포트는 어디에도 열지 않는다. 운영 접근은 SSM Session Manager 로 한다 (INF-12).
 */

/*
 * 보안 그룹 설명은 ASCII 만 받는다. AWS 가 한글을 거부한다.
 * 규칙 설명도 마찬가지다. 주석은 한글로 두고 AWS 에 올라가는 문자열만 영어로 쓴다.
 */
locals {
  sg_names = {
    alb      = "public entry point. 443 and 80 from internet"
    app      = "8080 from ALB, 8081 from ALB and monitoring"
    db       = "3306 from app, batch, monitoring"
    cache    = "6379 from app and monitoring"
    mon      = "3100 only. Alloy pushes logs to Loki"
    batch    = "no inbound"
    loadtest = "no inbound"
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = local.sg_names.alb
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-alb"
  }
}

resource "aws_security_group" "app" {
  name        = "${var.project}-app"
  description = local.sg_names.app
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-app"
  }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = local.sg_names.db
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-db"
  }
}

resource "aws_security_group" "cache" {
  name        = "${var.project}-cache"
  description = local.sg_names.cache
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-cache"
  }
}

resource "aws_security_group" "mon" {
  name        = "${var.project}-mon"
  description = local.sg_names.mon
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-mon"
  }
}

resource "aws_security_group" "batch" {
  name        = "${var.project}-batch"
  description = local.sg_names.batch
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-batch"
  }
}

resource "aws_security_group" "loadtest" {
  name        = "${var.project}-loadtest"
  description = local.sg_names.loadtest
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-loadtest"
  }
}

# 인터넷에서 들어오는 유일한 자리다. 80 은 리스너가 443 으로 넘긴다.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from internet"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "redirected to 443 by listener"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "traffic from ALB target group"
}

/*
 * 액추에이터를 8081 로 분리했다.
 * ALB 는 헬스체크를, Prometheus 는 /actuator/prometheus 를 여기로 찌른다.
 * 이 포트가 밖으로 열리면 관리 포트로 나눈 의미가 사라진다 (INF-12-21).
 */
resource "aws_vpc_security_group_ingress_rule" "app_mgmt_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "ALB health check and liveness path"
}

# 이 규칙이 없으면 앱 지표가 통째로 사라진다.
resource "aws_vpc_security_group_ingress_rule" "app_mgmt_from_mon" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "Prometheus scrape"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "app connection pool"
}

/*
 * node_exporter 와 cAdvisor 는 앱과 배치 인스턴스에도 뜬다.
 * 그 호스트의 CPU 크레딧과 컨테이너 상태를 봐야 하므로 모니터링이 여기로 긁는다.
 * 포트는 observability/README.md 가 정한다. cAdvisor 기본값 8080 은 앱과 겹쳐 8082 로 옮겼다.
 */
resource "aws_vpc_security_group_ingress_rule" "exporters_from_mon" {
  for_each = {
    app_node       = { sg = aws_security_group.app.id, port = 9100, desc = "node_exporter" }
    app_cadvisor   = { sg = aws_security_group.app.id, port = 8082, desc = "cAdvisor" }
    batch_node     = { sg = aws_security_group.batch.id, port = 9100, desc = "node_exporter" }
    batch_cadvisor = { sg = aws_security_group.batch.id, port = 8082, desc = "cAdvisor" }
    batch_mgmt     = { sg = aws_security_group.batch.id, port = 8081, desc = "actuator" }
  }

  security_group_id            = each.value.sg
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = each.value.desc
}

/*
 * SG-mon 의 인바운드 둘 중 하나다.
 * Alloy 가 각 인스턴스에서 로그를 읽어 Loki 로 밀어 넣는다. 방향이 다른 것들과 반대다.
 * 스크랩은 모니터링이 나가는 연결이지만 로그는 들어오는 연결이다.
 */
resource "aws_vpc_security_group_ingress_rule" "loki_from_hosts" {
  for_each = {
    app   = aws_security_group.app.id
    batch = aws_security_group.batch.id
  }

  security_group_id            = aws_security_group.mon.id
  referenced_security_group_id = each.value
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "Alloy log push"
}

/*
 * SG-mon 의 인바운드 하나가 더 는다. k6 가 시험 결과를 remote write 로 밀어 넣는다.
 *
 * 부하 생성기에서만 온다. Prometheus 는 원래 긁어오기만 하고 받지 않는 물건이라,
 * 받는 입구를 여는 이상 출처를 좁혀 둔다. 시험 시간에만 뜨는 인스턴스다.
 */
resource "aws_vpc_security_group_ingress_rule" "prometheus_from_loadtest" {
  security_group_id            = aws_security_group.mon.id
  referenced_security_group_id = aws_security_group.loadtest.id
  from_port                    = 9090
  to_port                      = 9090
  ip_protocol                  = "tcp"
  description                  = "k6 remote write"
}

/*
 * Grafana 를 ALB 뒤에 붙일 때만 열린다.
 * 출처가 SG-alb 뿐이라는 것이, Grafana 가 X-Amzn-Oidc-Identity 헤더를 믿어도 되는 근거다.
 * 다른 경로로 3000 에 닿을 수 없으니 헤더를 위조해 넣을 상대가 없다.
 */
resource "aws_vpc_security_group_ingress_rule" "grafana_from_alb" {
  count = local.has_grafana ? 1 : 0

  security_group_id            = aws_security_group.mon.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  description                  = "Grafana via ALB"
}

# 배치가 DB 에 못 붙으면 아무 일도 못 한다.
resource "aws_vpc_security_group_ingress_rule" "db_from_batch" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.batch.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "batch connection pool"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_mon" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "mysqld_exporter"
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_app" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "app cache access"
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_mon" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "redis_exporter"
}

/*
 * 아웃바운드는 전부 열어 둔다.
 * GHCR 이미지 pull, SSM Parameter Store 조회, 패키지 설치가 인터넷으로 나간다.
 * 프라이빗 서브넷의 RDS 와 캐시는 라우팅에 기본 경로가 없어 실제로는 나가지 못한다.
 */
resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    alb      = aws_security_group.alb.id
    app      = aws_security_group.app.id
    db       = aws_security_group.db.id
    cache    = aws_security_group.cache.id
    mon      = aws_security_group.mon.id
    batch    = aws_security_group.batch.id
    loadtest = aws_security_group.loadtest.id
  }

  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "allow all outbound"
}

/*
 * Caddy 가 Let's Encrypt 에서 인증서를 받는 경로다 (HTTP-01).
 * 검증 요청이 전 세계 여러 IP 에서 오므로 대역을 좁힐 수 없다.
 *
 * 80 은 챌린지 응답과 443 리다이렉트만 한다. Grafana 로 넘기지 않는다.
 */
resource "aws_vpc_security_group_ingress_rule" "caddy_acme" {
  count = local.has_duckdns ? 1 : 0

  security_group_id = aws_security_group.mon.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  # 아포스트로피는 AWS 가 규칙 설명에서 거부한다. 허용 집합은 a-zA-Z0-9._-:/()#,@[]+=&;{}!$* 다.
  description = "ACME HTTP-01 challenge for Caddy"
}

/*
 * 팀원이 Grafana 를 보는 문이다.
 * 인증 전 요청은 Caddy 의 basic_auth 가 막으므로 Grafana 까지 닿지 않는다.
 */
resource "aws_vpc_security_group_ingress_rule" "caddy_https" {
  for_each = local.has_duckdns ? toset(var.grafana_https_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.mon.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Grafana via Caddy"
}
