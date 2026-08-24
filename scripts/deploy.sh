#!/usr/bin/env bash
#
# 인스턴스 단위 롤링 배포. 절차는 docs/system-design/백엔드공통_무중단배포_롤링.md 6절이다.
#
# 신규를 먼저 띄우고 검증한 뒤 구 인스턴스를 지운다.
# 그래서 배포 중 용량이 100% 로 유지되고, 실패해도 구 버전이 계속 서비스한다.
#
# Terraform 이 하지 않는 일을 여기서 한다.
# SSM 값 갱신, desired 조정, 대상 등록 해제가 그것이다. 경계는 무중단배포 5절에 있다.
#
#   ./deploy.sh              fm-backend main 의 최신 커밋을 배포한다
#   ./deploy.sh <커밋 SHA>   그 커밋을 배포한다. 롤백도 이 형태다

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ASG="$PROJECT-app"
BACKEND_REPO="${BACKEND_REPO:-fresh-market/fm-backend}"

# 신규가 healthy 가 될 때까지 기다리는 상한. 기동이 4~6분이라 여유를 둔다.
HEALTHY_TIMEOUT=360

# 스모크로 찌를 경로다. 6번은 인스턴스 안에서, 7번은 ALB 를 거쳐 같은 경로를 본다.
# 호스트는 정하지 않는다. ALB 주소는 재구축마다 바뀌므로 7번에서 그때 조회한다.
SMOKE_PATH="${SMOKE_PATH:-/v1/products}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 인자를 주지 않으면 main 의 최신 커밋을 쓴다.
#
# 워크플로는 항상 SHA 를 넘기므로 이 경로는 사람이 손으로 돌릴 때만 탄다.
# 재구축 직후가 그렇다. 그때 필요한 것은 "지금 main 에 있는 것"이고,
# 그 값을 사람이 찾아 붙여넣게 하면 옛 커밋을 배포하는 실수가 생긴다.
#
# 로컬 클론이 아니라 GitHub 에 묻는다. 손에 있는 클론은 낡았을 수 있다.
SHA="${1:-}"
if [ -z "$SHA" ]; then
  SHA=$(gh api "repos/$BACKEND_REPO/commits/main" --jq .sha 2>/dev/null || true)
  [ -n "$SHA" ] || die "main 최신 커밋을 찾지 못했다. gh 로그인을 확인하거나 SHA 를 직접 넘겨라"
  log "인자가 없어 $BACKEND_REPO main 최신을 쓴다"
fi

tg_arn=$(aws elbv2 describe-target-groups --names "$PROJECT-app" \
  --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text)

healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$REGION" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text
}

instance_ids() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --region "$REGION" --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text
}

# 0. 사전 상태 점검. 실패하면 여기서 끝난다.
log "0. 사전 점검"
"$(dirname "$0")/preflight.sh" deploy

# 1. 이미지는 워크플로가 이미 GHCR 에 올렸다. 여기서는 존재만 전제한다.
log "1. 이미지 태그 $SHA"

# 2. SSM 을 먼저 갱신한다.
#    교체보다 먼저여야 신규 인스턴스가 새 버전으로 뜬다. 순서가 뒤바뀌면 구 버전이 올라온다.
log "2. SSM current-sha 갱신"
aws ssm put-parameter --name "/$PROJECT/current-sha" --value "$SHA" \
  --type String --overwrite --region "$REGION" > /dev/null

# 3. 구 인스턴스 목록을 기록한다. 나중에 이것만 지운다.
old_ids=$(instance_ids)
log "3. 구 인스턴스: $old_ids"

before=$(healthy_count)
desired=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --region "$REGION" --query 'AutoScalingGroups[0].DesiredCapacity' --output text)

# 4. desired 를 하나 올린다. 신규는 2번에서 갱신한 SHA 로 뜬다.
log "4. desired $desired -> $((desired + 1))"
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
  --desired-capacity "$((desired + 1))" --region "$REGION"

# 5. 신규가 healthy 가 될 때까지 기다린다.
log "5. healthy 대기 (상한 ${HEALTHY_TIMEOUT}초)"
deadline=$(( $(date +%s) + HEALTHY_TIMEOUT ))
while [ "$(healthy_count)" -le "$before" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "실패. 신규가 healthy 가 되지 않았다. 구 버전은 그대로 서비스 중이다."
    log "desired 를 되돌린다."
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
      --desired-capacity "$desired" --region "$REGION"
    exit 1
  fi
  sleep 10
done
log "   healthy $(healthy_count)"

# 6, 7. 스모크 테스트.
#      신규 인스턴스를 지목해 찌르고 도메인으로도 찌른다.
#      지목하는 이유는 ALB 를 거치면 어느 인스턴스가 답했는지 알 수 없기 때문이다.
#
#      인스턴스 안에서 돌린다. 이 스크립트는 GitHub Actions 러너에서 도는데
#      러너는 VPC 밖이라 사설 IP 에 닿지 못하고, 보안 그룹도 8081 을 ALB 와 모니터링에만 연다.
#      밖에서 찌를 방법이 없으므로 SSM 으로 명령을 보내 localhost 를 찌르게 한다.
#
#      8080 을 본다. 8081 readiness 는 ALB 헬스체크가 이미 보고 있어(5번이 그것을 기다린다)
#      같은 것을 두 번 확인하는 셈이고, 실제로 요청을 받는 포트는 8080 이다.
new_ids=$(comm -13 <(echo "$old_ids" | tr '\t' '\n' | sort) <(instance_ids | tr '\t' '\n' | sort))
for id in $new_ids; do
  log "6. 스모크 (인스턴스 안에서) $id"
  smoke_cmd=$(aws ssm send-command \
    --instance-ids "$id" \
    --document-name AWS-RunShellScript \
    --region "$REGION" \
    --parameters "commands=[\"curl -fsS --max-time 5 http://localhost:8080$SMOKE_PATH > /dev/null\"]" \
    --query 'Command.CommandId' --output text)

  smoke_status=Pending
  for _ in $(seq 1 20); do
    sleep 3
    smoke_status=$(aws ssm get-command-invocation --command-id "$smoke_cmd" \
      --instance-id "$id" --region "$REGION" --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$smoke_status" in Success|Failed|TimedOut|Cancelled) break ;; esac
  done

  if [ "$smoke_status" != "Success" ]; then
    log "실패($smoke_status). 신규만 종료하고 구 버전을 유지한다."
    aws ssm get-command-invocation --command-id "$smoke_cmd" --instance-id "$id" \
      --region "$REGION" --query 'StandardErrorContent' --output text 2>/dev/null || true
    aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" \
      --should-decrement-desired-capacity --region "$REGION" > /dev/null
    exit 1
  fi
done

# 7. ALB 를 경유해 한 번 더 찌른다. 6번이 인스턴스 직접이라 경로 전체를 보지 못한다.
#
# 주소를 밖에서 받지 않고 여기서 조회한다.
# ALB 를 다시 만들면 DNS 이름이 바뀌는데, 그 값을 GitHub 변수에 박아 두면
# 재구축마다 사람이 고쳐야 하고 안 고치면 여기서 호스트가 풀리지 않아 배포가 죽는다.
# 배포 역할에 elasticloadbalancing:DescribeLoadBalancers 가 이미 있어 그냥 물어보면 된다.
#
# 밖에서 정하는 것은 경로뿐이다. 경로는 재구축과 무관하게 안정적이다.
# 도메인을 붙이면 이 조회가 필요 없어지지만 그때까지는 이쪽이 맞다.
alb_dns=$(aws elbv2 describe-load-balancers --names "$PROJECT-alb" \
  --region "$REGION" --query 'LoadBalancers[0].DNSName' --output text)
log "7. 스모크 (ALB 경유) http://$alb_dns$SMOKE_PATH"
curl -fsS --max-time 10 "http://$alb_dns$SMOKE_PATH" > /dev/null

# 9. 3번에서 기록한 구 인스턴스만 종료한다.
#    desired 를 함께 줄여 원래 대수로 돌아간다.
#
#    그 인스턴스가 이미 없을 수 있다. 구 버전이 unhealthy 인 상태로 배포를 시작하면
#    (재구축 직후 current-sha 가 bootstrap 이라 이미지를 못 받는 경우가 그렇다)
#    ASG 가 5번 대기 중에 자기 판단으로 먼저 교체해 버린다.
#
#    그때 뜬 교체분은 2번에서 current-sha 를 갱신한 뒤에 부팅했으므로 이미 새 이미지다.
#    지울 이유가 없고, 남은 일은 4번에서 올린 desired 를 되돌리는 것뿐이다.
#    이것을 실패로 두면 앱이 멀쩡한데 배포만 실패로 보고된다.
for id in $old_ids; do
  log "9. 구 인스턴스 종료 $id"
  aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" \
    --should-decrement-desired-capacity --region "$REGION" > /dev/null 2>&1 && continue

  log "   이미 없다. ASG 가 먼저 교체했다. desired 만 $desired 로 되돌린다"
  aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
    --desired-capacity "$desired" --region "$REGION" > /dev/null
done

# 10. 배치 인스턴스를 교체한다.
#
#     배치는 롤링 대상이 아니다. 중지 후 교체한다.
#     롤링으로 하면 구버전과 신버전 배치가 겹쳐 "프로세스는 항상 하나" 전제가 깨진다.
#
#     앱보다 뒤에 하는 이유는 스키마 확장 후 축소 때문이다.
#     앱이 먼저 새 버전이 되어야 배치가 새 스키마를 전제해도 안전하다.
#
#     user-data 는 최초 부팅에만 돈다. 그냥 재시작하면 부팅 때 읽은 옛 값으로 다시 뜬다.
#     refresh-env 가 SSM 을 다시 읽어 .env 를 통째로 만든다.
#     GIT_SHA 만 고치면 DB 엔드포인트가 부팅 시점 값에 고정되어, 복원으로 주소가 바뀌면 못 따라간다.
batch_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=batch" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ "$batch_id" = "None" ] || [ -z "$batch_id" ]; then
  log "10. 배치 인스턴스가 없다. 건너뛴다"
else
  log "10. 배치 교체 $batch_id"
  cmd_id=$(aws ssm send-command \
    --instance-ids "$batch_id" \
    --document-name AWS-RunShellScript \
    --region "$REGION" \
    --parameters "commands=[\"set -e\",\"/usr/local/bin/$PROJECT-refresh-env\",\"systemctl stop $PROJECT.service\",\"systemctl start $PROJECT.service\"]" \
    --query 'Command.CommandId' --output text)

  # 배치가 실행 중이면 stop 이 graceful shutdown 을 기다린다. systemd TimeoutStopSec 60 이 상한이다
  for _ in $(seq 1 30); do
    st=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$batch_id" \
      --region "$REGION" --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$st" in
      Success) break ;;
      Failed|Cancelled|TimedOut)
        log "    배치 교체 실패 ($st). 앱은 이미 새 버전이다"
        log "    배치가 옛 버전으로 도는 구간이 생겼다. 수동으로 확인하라"
        exit 1 ;;
    esac
    sleep 5
  done
  log "    배치 교체 완료"
fi

# 11. 최종 확인
log "11. 최종 healthy $(healthy_count) / desired $desired"
log "배포 완료 $SHA"
