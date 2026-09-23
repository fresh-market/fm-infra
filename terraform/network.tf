/*
 * 한때 NAT Gateway 를 쓰지 않았다 (INF-09). 월 40 USD 가 전체 예산의 4분의 1이라 앱을
 * 퍼블릭 서브넷에 두고 보안 그룹만으로 막았다.
 *
 * 그 판단을 뒤집었다. 보안 그룹이 유일한 방어선이면 규칙 하나를 실수로 0.0.0.0/0 으로 여는
 * 순간 인터넷에 노출된다. 사설 서브넷은 경로 자체가 없어 그 실수를 무르게 한다.
 *
 * NAT 는 한 대뿐이다. AZ 당 하나가 운영 표준이지만 두 배 값이고, 이 규모에서는 그 AZ 가
 * 죽는 경우보다 비용이 먼저 아프다. 대신 그 AZ 가 죽으면 양쪽 사설 서브넷이 다 못 나간다.
 * 카카오 로그인이 멈춘다는 뜻이다.
 *
 * ALB 와 부하 생성기는 퍼블릭에 남는다. ALB 는 인터넷을 받는 자리라 옮길 수 없고,
 * 부하 생성기는 사설로 가면 인터넷 대면 ALB 를 부를 때 NAT 를 왕복해 요금과 측정 변수가
 * 함께 는다. 시험 도구라 운영 구성요소도 아니다.
 */

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-igw"
  }
}

# ALB, NAT, 부하 생성기가 여기 있다. 앱과 배치와 모니터링은 사설로 옮겼다.
resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = var.azs[each.key]

  # NAT 가 없으므로 인스턴스가 퍼블릭 IP 로 직접 나간다.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${each.key}"
    Tier = "public"
  }
}

# RDS 와 ElastiCache 가 여기 있다. 나갈 일이 없다.
resource "aws_subnet" "private" {
  for_each = var.private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = var.azs[each.key]

  tags = {
    Name = "${var.project}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-public"
  }
}

/*
 * NAT 는 퍼블릭 서브넷에 있어야 한다. 자기 자신이 IGW 로 나갈 수 있어야 남을 내보낸다.
 */
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-nat"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  # IGW 가 먼저 붙어 있어야 만들어진다. 암묵적 의존이 안 잡혀 명시한다.
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project}-nat"
  }
}

/*
 * 사설 서브넷의 나갈 길이다.
 *
 * RDS 와 캐시는 나갈 일이 없지만 같은 라우팅 테이블을 쓴다. 나갈 길이 있어도 보안 그룹이
 * 아웃바운드를 막지 않는 한 쓰지 않을 뿐이다. 서브넷을 더 쪼개 얻는 것보다 단순함이 낫다.
 */
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project}-private"
  }
}

/*
 * S3 는 게이트웨이 엔드포인트로 뺀다. 시간당 요금이 없어 공짜다.
 *
 * ECR 이미지 레이어의 실체가 S3 에 있다. 이걸 안 붙이면 인스턴스가 뜰 때마다 이미지 전체가
 * NAT 의 데이터 처리 요금을 탄다. 선착순 이벤트는 전용 3대를 한꺼번에 올리므로 그 순간에 몰린다.
 */
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.project}-s3"
  }
}

resource "aws_route_table_association" "public" {
  # 키를 서브넷 리소스가 아니라 원본 맵에서 가져온다. 리소스를 쓰면 apply 전에 키를 알 수 없다.
  for_each = var.public_subnet_cidrs

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = var.private_subnet_cidrs

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}
