/*
 * ElastiCache Valkey 9.0 (INF-03).
 * Redis OSS 가 아닌 이유는 ElastiCache 의 Redis OSS 가 7.1 에서 동결됐기 때문이다.
 * 9.0 인 이유는 해시 필드 만료가 거기서 들어왔기 때문이다.
 *
 * 단일 노드라도 replication_group 으로 만든다 (INF-36).
 * 복제본 추가는 replication group 에만 되고, 나중에 바꾸려면 이관이 필요하다.
 * 지금 정하면 비용 차이가 0 이다.
 *
 * 그 판단이 실제로 값을 했다. 복제본을 붙일 때 이관도 재생성도 없었다.
 */

# AZ-a 만 등록했다면 Multi-AZ 를 켤 때 서브넷 그룹부터 고쳐야 했다.
resource "aws_elasticache_subnet_group" "main" {
  name        = "${var.project}-cache"
  description = "private subnets in 2 AZ. primary in a, replica in c"
  subnet_ids  = [for s in aws_subnet.private : s.id]
}

resource "aws_elasticache_parameter_group" "main" {
  name        = "${var.project}-valkey90"
  family      = "valkey9"
  description = "defaults only. nothing to tune for cache use"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project}-cache"
  description          = "read cache. Degradable grade in normal operation"

  engine         = "valkey"
  engine_version = "9.0"
  node_type      = var.cache_node_type
  port           = 6379

  /*
   * 프라이머리 AZ-a, 복제본 AZ-c 다 (INF-37). 단일 노드 전제였던 INF-04 를 대체한 결정이다.
   *
   * 이관 없이 여기까지 온 것은 노드가 하나일 때부터 replication group 으로 만들어 뒀기 때문이다 (INF-36).
   * aws_elasticache_cluster 로 시작했다면 이 변경이 재생성이었다.
   *
   * automatic_failover 와 multi_az 는 짝이다. multi_az 만 켜면 AWS 가 거절한다.
   */
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  /*
   * 순서가 의미를 갖는다. 첫 원소가 프라이머리다.
   * 서브넷 그룹에 두 AZ 를 미리 등록해 둔 덕에 여기만 늘리면 된다.
   */
  preferred_cache_cluster_azs = [var.azs["a"], var.azs["c"]]

  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.cache.id]
  parameter_group_name = aws_elasticache_parameter_group.main.name

  at_rest_encryption_enabled = true

  /*
   * 전송 암호화를 켜지 않는다.
   * 켜면 클라이언트가 TLS 로 붙어야 하는데 지금 앱에 캐시 클라이언트 자체가 없다.
   * 같은 VPC 안이고 보안 그룹이 앱과 모니터링만 허용한다.
   */
  transit_encryption_enabled = false

  maintenance_window       = "sun:20:30-sun:21:30"
  snapshot_retention_limit = 0

  /*
   * 9.0 에서 9.1 로 올라가지 못하게 한다.
   * 기술 스택 3.2절이 "9-alpine 을 쓰면 안 된다. 그 태그는 9.1 로 풀린다" 고 못 박았다.
   * 로컬 이미지를 9.0 으로 고정해 두고 운영만 올라가면 동작이 갈린다.
   */
  auto_minor_version_upgrade = false

  tags = {
    Name = "${var.project}-cache"
  }
}
