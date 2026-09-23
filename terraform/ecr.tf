/*
 * 앱 이미지 저장소다. GHCR 에서 옮겨 왔다.
 *
 * 옮긴 이유는 호스트에서 장기 자격증명을 없애는 것이다. GHCR 은 패키지가 비공개라
 * 인스턴스가 SSM 에 둔 토큰으로 docker login 을 해야 했고, 그 토큰은 만료와 회전을
 * 사람이 관리해야 했다. ECR 은 인스턴스 프로파일이 곧 pull 권한이라 그 토큰이 사라진다.
 *
 * 부수적으로 장애 도메인이 같아진다. 이벤트 직전에 전용 ASG 를 올리는 구조라
 * (scripts/coupon-event.sh), 레지스트리가 AWS 밖이면 그쪽 장애가 곧 이벤트를 못 여는 것이 된다.
 */

resource "aws_ecr_repository" "app" {
  name = var.project

  /*
   * 태그를 덮어쓰지 못하게 한다.
   *
   * 배포가 커밋 SHA 를 태그로 쓰고, 어느 인스턴스가 어느 버전인지 태그로 판단한다
   * (docs/deploy/backend-deploy-workflow.yml). 같은 태그에 다른 이미지가 들어갈 수 있으면
   * 그 판단이 거짓이 되고 롤백 대상도 흔들린다.
   */
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = var.project
  }
}

/*
 * 이미지를 지우는 규칙이다. 없으면 무한히 쌓인다.
 *
 * latest 를 안 쓰고 커밋 SHA 로만 태그하므로 배포마다 새 이미지가 생기고 겹치지 않는다.
 * GHCR 일 때는 GitHub 이 알아서 하던 자리라 이 규칙이 없었다.
 *
 * 30개를 남기는 것은 롤백 범위다. deploy.sh 가 되돌릴 수 있는 것은 직전 SHA 하나지만,
 * 사람이 콘솔에서 더 뒤로 갈 수 있어야 한다. 하루 몇 번 배포면 한 주 남는 셈이다.
 */
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
