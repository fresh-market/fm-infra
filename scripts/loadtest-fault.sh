#!/usr/bin/env bash
#
# 부하 시험 중에 장애를 주입하고 되돌린다.
#
#   ./loadtest-fault.sh app         전용 인스턴스 3대 중 1대를 세운다
#   ./loadtest-fault.sh cache       전용 인스턴스에서 캐시로 가는 패킷을 버린다
#   ./loadtest-fault.sh db          전용 인스턴스에서 DB 로 가는 패킷을 버린다
#   ./loadtest-fault.sh app+cache   위 둘을 함께
#   ./loadtest-fault.sh status      지금 무엇이 끊겨 있는지
#   ./loadtest-fault.sh restore     무엇이 걸려 있든 되돌린다
#
#   --hold <초>   그 시간 뒤 스스로 되돌린다
#
# 왜 보안 그룹이 아니라 iptables 인가.
#
# AWS 보안 그룹은 상태 추적이라 규칙을 떼어도 **이미 맺어진 연결은 그대로 흐른다.**
# Lettuce 는 커넥션 하나를 세워 두고 모든 명령을 그 위로 다중화하므로, 규칙만 떼면 앱은
# 아무 일도 없었다는 듯 계속 돈다.
#
# 실제로 그렇게 헛돌았다 (2026-08-31). 캐시 인그레스를 떼고 부하를 걸었는데
# congested-seq-unavailable 이 0 이었고 10,000건이 다 나갔다. 장애가 주입되지 않은 회차를
# 통과로 읽을 뻔했다. iptables 로 버리면 기존 연결도 끊긴다.
#
# 앱은 인스턴스 종료가 아니라 systemctl stop 이다. 종료하면 ASG 가 새로 띄워 되돌릴 수 없다.
set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
STATE="${FAULT_STATE:-/tmp/${PROJECT}-fault.state}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

coupon_ids() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=coupon" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

run_ssm() {  # $1=instance $2=shell
  local id st
  id=$(aws ssm send-command --region "$REGION" --instance-ids "$1" \
        --document-name AWS-RunShellScript --timeout-seconds 300 \
        --parameters "commands=[\"$2\"]" --query Command.CommandId --output text)
  for _ in $(seq 1 30); do
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" \
          --instance-id "$1" --query Status --output text 2>/dev/null) && [ -n "$st" ] && break
    sleep 1
  done
  aws ssm wait command-executed --region "$REGION" --command-id "$id" --instance-id "$1" >/dev/null 2>&1 || true
  st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" \
        --query Status --output text 2>/dev/null)
  [ "$st" = "Success" ] || die "SSM 실패 ($st) on $1"
}

endpoint_port() {  # $1 = cache|db  ->  "호스트 포트"
  case "$1" in
    cache) printf '%s 6379' "$(aws ssm get-parameter --name "/$PROJECT/cache-endpoint" \
             --region "$REGION" --query Parameter.Value --output text)" ;;
    db)    printf '%s 3306' "$(aws ssm get-parameter --name "/$PROJECT/db-endpoint" \
             --region "$REGION" --query Parameter.Value --output text)" ;;
    *) die "모르는 대상: $1" ;;
  esac
}

# ---------------------------------------------------------------- 주입

cut_link() {  # $1 = cache|db
  local port ids
  port=$(endpoint_port "$1" | awk '{print $2}')
  ids=$(coupon_ids)
  [ -n "$ids" ] || die "도는 전용 인스턴스가 없다"
  for id in $ids; do
    log "$id 에서 $1(:$port) 패킷 차단"
    # OUTPUT 과 FORWARD 둘 다 넣는다. 앱이 도커 브리지 안에서 돌아 컨테이너가 내보내는
    # 패킷은 호스트의 OUTPUT 을 안 지나고 FORWARD 를 지난다. OUTPUT 만 넣었다가 주입이
    # 안 먹은 채로 회차를 통과로 읽을 뻔했다 (2026-08-31).
    run_ssm "$id" "iptables -I OUTPUT -p tcp --dport $port -j DROP; iptables -I FORWARD -p tcp --dport $port -j DROP; echo blocked"
  done
  printf 'block|%s|%s|%s\n' "$1" "$port" "$(echo $ids)" >> "$STATE"
}

stop_one_app() {
  local ids first left
  ids=$(coupon_ids)
  [ -n "$ids" ] || die "도는 전용 인스턴스가 없다"
  first=$(printf '%s\n' $ids | head -1)
  left=$(( $(printf '%s\n' $ids | wc -w) - 1 ))
  log "인스턴스 정지  $first  (남는 대수 $left)"
  run_ssm "$first" 'systemctl stop freshmarket.service; echo stopped'
  printf 'stop|%s\n' "$first" >> "$STATE"
}

# ---------------------------------------------------------------- 복구

restore_all() {
  [ -f "$STATE" ] || { log "되돌릴 것이 없다"; return 0; }
  # 여러 번 넣었을 수 있어 규칙이 없어질 때까지 지운다
  while IFS='|' read -r kind a b c; do
    case "$kind" in
      block)
        for id in $c; do
          log "$id 에서 $a(:$b) 차단 해제"
          run_ssm "$id" "while iptables -D OUTPUT -p tcp --dport $b -j DROP 2>/dev/null; do :; done; while iptables -D FORWARD -p tcp --dport $b -j DROP 2>/dev/null; do :; done; echo cleared"
        done ;;
      stop)
        log "인스턴스 기동  $a"
        run_ssm "$a" 'systemctl start freshmarket.service; echo started' ;;
    esac
  done < "$STATE"
  rm -f "$STATE"
  log "복구 완료. ALB 가 대상을 다시 넣기까지 healthy_threshold 만큼 걸린다"
}

show_status() {
  printf '전용 인스턴스\n'
  local tg
  tg=$(aws elbv2 describe-target-groups --names "$PROJECT-coupon" --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || true
  [ -n "${tg:-}" ] && aws elbv2 describe-target-health --target-group-arn "$tg" --region "$REGION" \
      --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | sed 's/^/  /'
  if [ -f "$STATE" ]; then printf '주입 중\n'; sed 's/^/  /' "$STATE"; else printf '주입 없음\n'; fi
}

# ---------------------------------------------------------------- 진입점

HOLD=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --hold) HOLD="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -ge 1 ] || die "시나리오를 주어라. app | cache | db | app+cache | status | restore"

case "${ARGS[0]}" in
  status)  show_status; exit 0 ;;
  restore) restore_all; exit 0 ;;
esac

[ -f "$STATE" ] && die "이미 주입된 장애가 있다. 먼저 restore 를 불러라"
trap 'echo; log "중단됨. 되돌린다"; restore_all' INT TERM

case "${ARGS[0]}" in
  app)       stop_one_app ;;
  cache)     cut_link cache ;;
  db)        cut_link db ;;
  app+cache) stop_one_app; cut_link cache ;;
  *) die "모르는 시나리오: ${ARGS[0]}" ;;
esac

log "주입 완료: ${ARGS[0]}"
show_status
if [ -n "$HOLD" ]; then log "${HOLD}초 유지한 뒤 되돌린다"; sleep "$HOLD"; restore_all
else log "유지 중. 되돌리려면  ./scripts/loadtest-fault.sh restore"; fi
