#!/usr/bin/env bash
#
# 부하 생성기를 띄우고 내린다. 시험 시간에만 켠다.
#
#   ./loadtest-box.sh up            띄우고 준비될 때까지 기다린다
#   ./loadtest-box.sh down          지운다
#   ./loadtest-box.sh status        상태와 지금까지 쓴 비용
#   ./loadtest-box.sh run <태그>     전 대수에 동시에 k6 를 건다
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

# 첫 대. 상태 표시처럼 대표 하나만 있으면 되는 곳이 쓴다
box_id() {
  box_ids | head -1
}

# 대수만큼 돌려준다. 세그먼트 번호 순으로 정렬한다.
#
# 2026-09-27 부터 생성기가 여러 대다. 한 대로 2만 VU 를 걸면 k6 가 8 GB 를 넘겨 커널이
# 죽인다. 근거는 terraform 의 variable "load_test_count" 주석에 있다.
box_ids() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=load-test" "Name=instance-state-name,Values=running,pending" \
    --query 'sort_by(Reservations[].Instances[], &Tags[?Key==`Segment`]|[0].Value)[].InstanceId' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$'
}

# 그 인스턴스가 쏠 세그먼트다. k6 에 --execution-segment 로 넘긴다
box_segment() {
  aws ec2 describe-instances --instance-ids "$1" --region "$REGION" \
    --query 'Reservations[0].Instances[0].Tags[?Key==`Segment`]|[0].Value' \
    --output text 2>/dev/null
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

  ids=$(box_ids)
  count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
  log "   $count 대"

  for id in $ids; do
    log "2. SSM 등록 대기 $id (부팅과 k6 설치에 수 분)"
    deadline=$(( $(date +%s) + 600 ))
    while true; do
      n=$(aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=$id" --query 'length(InstanceInformationList)' --output text 2>/dev/null || echo 0)
      [ "$n" = "1" ] && break
      [ "$(date +%s)" -ge "$deadline" ] && die "10분을 넘겼다. 콘솔에서 $id 를 확인하라"
      sleep 15
    done

    # user_data 가 끝나야 시나리오와 토큰이 있다. 파일로 확인한다.
    log "3. 시나리오와 토큰 대기 $id"
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
  done

  # 세그먼트를 검산한다.
  #
  # 이 값이 어긋나면 두 대가 같은 VU 번호를 써서 같은 토큰을 쏜다. 그러면 1인 1매 위반이
  # 나는데 그것은 앱이 아니라 생성기 탓이다. 지표에서는 그 둘이 구분되지 않으므로
  # 돌리기 전에 여기서 막는다.
  log "4. 세그먼트 검산"
  seen=""
  for id in $ids; do
    seg=$(box_segment "$id")
    case "$seg" in
      *:*) : ;;
      *) die "$id 의 Segment 가 $seg 다. 0:1/2 같은 구간 표기여야 한다. apply 를 다시 돌려라" ;;
    esac
    case " $seen " in
      *" $seg "*) die "세그먼트 $seg 가 두 번 나왔다. 같은 토큰을 두 대가 쏜다" ;;
    esac
    seen="$seen $seg"
    log "   $id  $seg"
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

run)
  # 전 대수에 동시에 건다.
  #
  # 손으로 대별로 돌리면 시작 시각이 어긋난다. 램프가 60초인데 대별로 10초씩 밀리면
  # 도착률이 설계값과 달라지고, 그 회차는 무엇을 잰 것인지 말할 수 없다.
  #
  # --execution-segment 가 VU 번호 공간을 나눈다. 시나리오가 exec.vu.idInTest 로 토큰을
  # 고르므로 이 값이 있어야 대별로 다른 사람을 쏜다. 없으면 두 대가 같은 토큰을 쓴다.
  #
  # execution-segment-sequence 를 함께 준다. k6 는 그 수열이 있어야 자기 몫이 전체의
  # 어디인지 안다. 둘 중 하나만 주면 거부한다.
  TAG="${2:-}"
  [ -z "$TAG" ] && die "회차 태그를 줘라. 예: ./loadtest-box.sh run v4-1"

  ids=$(box_ids)
  [ -z "$ids" ] && die "생성기가 없다. up 으로 띄운다"
  count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')

  # 경계 수열을 만든다. 0 으로 시작해 1 로 끝난다.
  #
  # 마지막을 count/count 로 적으면 안 된다. k6 는 끝을 1 로 본다.
  # 2대면 "0,1/2,1" 이고 각 대의 세그먼트는 "0:1/2" 과 "1/2:1" 이다.
  seq_arg="0"
  for i in $(seq 1 $(( count - 1 ))); do seq_arg="$seq_arg,$i/$count"; done
  seq_arg="$seq_arg,1"

  log "회차 $TAG 를 $count 대에 건다  (수열 $seq_arg)"
  cmds=""
  for id in $ids; do
    seg=$(box_segment "$id")
    body="set -a; . /opt/loadtest/env; set +a
cd /opt/loadtest/fm-backend/loadtest
k6 run -o experimental-prometheus-rw \
  --execution-segment '$seg' --execution-segment-sequence '$seq_arg' \
  -e BASE_URL=\"\$BASE_URL\" -e COUPON_ID=900001 issue.js"
    # 인자를 손으로 조립하지 않는다. 따옴표와 줄바꿈이 섞여 조용히 깨진다.
    # python 이 JSON 으로 만들어 --cli-input-json 으로 넘긴다.
    payload=$(BODY="$body" python3 -c '
import json, os
print(json.dumps({"Parameters": {"commands": [os.environ["BODY"]],
                                 "executionTimeout": ["1200"]}}))')
    c=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
          --region "$REGION" --timeout-seconds 1200 \
          --cli-input-json "$payload" \
          --query 'Command.CommandId' --output text)
    log "   $id  세그먼트 $seg  명령 $c"
    cmds="$cmds $id:$c"
  done

  log "대기"
  for pair in $cmds; do
    id="${pair%%:*}"; c="${pair##*:}"
    while :; do
      st=$(aws ssm get-command-invocation --command-id "$c" --instance-id "$id" \
             --region "$REGION" --query 'Status' --output text 2>/dev/null || echo Pending)
      case "$st" in Success|Failed|TimedOut|Cancelled) break;; esac
      sleep 15
    done
    printf '\n======== %s (%s) ========\n' "$id" "$st"
    aws ssm get-command-invocation --command-id "$c" --instance-id "$id" --region "$REGION" \
      --query 'StandardOutputContent' --output text 2>/dev/null | tail -40
  done
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
