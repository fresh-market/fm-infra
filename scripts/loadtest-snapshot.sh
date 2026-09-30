#!/usr/bin/env bash
#
# 회차 구간의 그라파나 대시보드를 PNG 로 내려받는다.
#
#   ./loadtest-snapshot.sh --label f4-1           지금부터 거꾸로 5분
#   ./loadtest-snapshot.sh --label F-2 --minutes 10
#   ./loadtest-snapshot.sh --from 1790699360000 --to 1790699480000
#   ./loadtest-snapshot.sh --dash fm-loadtest     한 장만
#
#   --label <이름>     저장 폴더에 붙인다
#   --minutes <분>     지금부터 거꾸로 몇 분 (기본 5)
#   --from / --to      유닉스 밀리초로 구간을 직접 준다
#   --dash <uid>       그 대시보드만. 여러 번 줄 수 있다
#   --out <경로>       저장 위치 (기본 loadtest-runs/)
#
# 왜 이 스크립트가 필요한가.
#
# 2026-09-30 장애 회차에서 팀은 수치를 다 남기고 대시보드를 한 장도 안 남겼다. 인프라를 내린
# 뒤에는 되살릴 수 없다. Prometheus 는 모니터링 인스턴스의 도커 볼륨에 담기고 밖으로 내보내는
# 설정이 없으므로, destroy 가 지우면 그 회차의 그림은 영영 없다.
#
# 그래서 회차가 끝난 직후에 부른다. destroy 보다 먼저다.
#
# 렌더러가 필요하다.
#
# observability/compose.yaml 의 renderer 가 떠 있어야 한다. 없으면 그라파나가 PNG 대신
# 오류를 200 으로 돌려주므로 아래에서 PNG 인지 확인한다.
#
# 왜 SSM 터널인가.
#
# 그라파나는 127.0.0.1:3000 에만 묶여 있다. 밖에서 오는 것은 Caddy 가 받고, 3000 인바운드는
# SG-alb 출처만 허용한다. 내 IP 를 SG 에 넣지 않으려면 SSM 이 유일한 길이다.
set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$ROOT/loadtest-runs}"
LOCAL_PORT="${LOCAL_PORT:-13000}"
WIDTH="${WIDTH:-1600}"
HEIGHT="${HEIGHT:-900}"

LABEL=""; MINUTES=5; FROM=""; TO=""; DASH=()

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --label)   LABEL="${2:-}"; shift 2 ;;
    --minutes) MINUTES="${2:-}"; shift 2 ;;
    --from)    FROM="${2:-}"; shift 2 ;;
    --to)      TO="${2:-}"; shift 2 ;;
    --dash)    DASH+=("${2:-}"); shift 2 ;;
    --out)     OUT_ROOT="${2:-}"; shift 2 ;;
    *) die "모르는 인자: $1" ;;
  esac
done

# 구간을 정한다. from 과 to 를 함께 주지 않았으면 지금부터 거꾸로 센다.
if [ -z "$FROM" ] || [ -z "$TO" ]; then
  case "$MINUTES" in ''|*[!0-9]*) die "--minutes 는 숫자다: $MINUTES" ;; esac
  TO=$(( $(date +%s) * 1000 ))
  FROM=$(( TO - MINUTES * 60 * 1000 ))
fi

# 기본은 다섯 장 전부다. 회차마다 무엇이 문제였는지 미리 알 수 없다.
if [ ${#DASH[@]} -eq 0 ]; then
  DASH=(fm-overview fm-hosts fm-app-jvm fm-data-stores fm-loadtest)
fi

mon_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

TUNNEL_PID=""
cleanup() { [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true; }
trap cleanup EXIT

id=$(mon_id)
[ "$id" != "None" ] && [ -n "$id" ] || die "running 인 모니터링 인스턴스가 없다"

log "1. 터널 $LOCAL_PORT -> $id:3000"
aws ssm start-session --target "$id" --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
  > /dev/null 2>&1 &
TUNNEL_PID=$!

deadline=$(( $(date +%s) + 60 ))
until curl -sf "http://localhost:$LOCAL_PORT/api/health" > /dev/null 2>&1; do
  [ "$(date +%s)" -ge "$deadline" ] && die "터널이 안 열렸다. session-manager-plugin 이 있나"
  kill -0 "$TUNNEL_PID" 2>/dev/null || die "터널 프로세스가 죽었다"
  sleep 2
done
log "   열렸다"

# 비어 있으면 compose 의 기본값이 admin 이다.
PW=$(aws ssm get-parameter --name "/$PROJECT/grafana-admin-password" --region "$REGION" \
      --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)
[ -n "$PW" ] && [ "$PW" != "None" ] || PW=admin

stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
dir="$OUT_ROOT/${stamp}${LABEL:+_$LABEL}/grafana"
mkdir -p "$dir"

# 무엇을 자른 구간인지 남긴다. 파일 이름만으로는 나중에 회차를 못 짚는다.
{
  printf 'label   %s\n' "${LABEL:-없음}"
  printf 'from    %s  (%s)\n' "$FROM" "$(date -u -r $((FROM/1000)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')"
  printf 'to      %s  (%s)\n' "$TO" "$(date -u -r $((TO/1000)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')"
  printf 'size    %sx%s\n' "$WIDTH" "$HEIGHT"
} > "$dir/구간.txt"

log "2. 렌더 $FROM ~ $TO"
ok=0; fail=0
for uid in "${DASH[@]}"; do
  out="$dir/$uid.png"
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 180 -u "admin:$PW" \
    "http://localhost:$LOCAL_PORT/render/d/$uid/x?orgId=1&from=$FROM&to=$TO&width=$WIDTH&height=$HEIGHT&kiosk&tz=Asia%2FSeoul&timeout=120" \
    2>/dev/null || echo 000)
  # 그라파나는 렌더러가 없어도 200 을 주고 본문에 오류를 담는다. 매직 바이트로 가른다.
  if [ "$code" = "200" ] && [ "$(head -c 4 "$out" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; then
    log "   $uid  $(wc -c < "$out" | tr -d ' ') 바이트"
    ok=$((ok+1))
  else
    log "   $uid  실패 (HTTP $code)"
    head -c 300 "$out" >&2 2>/dev/null || true; printf '\n' >&2
    rm -f "$out"; fail=$((fail+1))
  fi
done

log "3. $dir"
log "   성공 $ok / 실패 $fail"
[ "$fail" -eq 0 ] || die "$fail 장이 안 나왔다. renderer 컨테이너가 떠 있는지 보라 (docker ps)"
