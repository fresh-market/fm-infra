#!/usr/bin/env bash
#
# 부하 생성기를 띄우고 내린다. 시험 시간에만 켠다.
#
#   ./loadtest-box.sh up       띄우고 준비될 때까지 기다린다
#   ./loadtest-box.sh down     지운다
#   ./loadtest-box.sh status   상태와 지금까지 쓴 비용
#
# tfvars 에 두지 않는 이유가 있다.
#
# load_test_enabled = true 를 tfvars 에 적어 두면 다른 이유로 apply 할 때마다 되살아난다.
# 시험이 끝난 줄 알았는데 계속 켜져 있고, 시간당 과금이라 그것을 알아채는 데 며칠이 걸린다.
# 여기서 -var 로 넘기면 이 스크립트로 켠 동안만 존재한다.
#
# 대가는 시험 중에 누가 apply 를 돌리면 이 인스턴스가 사라진다는 것이다.
# 그때는 up 을 다시 부르면 된다. 반대쪽 실수보다 싸다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# m7i-flex.large 온디맨드 (ap-northeast-2, 2026-08-30 조회).
# 프리 티어 크레딧에서 차감된다. 이 타입은 무료 할당 대상이 아니다.
HOURLY="0.1177"

ACTION="${1:-}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

tf() {
  cd "$ROOT/terraform"
  terraform init -input=false -backend-config=backend.hcl > /dev/null
  terraform apply -auto-approve -input=false -var "load_test_enabled=$1"
}

box_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=load-test" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null
}

show_status() {
  local id launched secs hours cost state
  id=$(box_id)

  if [ "$id" = "None" ] || [ -z "$id" ]; then
    printf '  부하 생성기   없다. up 으로 띄운다\n'
    return
  fi

  read -r state launched <<< "$(aws ec2 describe-instances --instance-ids "$id" --region "$REGION" \
    --query 'Reservations[0].Instances[0].[State.Name,LaunchTime]' --output text)"

  # LaunchTime 은 UTC 다. macOS 는 -u 를 안 주면 로컬로 읽어 9시간이 어긋난다.
  secs=$(( $(date +%s) - $(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${launched%%+*}" +%s 2>/dev/null \
    || date -d "$launched" +%s) ))
  hours=$(printf '%.2f' "$(echo "$secs / 3600" | bc -l)")
  cost=$(printf '%.2f' "$(echo "$hours * $HOURLY" | bc -l)")

  printf '  부하 생성기   %s  %s\n' "$id" "$state"
  printf '  가동          %s 시간\n' "$hours"
  printf '  누적 비용     약 %s USD  (시간당 %s, 크레딧에서 차감)\n' "$cost" "$HOURLY"
}

case "$ACTION" in
up)
  if [ "$(box_id)" != "None" ]; then
    log "이미 떠 있다"
    show_status
    exit 0
  fi

  log "1. 인스턴스 생성"
  tf true

  id=$(box_id)
  log "2. SSM 등록 대기 (부팅과 k6 설치에 수 분)"
  deadline=$(( $(date +%s) + 600 ))
  while true; do
    n=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$id" --query 'length(InstanceInformationList)' --output text 2>/dev/null || echo 0)
    [ "$n" = "1" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && die "10분을 넘겼다. 콘솔에서 $id 를 확인하라"
    sleep 15
  done

  # user_data 가 끝나야 시나리오와 토큰이 있다. 파일로 확인한다.
  log "3. 시나리오와 토큰 대기"
  deadline=$(( $(date +%s) + 600 ))
  while true; do
    cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
      --region "$REGION" --parameters 'commands=["test -f /opt/loadtest/fm-backend/loadtest/tokens.csv && echo ready"]' \
      --query 'Command.CommandId' --output text)
    sleep 8
    out=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
      --region "$REGION" --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
    [ "${out%%$'\n'*}" = "ready" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && die "user_data 가 안 끝났다. /var/log/user-data.log 를 보라"
    sleep 10
  done

  log "준비 완료"
  show_status
  printf '\n접속\n'
  printf '  aws ssm start-session --target %s --region %s\n\n' "$id" "$REGION"
  printf '시험 직전에 토큰을 다시 찍어라. 6시간짜리다\n'
  printf '  sudo /opt/loadtest/refresh.sh\n\n'
  printf '끝나면 반드시 내려라\n'
  printf '  %s down\n\n' "$0"
  ;;

down)
  id=$(box_id)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    log "이미 없다"
    exit 0
  fi

  show_status
  log "지운다 $id"
  tf false
  log "완료. 과금이 멈췄다"
  ;;

status)
  show_status
  ;;

*)
  sed -n '2,9p' "$0" | sed 's/^#//;s/^ //'
  exit 1
  ;;
esac
