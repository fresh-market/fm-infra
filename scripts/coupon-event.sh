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
#
# 커넥션 예산은 값을 베끼지 않고 잰다.
#
# 전에는 백엔드의 maximum-pool-size 세 값을 상수로 들고 있었다. 저쪽이 바뀌면 이쪽이 조용히
# 틀리는데, 틀렸다는 사실이 어디에도 안 드러났다. 지금은 돌고 있는 인스턴스에게 SSM 으로
# hikaricp_connections_max 를 물어본다. 파일도 저장소도 안 읽으므로 fm-infra 만 있으면 된다.
#
# 앱과 배치는 늘 떠 있어 2절에서 읽힌다. 전용은 3절이 올린 뒤에야 생기므로 5절에서 읽는다.
# 그래서 2절은 "전용에 얼마가 남았나" 만 묻고 예측하지 않는다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ASG="$PROJECT-coupon"
TG="$PROJECT-coupon"

# max_connections 실측값이다 (2026-08-23, pending-decisions 2.2절).
MAX_CONNECTIONS=60

# 익스포터와 운영자 접속 몫이다. 실측이 아니라 잡아 둔 여유다.
ADMIN_RESERVE=3

# 풀 크기는 여기 없다. 백엔드가 소유하는 값이라 인스턴스에게 물어본다 (pool_max).

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# ASG 에서 서비스 중인 인스턴스 하나를 고른다. 없으면 빈 문자열이다.
asg_instance() {
  local id
  id=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$1" \
    --region "$REGION" --output text \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' 2>/dev/null || true)
  [ "$id" = "None" ] && id=""
  printf '%s' "$id"
}

# 태그로 인스턴스 하나를 고른다. 배치는 ASG 가 아니라 단독 인스턴스다.
tagged_instance() {
  local id
  id=$(aws ec2 describe-instances --region "$REGION" --output text \
    --filters "Name=tag:Role,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' 2>/dev/null || true)
  [ "$id" = "None" ] && id=""
  printf '%s' "$id"
}

#
# 그 인스턴스의 Hikari 최대 풀 크기를 읽는다. 못 읽으면 빈 문자열이다.
#
# 파일이 아니라 돌고 있는 프로세스에게 묻는 것이 요점이다. 그래야 프로필과 환경 변수를 다
# 해석한 뒤의 값을 얻는다. 이 저장소가 예전에 rewriteBatchedStatements 로 그 차이에 물렸다.
# yml 에는 있었는데 DB_URL 환경 변수가 그 기본값을 통째로 버려서 운영에는 없던 값이었다.
#
# 8081 은 ALB 와 모니터링에서만 열려 있다 (INF-12-21). 그래서 밖에서 긁지 않고 SSM 으로
# 인스턴스 안에서 curl 한다. 포트를 하나도 안 연다.
#
pool_max() {
  local iid="$1" cid out status value tmp
  [ -n "$iid" ] || return 1

  tmp=$(mktemp)
  cat > "$tmp" <<'JSON'
{
  "commands": [
    "curl -s --max-time 3 localhost:8081/actuator/prometheus | grep -m1 '^hikaricp_connections_max' | sed 's/.* //'"
  ]
}
JSON
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript --parameters "file://$tmp" \
    --query 'Command.CommandId' --output text 2>/dev/null || true)
  rm -f "$tmp"
  [ -n "$cid" ] && [ "$cid" != "None" ] || return 1

  # 상한 20초다. 못 읽어도 이 스크립트는 계속 간다
  local waited=0
  while [ "$waited" -lt 20 ]; do
    waited=$(( waited + 1 ))
    out=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cid" --instance-id "$iid" \
      --query '[Status,StandardOutputContent]' --output text 2>/dev/null || true)
    status=$(printf '%s' "$out" | awk 'NR==1{print $1}')
    case "$status" in
      Success)
        #
        # SSM 이 Success 라도 값이 비어 있을 수 있다. curl 이 0 으로 끝나기 때문이다.
        # 액추에이터가 아직 안 떴거나 지표가 없으면 그렇게 된다. 배포 직후에 흔하다.
        #
        # 그래서 숫자인지 먼저 본다. printf '%.0f' 에 그냥 넘기면 안 된다.
        # 빈 값에 0 을 찍고 종료코드 0 을 주므로 실패를 못 걸러 내고, 그 0 이 곱해져
        # baseline 을 무너뜨린다. 검산이 통과해 버린다.
        #
        value=$(printf '%s' "$out" | awk 'NR==1{print $2}')
        case "$value" in
          ''|*[!0-9.]*|*.*.*) return 1 ;;
        esac
        # 지표가 2.0 처럼 소수로 온다. 소수점 아래를 버려 정수로 쓴다
        value="${value%%.*}"
        [ -n "$value" ] && [ "$value" -ge 1 ] 2>/dev/null || return 1
        printf '%s' "$value"
        return 0
        ;;
      Failed|Cancelled|TimedOut) return 1 ;;
    esac
    sleep 1
  done
  return 1
}

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
  # 0 을 받으면 아래 headroom 나눗셈이 0 으로 나눈다. close 와 헷갈리지 않게 여기서 막는다
  [ "$DESIRED" -ge 1 ] || die "$DESIRED 대는 올릴 수 없다. 내리려면 $0 close 를 써라"
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

  #
  # 2. 전용에 얼마가 남아 있나. 전용이 얼마를 쓸지는 여기서 묻지 않는다.
  #
  #    앱과 배치는 지금 돌고 있으므로 풀 크기를 실측한다. 전용은 아직 없어 못 읽는데, 그래서
  #    예측하는 대신 남는 여유만 낸다. 실제로 얼마를 쓰는지는 5절이 실측으로 확정한다.
  #
  #    앱은 오토스케일링이라 이벤트 중 몇 대일지 모른다. 상한을 써서 최악으로 잡는다.
  #
  log "2. 여유 확인"
  app_max=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$PROJECT-app" --region "$REGION" \
    --query 'AutoScalingGroups[0].MaxSize' --output text)

  app_pool=$(pool_max "$(asg_instance "$PROJECT-app")" || true)
  batch_pool=$(pool_max "$(tagged_instance batch)" || true)

  if [ -z "$app_pool" ] || [ -z "$batch_pool" ]; then
    #
    # 못 읽어도 멈추지 않는다. 계측은 판정을 낫게 하려는 것이지 새 실패 지점이 아니다.
    # 넘겼는지는 4절의 healthy 대기가, 얼마를 썼는지는 5절이 여전히 잡는다.
    #
    warn "풀 크기를 실측하지 못했다 (앱 '$app_pool' / 배치 '$batch_pool'). 여유 확인을 건너뛴다"
    warn "SSM 이나 액추에이터를 확인하라. 4절과 5절은 그대로 돈다"
    baseline=""
  else
    baseline=$(( app_max * app_pool + batch_pool + ADMIN_RESERVE ))
    headroom=$(( MAX_CONNECTIONS - baseline ))
    log "   앱 최대 ${app_max}대 x $app_pool (실측) + 배치 $batch_pool (실측) + 관리 $ADMIN_RESERVE = $baseline"
    log "   전용에 남는 여유 $headroom / $MAX_CONNECTIONS"

    if [ "$headroom" -le 0 ]; then
      per=0
    else
      per=$(( headroom / DESIRED ))
    fi
    log "   ${DESIRED}대면 대당 $per 까지 안전하다"

    # 대당 하나도 못 주면 올릴 이유가 없다. 인스턴스는 뜨지만 이벤트에서 커넥션이 마른다
    if [ "$per" -lt 1 ]; then
      if [ "$FORCE" != "--force" ]; then
        printf '\n' >&2
        printf '전용에 줄 여유가 없다. 여유 %s 를 %s 대로 나누면 대당 %s 다.\n' "$headroom" "$DESIRED" "$per" >&2
        printf '\n' >&2
        printf '올려도 인스턴스는 뜬다. 유휴 커넥션은 적어서 기동은 성공한다.\n' >&2
        printf '마르는 것은 풀이 다 차는 이벤트 순간이고, 그때는 되돌릴 수 없다.\n' >&2
        printf '\n' >&2
        printf '대수를 줄이거나 앱 max_size 를 낮춰라.\n' >&2
        printf '확인했다면 --force 를 붙여라.  %s open %s --force\n' "$0" "$DESIRED" >&2
        exit 1
      fi
      log "   --force 로 강행한다"
    fi
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

  #
  # 5. 이제 전용 인스턴스가 있으므로 실제로 얼마를 쓰는지 읽는다.
  #
  #    이 자리가 마지막 되돌릴 수 있는 지점이다. 이벤트는 사람이 관리자 API 로 따로 열므로
  #    여기서 넘긴 것을 알면 close 하고 다시 계획할 수 있다.
  #
  #    4절이 못 잡는 것을 이 절이 잡는다. 기동 실패는 유휴 커넥션만 있으면 되므로 풀이 커도
  #    healthy 는 통과한다. 넘치는 것은 풀이 다 차는 이벤트 순간이고, 그것은 이 곱셈으로만 보인다.
  #
  log "5. 실측 검산"
  coupon_pool=$(pool_max "$(asg_instance "$ASG")" || true)

  if [ -z "$coupon_pool" ]; then
    warn "전용 인스턴스에서 풀 크기를 못 읽었다. 검산을 건너뛴다"
  elif [ -z "$baseline" ]; then
    warn "2절에서 baseline 을 못 구해 합계를 못 낸다. 전용은 대당 $coupon_pool 이다"
  else
    used=$(( DESIRED * coupon_pool ))
    total=$(( baseline + used ))
    log "   전용 ${DESIRED}대 x $coupon_pool (실측) = $used"
    log "   합계 $total / $MAX_CONNECTIONS"

    if [ "$total" -gt "$MAX_CONNECTIONS" ]; then
      printf '\n' >&2
      printf '커넥션 예산을 넘긴다. %s / %s\n' "$total" "$MAX_CONNECTIONS" >&2
      printf '\n' >&2
      printf '아직 이벤트를 안 열었다. 여는 대신 되돌려라.  %s close\n' "$0" >&2
      printf '그대로 열면 풀이 다 차는 순간에 커넥션이 마른다.\n' >&2
      printf '\n' >&2
      #
      # 성공으로 끝내지 않는다. 이 절이 마지막 되돌릴 수 있는 지점이라고 적어 두고
      # 종료코드 0 을 주면, 사람이 안 보는 자리에서는 넘긴 사실이 사라진다.
      # 인스턴스는 그대로 두고 나간다. 여기서 내리면 사람이 상태를 볼 기회를 잃는다.
      #
      show_status
      exit 1
    fi
  fi

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
