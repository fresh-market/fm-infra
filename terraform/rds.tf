/*
 * MySQL 8.4, db.t4g.micro, Multi-AZ (기술 스택 확정 문서 2.6절).
 * AZ 를 고정하지 않는다. 페일오버로 primary 와 standby 가 뒤바뀐다.
 */

resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-db"
  description = "private subnets in 2 AZ. required for Multi-AZ"
  subnet_ids  = [for s in aws_subnet.private : s.id]

  tags = {
    Name = "${var.project}-db"
  }
}

/*
 * max_connections 를 지정하지 않는다.
 * 기본 파라미터 그룹의 공식({DBInstanceClassMemory/12582880})을 그대로 쓴다.
 * 1 GiB 에서 커넥션당 12MB 라 공식보다 높게 잡으면 OOM 이 난다. 예측값은 약 60 이다.
 *
 * 콜레이션은 협상 대상이 아니다.
 * 스키마가 상태 컬럼마다 utf8mb4_0900_as_cs 를 명시하고 서버 기본은 ai_ci 여야 한다.
 */
resource "aws_db_parameter_group" "main" {
  name        = "${var.project}-mysql84"
  family      = "mysql8.4"
  description = "collation and slow query log only"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_0900_ai_ci"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  # 부하 시험에서 느린 쿼리를 찾는 것이 목적이라 기본 10초는 너무 길다.
  parameter {
    name  = "long_query_time"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier = "${var.project}-db"
  engine     = "mysql"

  /*
   * 마이너까지 박는다. auto_minor_version_upgrade 를 껐으므로 여기가 유일한 출처다.
   * 2026-08-20 조회 기준 8.4 라인의 최신이고 db.t4g.micro 와 gp3 를 지원한다.
   * aws rds describe-db-engine-versions --engine mysql --engine-version 8.4
   */
  engine_version = "8.4.11"

  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username

  /*
   * 비밀번호를 Terraform 이 만들지 않는다.
   * manage_master_user_password 는 Secrets Manager 를 쓰는데 시크릿당 월 0.40 USD 다 (INF-11).
   * SSM 에 넣은 값을 apply 시점에 넘긴다.
   */
  password = data.aws_ssm_parameter.db_password.value

  /*
   * 스토리지 자동 확장을 켜지 않는다.
   * 예산을 항목마다 근거로 잡는 프로젝트에서 근거 없이 늘어나는 유일한 자리가 된다.
   * 20GB 로 부족해지면 그때 값을 올린다.
   */
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # true 면 동기 복제라 커밋 손실이 없다. 구축 초기에는 false 로 시작한다.
  multi_az = var.db_multi_az

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  # PITR 보존. 확정값은 7일이고 프리 티어에서만 낮춘다.
  backup_retention_period = var.db_backup_retention_days
  backup_window           = var.db_backup_window
  maintenance_window      = var.db_maintenance_window

  /*
   * 자동 백업은 인스턴스를 지우면 함께 사라진다.
   * 최종 스냅샷을 건너뛰면 되돌릴 수단이 없다.
   */
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-db-final"

  # 일반 로그는 켜지 않는다. 부하 시험 중 GB 단위로 늘어난다.
  enabled_cloudwatch_logs_exports = ["slowquery"]

  /*
   * 마이너 버전을 AWS 가 올리지 못하게 한다.
   * 기술 스택 6장이 "latest 태그는 어디에도 쓰지 않는다" 고 못 박았고
   * mysql:8.4 와 valkey:9.0-alpine 도 같은 이유로 고정했다. RDS 만 예외로 둘 이유가 없다.
   */
  auto_minor_version_upgrade = false

  tags = {
    Name = "${var.project}-db"
  }

  lifecycle {
    prevent_destroy = true

    /*
     * 파라미터를 만들 때 자리만 unset 으로 채웠다.
     * 실제 값을 넣지 않고 apply 하면 그 문자열이 그대로 마스터 비밀번호가 된다.
     */
    precondition {
      condition     = data.aws_ssm_parameter.db_password.value != "unset"
      error_message = "aws ssm put-parameter --name /${var.project}/db-password --type SecureString --value '<비밀번호>' --overwrite 를 먼저 실행하라."
    }
  }
}

/*
 * 파라미터 자체는 bootstrap/ 이 만든다. 여기서는 이름으로만 참조한다.
 * 시크릿을 그쪽에 둔 이유는 destroy 를 견디게 하기 위해서다. 표준 파라미터라 유지 비용이 0 인데,
 * 지우면 재구축 때 11개를 손으로 다시 넣어야 한다.
 *
 * 구성이 갈라져 Terraform 이 순서를 세워 주지 못한다. bootstrap 을 먼저 apply 해야 한다.
 * 안 하면 아래 lifecycle 의 안내가 아니라 "couldn't find resource" 만 보게 된다.
 * data 소스가 precondition 보다 먼저 평가되기 때문이다.
 */
data "aws_ssm_parameter" "db_password" {
  name = "${local.ssm_prefix}/db-password"

  lifecycle {
    postcondition {
      condition     = self.value != "unset"
      error_message = "aws ssm put-parameter --name ${self.name} --type SecureString --value '<비밀번호>' --overwrite 를 먼저 실행하라."
    }
  }
}

/*
 * 로그 그룹은 RDS 가 자동 생성하는데 보존 기간이 무기한이다.
 * Terraform 이 먼저 만들어 보존을 강제한다 (알람과 알림 설계 3.3절).
 */
resource "aws_cloudwatch_log_group" "rds_slowquery" {
  name              = "/aws/rds/instance/${var.project}-db/slowquery"
  retention_in_days = 30

  tags = {
    Name = "${var.project}-db-slowquery"
  }
}
