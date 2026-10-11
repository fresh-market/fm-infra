#!/usr/bin/env bash
#
# 회차 하나를 돌린다. 부하를 먼저 띄우고 +15초에 장애를 주입한다.
#
#   ./loadtest-round.sh <이름> [장애]
#
#   이름   결과 폴더와 대시보드 라벨에 붙는다
#   장애   없으면 기준 회차다. 있으면 loadtest-fault.sh 에 그대로 넘긴다
#
# 환경변수로 바꿀 수 있는 것.
#
#   COUPON_ID     이 회차가 쓸 쿠폰 번호 (기본 900001)
#   BACKEND_REF   시드 SQL 을 받아 올 fm-backend 브랜치 (기본 main)
#   OUT           결과를 쌓을 디렉터리 (기본 이 저장소의 loadtest-runs/)
#
# 회차를 거듭할 때는 COUPON_ID 를 바꿔라. 같은 쿠폰을 재사용하면 앱이 든 highWater 와 어긋나
# 장애가 없는 회차에도 COUPON_SEQ_COUNTER_BEHIND 가 쏟아진다. 2026-10-10 J-3 에서 1,130건이
# 났고, 번호를 바꾼 L-2 에서 0 이 되었다 (fm-backend docs/coupon/budget-breakdown-2026-10-10.md).
#
#   COUPON_ID=900002 ./loadtest-round.sh N-1 cache-failover
#
# 왜 부하가 먼저인가.
# DB 나 캐시를 먼저 막으면 ALB 가 그 인스턴스를 대상에서 빼서 요청을 한 건도 안 받는다.
# 2026-09-30 회차가 그렇게 발급 2,886 에 재건 issued=0 queued=0 을 냈다.

set -uo pipefail

PROJECT=freshmarket
REGION=ap-northeast-2
COUPON_ID="${COUPON_ID:-900001}"
BACKEND_REF="${BACKEND_REF:-main}"

# 이 스크립트가 있는 자리에서 저장소 뿌리를 찾는다. 받는 사람의 홈 경로를 모른다
INFRA="$(cd -P "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$INFRA/loadtest-runs}"

NAME="${1:?이름을 줘라}"
FAULT="${2:-}"
DIR="$OUT/$NAME"
mkdir -p "$DIR"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$DIR/round.log"; }

box_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters 'Name=tag:Role,Values=load-test' 'Name=instance-state-name,Values=running' \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | grep -v '^$' | head -1
}

coupon_ids() {
  aws ec2 describe-instances --region "$REGION" \
    --filters 'Name=tag:Role,Values=coupon' 'Name=instance-state-name,Values=running' \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | grep -v '^$'
}

# 표준출력을 SSM_OUT 에 담는다. 실패해도 안 죽고 상태만 남긴다.
#
# --parameters 의 단축 문법을 쓰지 않는다. 그쪽은 JSON 을 해석하지 않아서 줄바꿈과 따옴표가
# 섞인 스크립트를 조용히 망가뜨린다. B-1 첫 시도가 그렇게 빈 출력을 냈다.
run_ssm() {  # $1=instance $2=shell  [$3=timeout초]
  local id to="${3:-300}" f
  f=$(mktemp)
  INSTANCE="$1" SHELL_IN="$2" TO="$to" python3 -c '
import json, os
print(json.dumps({
    "InstanceIds": [os.environ["INSTANCE"]],
    "DocumentName": "AWS-RunShellScript",
    "TimeoutSeconds": int(os.environ["TO"]),
    "Parameters": {"commands": os.environ["SHELL_IN"].splitlines()},
}))' > "$f"
  id=$(aws ssm send-command --region "$REGION" --cli-input-json "file://$f" \
        --query Command.CommandId --output text 2>/dev/null) || { rm -f "$f"; SSM_OUT=""; SSM_STATUS=SendFailed; return 1; }
  rm -f "$f"
  aws ssm wait command-executed --region "$REGION" --command-id "$id" --instance-id "$1" >/dev/null 2>&1 || true
  SSM_STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" \
        --query Status --output text 2>/dev/null)
  SSM_OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" \
        --query StandardOutputContent --output text 2>/dev/null)
  SSM_ERR=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" \
        --query StandardErrorContent --output text 2>/dev/null)
  [ "$SSM_STATUS" = Success ]
}

BOX=$(box_id)
[ -n "$BOX" ] || { echo "부하 생성기가 없다"; exit 1; }

log "################ $NAME ################"
log "장애: ${FAULT:-없음(기준 회차)}"

# ---------------------------------------------------------------- 1. 되돌리기
log "1. 앞 회차 되돌리기"
"$INFRA/scripts/loadtest-fault.sh" restore >/dev/null 2>&1 || true
COUPON_ID="$COUPON_ID" BACKEND_REF="$BACKEND_REF" \
  "$INFRA/scripts/loadtest-seed.sh" reset >>"$DIR/round.log" 2>&1 || log "   reset 실패. 로그를 봐라"

# 쿠폰을 다시 붓는다. 회차마다 번호가 다르면 reset 이 지울 것이 없고 이 단계가 새로 만든다
COUPON_ID="$COUPON_ID" BACKEND_REF="$BACKEND_REF" \
  "$INFRA/scripts/loadtest-seed.sh" coupon >>"$DIR/round.log" 2>&1 || log "   쿠폰 시드 실패"

# ---------------------------------------------------------------- 2. 대수 확인
log "2. 전용 인스턴스"
IDS=$(coupon_ids)
printf '%s\n' "$IDS" | sed 's/^/     /' | tee -a "$DIR/round.log"
N=$(printf '%s\n' "$IDS" | grep -c .)
[ "$N" -ge 3 ] || log "   3대가 아니다 ($N). 그대로 간다"

# ---------------------------------------------------------------- 3. 이벤트 열기
log "3. 이벤트 열기"
run_ssm "$BOX" 'set -a; . /opt/loadtest/env; set +a
T=$(grep -o 'eyJ[A-Za-z0-9._-]*' /opt/loadtest/mint.out | tail -1)
curl -s -o /dev/null -w "event:open HTTP %{http_code}\n" -X POST \
  -H "Authorization: Bearer $T" "$BASE_URL/v1/admin/coupons/'"$COUPON_ID"'/event:open"'
printf '%s\n' "$SSM_OUT" | sed 's/^/     /' | tee -a "$DIR/round.log"
printf '%s' "$SSM_OUT" | grep -q 'HTTP 200' || { log "   이벤트가 안 열렸다. 멈춘다 (SSM $SSM_STATUS) err=[$SSM_ERR]"; exit 1; }

START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

# ---------------------------------------------------------------- 4. k6
log "4. k6 를 띄운다"
run_ssm "$BOX" 'cd /opt/loadtest/fm-backend/loadtest
set -a; . /opt/loadtest/env; set +a
nohup k6 run -o experimental-prometheus-rw -e BASE_URL="$BASE_URL" -e COUPON_ID='"$COUPON_ID"' \
  issue.js > /tmp/k6.out 2>&1 &
echo $! > /tmp/k6.pid
sleep 2; echo "k6 pid $(cat /tmp/k6.pid)"'
printf '%s\n' "$SSM_OUT" | sed 's/^/     /' | tee -a "$DIR/round.log"

# ---------------------------------------------------------------- 5. 주입
if [ -n "$FAULT" ]; then
  log "5. +15초에 주입한다"
  sleep 15
  INJECT_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
  ( "$INFRA/scripts/loadtest-fault.sh" $FAULT >>"$DIR/fault.log" 2>&1 ; echo "주입 종료 $?" >>"$DIR/fault.log" ) &
  FAULT_PID=$!
  log "   주입을 걸었다 ($FAULT). 부하와 겹쳐 돈다"
else
  log "5. 주입 없음"
  INJECT_MS=""
fi

# ---------------------------------------------------------------- 6. k6 종료 대기
log "6. k6 종료 대기"
for i in $(seq 1 40); do
  run_ssm "$BOX" 'if kill -0 $(cat /tmp/k6.pid) 2>/dev/null; then echo RUNNING; else echo DONE; fi' 120
  case "$SSM_OUT" in
    *DONE*) log "   k6 끝 (확인 $i 회)"; break ;;
    *) sleep 15 ;;
  esac
done
[ -n "${FAULT_PID:-}" ] && wait "$FAULT_PID" 2>/dev/null
END_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

# ---------------------------------------------------------------- 7. 요약 전문
log "7. k6 요약을 받는다"
# SSM 이 표준출력을 24KB 로 자른다. 장애 회차는 timeout 경고가 그 한도를 혼자 다 먹으므로
# 경고를 걷어내고 꼬리만 받는다. F-2 에서 요약을 한 번 잃었다.
run_ssm "$BOX" 'grep -v "level=warning" /tmp/k6.out | tail -80'
printf '%s\n' "$SSM_OUT" > "$DIR/k6.txt"
grep -E "p\(99\)|coupon_issued|coupon_unexpected|http_req_failed|thresholds|✓|✗" "$DIR/k6.txt" \
  | head -30 | sed 's/^/     /' | tee -a "$DIR/round.log"

# ---------------------------------------------------------------- 8. 되돌리기
log "8. 되돌린다"
"$INFRA/scripts/loadtest-fault.sh" restore >>"$DIR/round.log" 2>&1 || true

# ---------------------------------------------------------------- 9. 재건 로그
#
# 회차가 시작한 뒤의 로그만 받는다. 컨테이너 로그가 누적되므로 --since 없이 tail 을 쓰면
# 앞 회차의 줄이 섞인다. 2026-10-10 J-3 수집물에 16분 전 J-2 의 재건 로그가 들어 있었다.
#
# 수천 건씩 나는 COUPON_SEQ_COUNTER_BEHIND 는 받지 않는다. tail 한도를 다 먹어 한 번만 나는
# 사건(REBUILT, REBUILD_FAILED, RECONNECT_DETECTED)을 밀어낸다. 실제로 J-4 에서 REBUILT 줄을
# 놓쳐 SSM 으로 따로 뽑아야 했다. 그 건수는 아래 9.5 가 지표로 센다.
#
# COUPON_SEQ_CONTRIBUTED 는 받는다. 어느 대가 기여를 올렸는지가 "재건이 남의 큐를 다 받았나"
# 를 가리는 유일한 단서다. 2026-10-10 N-2 에서 이것을 패턴에서 빼 두어, 3대가 도는 중에 재건이
# 2대의 기여만 기다린 것을 보고도 빠진 대가 올렸는지 끝내 가리지 못했다.
#
# 올리기는 쿠폰당 인스턴스당 한 번이라 수천 건이 되지 않는다. 그 회차에서 많아 보였던 것은
# 쿠폰이 여섯 개 열려 있었던 탓이고 그쪽은 reset 이 고쳤다.
log "9. 재건과 올리기 로그"
SINCE=$(python3 -c "import time; print(int($START_MS/1000) - 5)")
: > "$DIR/rebuild.txt"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  {
    printf '  [%s]\n' "$id"
    if run_ssm "$id" "docker logs --since $SINCE \$(docker ps -q --filter name=freshmarket) 2>&1 | grep -E \"COUPON_SEQ_REBUILD|COUPON_SEQ_REBUILT|COUPON_SEQ_RECONNECT|COUPON_SEQ_CONTRIBUT\" | tail -60"; then
      if [ -n "$SSM_OUT" ]; then printf '%s\n' "$SSM_OUT" | sed 's/^/    /'; else printf '    (없음)\n'; fi
    else
      printf '    (SSM %s)\n' "$SSM_STATUS"
    fi
  } >> "$DIR/rebuild.txt"
done <<< "$IDS"
cat "$DIR/rebuild.txt" | tee -a "$DIR/round.log"

# ---------------------------------------------------------------- 9.5 건수 지표
#
# 로그로 못 세는 것을 Prometheus 에서 센다. 로그 쪽은 tail 한도가 상한을 만들어 회차마다
# 똑같은 수가 찍힌다. 인스턴스 3대에 tail -40 이면 120 이 그 상한이고, 실제로 그렇게 찍힌
# 회차들의 참값은 그보다 훨씬 컸다. J-2 는 로그 114건에 지표 1,689건으로 15배였다.
log "9.5 건수 지표"
{
  printf 'BEHIND 와 재건 완주 건수는 지표로 센다. 로그의 tail 한도와 무관하다.\n\n'
  printf '다음을 모니터링 인스턴스에서 돌린다.\n'
  printf '  P=http://localhost:9090/api/v1/query\n'
  printf '  D=%s\n' "$(( (END_MS - START_MS) / 1000 ))"
  printf '  increase(coupon_seq_counter_behind_count[${D}s])\n'
  printf '  increase(coupon_seq_rebuild_duration_seconds_count[${D}s])\n'
  printf '  increase(coupon_seq_rebuild_duration_seconds_sum[${D}s])\n'
  printf '  time=%s\n' "$(( END_MS / 1000 ))"
} > "$DIR/metric-queries.txt"

# ---------------------------------------------------------------- 10. 정합성
log "10. 정합성"
COUPON_ID="$COUPON_ID" BACKEND_REF="$BACKEND_REF" "$INFRA/scripts/loadtest-seed.sh" verify 2>&1 | tee "$DIR/verify.txt" | grep -A3 issued_rows | sed 's/^/     /' | tee -a "$DIR/round.log"

# ---------------------------------------------------------------- 11. 대시보드
log "11. 대시보드"
"$INFRA/scripts/loadtest-snapshot.sh" --label "$NAME" --from "$START_MS" --to "$END_MS" \
  >>"$DIR/round.log" 2>&1 && log "   받았다" || log "   실패. round.log 를 봐라"

printf '%s %s %s\n' "$START_MS" "${INJECT_MS:--}" "$END_MS" > "$DIR/window.txt"
log "################ $NAME 완료 ################"
