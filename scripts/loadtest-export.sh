#!/usr/bin/env bash
#
# 부하 시험 회차의 지표를 로컬 파일로 내려받는다.
#
#   ./loadtest-export.sh                 최근 30분
#   ./loadtest-export.sh --since 2h      최근 2시간
#   ./loadtest-export.sh --label v4-1차   이름을 붙인다
#
# 왜 그림이 아니라 데이터인가.
#
# 그라파나 스냅샷은 grafana-data 도커 볼륨에 저장된다. destroy 하면 함께 사라지는데
# 이 프로젝트는 재구축을 반복하므로 회차 기록으로 못 쓴다.
# PNG 를 만들려면 이미지 렌더러(헤드리스 크로미움)를 모니터링에 얹어야 하는데,
# 그 박스는 관측 스택으로 이미 2 GB 를 쓰고 있어 넣을 자리가 없다.
#
# 데이터를 내려 두면 destroy 해도 남고, 대시보드 JSON 이 Git 에 있으므로
# 나중에 언제든 같은 그림을 다시 만들 수 있다. 회차 간 비교도 이쪽이라야 된다.
#
# Prometheus 보존이 15일이다. 그 전에 내려야 한다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SINCE="30m"
LABEL=""
OUT_ROOT="${OUT_ROOT:-$ROOT/loadtest-runs}"
LOCAL_PORT="${LOCAL_PORT:-19090}"
STEP="${STEP:-15s}"

while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --out)   OUT_ROOT="$2"; shift 2 ;;
    *) printf 'ERROR: 모르는 인자 %s\n' "$1" >&2; exit 1 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 내릴 지표.
#
# k6 만 받으면 "느려졌다" 까지만 알고 왜 느려졌는지는 못 읽는다.
# 같은 시간축의 앱과 DB 를 함께 받아야 p99 가 튄 순간에 무엇이 있었는지 맞춰 볼 수 있다.
METRICS=$(cat <<'LIST'
k6_http_reqs_total
k6_http_req_duration_p99
k6_http_req_duration_p95
k6_http_req_duration_avg
k6_http_req_waiting_p99
k6_http_req_blocked_p99
k6_http_req_connecting_p99
k6_http_req_failed_rate
k6_vus
k6_dropped_iterations_total
k6_iteration_duration_p99
k6_coupon_issued_total
k6_coupon_sold_out_total
k6_coupon_congested_total
k6_coupon_rejected_total
k6_coupon_unexpected_total
k6_coupon_connect_failed_total
coupon_issue_queue_size
coupon_issue_results_total
jvm_memory_used_bytes
jvm_gc_pause_seconds_count
jvm_threads_live_threads
jvm_threads_peak_threads
jvm_threads_live_threads
hikaricp_connections_active
hikaricp_connections_pending
hikaricp_connections_timeout_total
tomcat_threads_busy_threads
http_server_requests_seconds_count
mysql_global_status_threads_connected
mysql_global_status_threads_running
mysql_global_status_slow_queries
mysql_global_status_innodb_row_lock_waits
redis_connected_clients
redis_commands_processed_total
node_cpu_seconds_total
node_memory_MemAvailable_bytes
node_load1
up
LIST
)

mon_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

TUNNEL_PID=""
cleanup() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
}
trap cleanup EXIT

id=$(mon_id)
[ "$id" != "None" ] && [ -n "$id" ] || die "running 인 모니터링 인스턴스가 없다"

# 터널로 붙는다. 모니터링에 아무것도 안 깐다.
#
# 이 방향이라야 하는 이유는 SG 다. Prometheus 9090 은 부하 생성기에서만 받게 막아 두었고
# 그것을 열어 주려면 내 IP 를 SG 에 넣어야 한다. SSM 은 그럴 필요가 없다.
log "1. 터널 $LOCAL_PORT -> $id:9090"
aws ssm start-session --target "$id" --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"9090\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
  > /dev/null 2>&1 &
TUNNEL_PID=$!

deadline=$(( $(date +%s) + 60 ))
until curl -sf "http://localhost:$LOCAL_PORT/-/ready" > /dev/null 2>&1; do
  [ "$(date +%s)" -ge "$deadline" ] && die "터널이 안 열렸다. session-manager-plugin 이 있나"
  kill -0 "$TUNNEL_PID" 2>/dev/null || die "터널 프로세스가 죽었다"
  sleep 2
done
log "   열렸다"

stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
dir="$OUT_ROOT/${stamp}${LABEL:+_$LABEL}"
mkdir -p "$dir/metrics"

# 무엇을 잰 회차인지 함께 남긴다.
#
# 숫자만 남기면 나중에 회차를 비교할 때 무엇이 달라서 다른지 못 읽는다.
# 특히 인스턴스 타입과 커밋은 회차마다 바뀌므로 반드시 붙여 둔다.
log "2. 회차 정보"
{
  printf '{\n'
  printf '  "exported_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "window": "%s",\n' "$SINCE"
  printf '  "label": "%s",\n' "$LABEL"
  printf '  "current_sha": "%s",\n' \
    "$(aws ssm get-parameter --name "/$PROJECT/current-sha" --region "$REGION" \
       --query 'Parameter.Value' --output text 2>/dev/null || echo unknown)"
  printf '  "instances": %s,\n' \
    "$(aws ec2 describe-instances --region "$REGION" \
       --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=running" \
       --query 'Reservations[].Instances[].{role:Tags[?Key==`Role`].Value|[0],type:InstanceType,az:Placement.AvailabilityZone}' \
       --output json | tr -d '\n ')"
  printf '  "app_asg": %s\n' \
    "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PROJECT-app" \
       --region "$REGION" \
       --query 'AutoScalingGroups[0].{min:MinSize,desired:DesiredCapacity,max:MaxSize}' \
       --output json | tr -d '\n ')"
  printf '}\n'
} > "$dir/meta.json"

# 초 단위로 바꾼다. query_range 는 유닉스 시각을 받는다.
case "$SINCE" in
  *h) secs=$(( ${SINCE%h} * 3600 )) ;;
  *m) secs=$(( ${SINCE%m} * 60 )) ;;
  *s) secs=${SINCE%s} ;;
  *)  die "--since 는 30m, 2h, 90s 형태다" ;;
esac
end=$(date +%s)
start=$(( end - secs ))

log "3. 지표 내려받기 (구간 $secs 초, 간격 $STEP)"
got=0; empty=0
for m in $METRICS; do
  code=$(curl -sG "http://localhost:$LOCAL_PORT/api/v1/query_range" \
    --data-urlencode "query=$m" \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$end" \
    --data-urlencode "step=$STEP" \
    -o "$dir/metrics/$m.json" -w '%{http_code}')

  if [ "$code" != "200" ]; then
    printf '  실패 %-42s HTTP %s\n' "$m" "$code"
    rm -f "$dir/metrics/$m.json"
    continue
  fi

  # 비어 있는 것은 지운다. 파일만 있고 내용이 없으면 나중에 읽는 사람이 헷갈린다.
  n=$(python3 -c "
import json,sys
d=json.load(open('$dir/metrics/$m.json'))
print(len(d.get('data',{}).get('result',[])))
" 2>/dev/null || echo 0)

  if [ "$n" = "0" ]; then
    rm -f "$dir/metrics/$m.json"
    empty=$(( empty + 1 ))
  else
    got=$(( got + 1 ))
  fi
done

log "   받음 $got 개, 데이터 없음 $empty 개"

# 사람이 먼저 볼 것을 요약해 둔다.
log "4. 요약"
python3 - "$dir" <<'PY' > "$dir/summary.txt"
import json, os, sys, glob
d = sys.argv[1]
meta = json.load(open(os.path.join(d, 'meta.json')))

print("부하 시험 회차")
print("  시각      %s" % meta['exported_at'])
print("  구간      %s" % meta['window'])
if meta.get('label'):
    print("  이름      %s" % meta['label'])
print("  커밋      %s" % meta['current_sha'][:12])
print("  앱 ASG    min %(min)s / desired %(desired)s / max %(max)s" % meta['app_asg'])
print("  인스턴스")
for i in meta['instances']:
    print("    %-11s %-16s %s" % (i.get('role') or '?', i['type'], i['az']))

def series(name):
    p = os.path.join(d, 'metrics', name + '.json')
    if not os.path.exists(p):
        return None
    return json.load(open(p))['data']['result']

print()
print("핵심 값")
checks = [
    ('k6_vus', '최대 VU', max),
    ('k6_dropped_iterations_total', '버려진 반복', max),
    ('k6_coupon_issued_total', '발급 200', max),
    ('k6_coupon_sold_out_total', '소진 409', max),
    ('k6_coupon_congested_total', '혼잡 503', max),
    ('k6_coupon_unexpected_total', '예상 밖', max),
    ('k6_coupon_connect_failed_total', '연결 실패', max),
    ('k6_http_req_duration_p99', 'p99 (초)', max),
    ('hikaricp_connections_pending', '커넥션 대기 최대', max),
    ('coupon_issue_queue_size', '발급 큐 최대', max),
]
for name, label, fn in checks:
    r = series(name)
    if not r:
        print("  %-18s -" % label)
        continue
    vals = [float(v) for s in r for _, v in s['values']]
    print("  %-18s %s" % (label, round(fn(vals), 4) if vals else '-'))

print()
print("혼잡의 원인별 내역")
r = series('coupon_issue_results_total')
if not r:
    print("  (없음. coupon job 이 스크랩되고 있나)")
else:
    tot = {}
    for s_ in r:
        k = s_['metric'].get('result', '?')
        vals = [float(v) for _, v in s_['values']]
        if vals:
            tot[k] = tot.get(k, 0) + (max(vals) - min(vals))
    for k, v in sorted(tot.items(), key=lambda x: -x[1]):
        if v > 0:
            print("  %-28s %10.0f" % (k, v))
    if not any(v > 0 for v in tot.values()):
        print("  (구간 내 증가 없음)")

print()
print("읽는 법")
print("  버려진 반복이 0 이 아니면 생성기가 부하를 다 못 보냈다. 그 회차 수치는 앱이 아니라")
print("  생성기의 한계를 잰 것이다.")
print("  예상 밖과 연결 실패는 0 이어야 한다.")
print()
print("받은 지표 %d 개" % len(glob.glob(os.path.join(d, 'metrics', '*.json'))))
PY

cat "$dir/summary.txt"
log "저장 위치 $dir"
