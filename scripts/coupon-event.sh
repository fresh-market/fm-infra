#!/usr/bin/env bash
#
# 선착순 이벤트 전용 용량 조절. coupon.md 4장의 "이벤트 전에 올리고 끝나면 내린다" 를 옮겼다.
#
# 이 스크립트는 인프라 용량만 다룬다. 이벤트 상태는 건드리지 않는다.
# Redis 네 키 정리와 is_active 스위치는 앱의 관리자 API 가 갖는다 (coupon-v4.md).
# 두 경계를 섞으면 앱을 고칠 때마다 이 스크립트를 함께 고쳐야 한다.
#
#   ./coupon-event.sh open [대수]   전제를 확인하고 전용 ASG 를 올린다. 기본 2대
#   ./coupon-event.sh open 3 --force  커넥션 예산을 넘겨도 강행한다
#   ./coupon-event.sh close         전용 ASG 를 0 으로 내린다
#   ./coupon-event.sh status        지금 상태만 본다
#
# 왜 스케일링 정책에 맡기지 않나.
# 2만 건이 몇 초에 몰리는데 알람 평가와 부팅에 수 분이 걸린다.
# 확장이 끝나기 전에 이벤트가 끝나므로 미리 올려 두는 것이 본 수단이다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ASG="$PROJECT-coupon"
TG="$PROJECT-coupon"

# max_connections 실측값이다 (2026-08-23, pending-decisions 2.2절).
MAX_CONNECTIONS=60

# 백엔드가 프로필별로 정한 풀 크기다 (application.yml, -batch, -coupon 의 maximum-pool-size).
# 저쪽이 바뀌면 여기도 바꾼다. 어긋나면 검산이 조용히 틀린다.
APP_POOL=8
BATCH_POOL=4
COUPON_POOL=2

# 익스포터와 운영자 접속 몫이다. 실측이 아니라 잡아 둔 여유다.
ADMIN_RESERVE=3

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

asg_exists() {
  local n
  n=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --region "$REGION" --query 'length(AutoScalingGroups)' --output text 2>/dev/null || echo 0)
  [ "$n" = "1" ]
}

show_status() {
  if ! asg_exists; then
    printf '  전용 ASG      없다. coupon_dedicated_enabled = true 로 apply 하라\n'
    return
  fi
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --region "$REGION" --output text \
    --query 'AutoScalingGroups[0].[DesiredCapacity,MaxSize,length(Instances)]' \
    | while read -r d m n; do printf '  전용 ASG      desired %s / max %s / 인스턴스 %s\n' "$d" "$m" "$n"; done

  local tg_arn healthy
  tg_arn=$(aws elbv2 describe-target-groups --names "$TG" --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  healthy=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$REGION" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  printf '  healthy 대상  %s\n' "$healthy"

  local conns
  conns=$(aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/RDS --metric-name DatabaseConnections \
    --dimensions "Name=DBInstanceIdentifier,Value=$PROJECT-db" \
    --start-time "$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 min ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text 2>/dev/null || echo None)
  printf '  DB 커넥션     %s / %s\n' "$conns" "$MAX_CONNECTIONS"
}

cmd="${1:-status}"

case "$cmd" in
status)
  log "상태"
  show_status
  ;;

open)
  DESIRED="${2:-2}"
  FORCE="${3:-}"

  asg_exists || die "전용 ASG 가 없다. tfvars 에 coupon_dedicated_enabled = true 를 넣고 apply 하라"

  # max_size 를 넘기면 AWS 가 거절하는데 메시지가 불친절하다. 여기서 먼저 막는다.
  max_size=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --region "$REGION" --query 'AutoScalingGroups[0].MaxSize' --output text)
  [ "$DESIRED" -le "$max_size" ] \
    || die "$DESIRED 대는 max_size $max_size 를 넘는다. coupon_max_size 를 올리고 apply 하라"

  # 1. 캐시가 판정 주체다. 단일 노드면 이벤트가 그 노드와 함께 멈춘다 (coupon.md 4장).
  log "1. 전제 확인"
  # status 는 zsh 에서 읽기 전용이다. 이 스크립트는 bash 로 돌지만 이름을 피해 둔다.
  read -r nodes failover cache_status <<< "$(aws elasticache describe-replication-groups \
    --replication-group-id "$PROJECT-cache" --region "$REGION" --output text \
    --query 'ReplicationGroups[0].[length(MemberClusters),AutomaticFailover,Status]')"
  [ "$cache_status" = "available" ] || die "캐시가 available 이 아니다 ($cache_status)"
  [ "$nodes" -ge 2 ] || die "캐시가 $nodes 노드다. 이벤트 구간에는 판정 주체라 2노드가 필요하다"
  [ "$failover" = "enabled" ] || die "캐시 자동 페일오버가 꺼져 있다"
  log "   캐시 $nodes 노드, 페일오버 $failover"

  db=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" \
    --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text)
  [ "$db" = "available" ] || die "RDS 가 available 이 아니다 ($db)"
  log "   RDS $db"

  # 2. 커넥션 예산. 넘기면 늘린 인스턴스가 커넥션을 못 잡고 교체가 반복된다.
  #
  #    풀 크기는 백엔드가 프로필별로 정한 값이다 (application-*.yml).
  #    앱 8, 배치 4, 선착순 2 다. 여기 값과 어긋나면 이 검산이 헛돈다.
  #
  #    앱은 오토스케일링이라 이벤트 중 몇 대일지 모른다. 상한을 써서 최악으로 잡는다.
  app_max=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$PROJECT-app" --region "$REGION" \
    --query 'AutoScalingGroups[0].MaxSize' --output text)

  budget=$(( DESIRED * COUPON_POOL ))
  baseline=$(( app_max * APP_POOL + BATCH_POOL + ADMIN_RESERVE ))
  total=$(( budget + baseline ))

  log "2. 커넥션 예산 검산"
  log "   앱 최대 ${app_max}대 x $APP_POOL + 배치 $BATCH_POOL + 관리 $ADMIN_RESERVE = $baseline"
  log "   전용 ${DESIRED}대가 $budget 을 더해 $total / $MAX_CONNECTIONS"

  # 넘긴 채로 올리면 실패하는 모양이 헷갈린다.
  #
  # 못 채우면 readiness 가 실패하고 ASG 가 교체하고 새 인스턴스가 같은 벽에 부딪힌다.
  # 앱 버그와 구분되지 않는 교체 반복으로 나타나고, healthy 대기 상한 600초를 태우고서야 드러난다.
  if [ "$total" -gt "$MAX_CONNECTIONS" ]; then
    if [ "$FORCE" != "--force" ]; then
      printf '\n' >&2
      printf '커넥션 예산을 넘긴다. %s / %s\n' "$total" "$MAX_CONNECTIONS" >&2
      printf '\n' >&2
      printf '풀 크기가 앱 %s / 배치 %s / 선착순 %s 라는 가정이다.\n' "$APP_POOL" "$BATCH_POOL" "$COUPON_POOL" >&2
      printf 'application-*.yml 이 더 줄였다면 실제로는 안 넘긴다. 그 경우 이 스크립트의 상수를 맞춰라.\n' >&2
      printf '맞다면 %s 번째 인스턴스가 커넥션을 못 잡고 교체를 반복한다.\n' "$DESIRED" >&2
      printf '앱 버그처럼 보이지만 원인은 커넥션 한도이고, 10분을 태우고서야 드러난다.\n' >&2
      printf '\n' >&2
      printf '확인했다면 --force 를 붙여라.  %s open %s --force\n' "$0" "$DESIRED" >&2
      exit 1
    fi
    log "   --force 로 강행한다"
  fi

  # 3. 미리 올린다. 스케일링 정책은 버스트를 못 받는다.
  log "3. 전용 ASG desired $DESIRED"
  aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
    --desired-capacity "$DESIRED" --region "$REGION"

  log "4. healthy 대기 (상한 600초)"
  tg_arn=$(aws elbv2 describe-target-groups --names "$TG" --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  deadline=$(( $(date +%s) + 600 ))
  while true; do
    healthy=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$REGION" \
      --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
    [ "$healthy" -ge "$DESIRED" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && die "healthy $healthy / $DESIRED. 상한 초과. 앱 로그를 확인하라"
    sleep 15
  done

  log "준비 완료"
  show_status
  printf '\n다음은 앱의 관리자 API 다. 이 스크립트가 하지 않는다.\n'
  printf '  Redis 네 키 정리, 카운터 0 초기화, EXPIREAT, is_active 켜기\n'
  ;;

close)
  asg_exists || die "전용 ASG 가 없다"

  log "1. 전용 ASG desired 0"
  aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
    --desired-capacity 0 --region "$REGION"

  # 드레인을 기다린다. 대상 그룹의 deregistration_delay 가 30초다.
  log "2. 드레인 대기 (상한 300초)"
  deadline=$(( $(date +%s) + 300 ))
  while true; do
    n=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --region "$REGION" --query 'length(AutoScalingGroups[0].Instances)' --output text)
    [ "$n" = "0" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && { log "   인스턴스 $n 대가 남아 있다. 콘솔에서 확인하라"; break; }
    sleep 15
  done

  log "종료 완료"
  show_status
  printf '\n경로 자체를 걷으려면 tfvars 의 coupon_dedicated_enabled 를 false 로 두고 apply 하라.\n'
  printf '그러면 발급 요청이 평상시 앱으로 간다.\n'
  ;;

*)
  die "사용법: $0 {open [대수]|close|status}"
  ;;
esac
