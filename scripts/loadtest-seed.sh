#!/usr/bin/env bash
#
# 부하 시험 데이터를 RDS 에 넣고 되돌리고 결과를 센다.
#
#   ./loadtest-seed.sh apply    회원 2만, 쿠폰 900001, 주변 데이터를 넣는다
#   ./loadtest-seed.sh reset    회차 사이에 되돌린다
#   ./loadtest-seed.sh verify   몇 장이 나갔는지 센다
#
# 로컬 절차(fm-backend/loadtest/README.md)는 docker exec 로 컨테이너 MySQL 에 붓는다.
# RDS 는 그게 안 되고, 부하 생성기는 SG 가 3306 을 막아 직접 못 붙는다. 일부러 그렇게 두었다.
#
# 그래서 배치 인스턴스를 거친다. DB 에 붙을 수 있는 것 중 이 일에 가장 가깝다.
# 앱은 ASG 가 언제든 갈아치우고, 모니터링은 관측용이라 쓰지 않는다.
#
# SQL 은 GitHub 에서 직접 받는다. fm-backend 가 public 이라 자격증명이 필요 없고,
# 시나리오와 같은 커밋의 시드를 쓰게 되어 둘이 어긋나지 않는다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ORG="${GITHUB_ORG:-fresh-market}"
REPO="${BACKEND_REPO:-fm-backend}"
REF="${BACKEND_REF:-main}"
COUPON_ID="${COUPON_ID:-900001}"

# 클라이언트만 쓴다. 서버는 안 띄운다.
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"

ACTION="${1:-}"
BASE_RAW="https://raw.githubusercontent.com/$ORG/$REPO/$REF/loadtest"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 배치 인스턴스에서 돌 스크립트의 머리다.
#
# 비밀번호를 명령줄에 안 놓는다. ps 에 보이고 SSM 명령 이력에도 남는다.
# MYSQL_PWD 로 넘기면 둘 다 피한다.
db_preamble() {
  cat <<'PRE'
set -euo pipefail
EP=$(aws ssm get-parameter --name "$P/db-endpoint" --region "$R" --query 'Parameter.Value' --output text)
export MYSQL_PWD=$(aws ssm get-parameter --name "$P/db-password" --region "$R" --with-decryption --query 'Parameter.Value' --output text)
HOST=${EP%%:*}
PRE
}

# 문자셋을 안 주면 확인 SELECT 의 한글 별칭에서 구문 오류가 난다.
mysql_cmd() {
  printf 'docker run --rm -i -e MYSQL_PWD %s mysql --default-character-set=utf8mb4 -h "$HOST" -u %s %s' \
    "$MYSQL_IMAGE" "$PROJECT" "$PROJECT"
}

# 배치 인스턴스에서 돌리고 끝날 때까지 기다린다.
#
# send-command 는 명령을 큐에 넣고 바로 돌아온다. 안 기다리면 시드가 다 들어가기 전에
# 이 스크립트가 성공으로 끝나고, 시험이 빈 테이블을 상대로 시작한다.
run_on_batch() {
  local body="$1" id cmd status tmp
  id=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=batch" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  [ "$id" != "None" ] && [ -n "$id" ] || die "running 인 배치 인스턴스가 없다. 인프라가 떠 있나"

  # 여러 줄 스크립트를 셸 인용으로 넘기면 반드시 깨진다. JSON 파일로 준다.
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  P="$PROJECT" R="$REGION" BODY="$body" python3 -c '
import json, os
print(json.dumps({"commands": [os.environ["BODY"]]}))
' > "$tmp"

  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --region "$REGION" --comment "loadtest $ACTION" \
    --parameters "file://$tmp" \
    --query 'Command.CommandId' --output text)

  log "   배치 $id 에서 실행 중 (명령 $cmd)"

  # 시드가 2만 행이라 몇 분이 걸린다.
  local deadline=$(( $(date +%s) + 900 ))
  while true; do
    status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
      --region "$REGION" --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut)
        printf '\n--- 표준 오류 ---\n' >&2
        aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
          --region "$REGION" --query 'StandardErrorContent' --output text >&2
        die "명령이 $status 로 끝났다"
        ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && die "15분을 넘겼다. 명령 $cmd 를 직접 확인하라"
    sleep 10
  done

  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
    --region "$REGION" --query 'StandardOutputContent' --output text
}

# 파일마다 따로 붓는다. 하나로 이으면 어디서 깨졌는지 못 읽는다.
pour() {
  local files="$1"
  printf 'P=/%s\nR=%s\n%s\nfor f in %s; do\n  echo "-- $f"\n  curl -fsSL "%s/$f" | %s\ndone\necho 완료\n' \
    "$PROJECT" "$REGION" "$(db_preamble)" "$files" "$BASE_RAW" "$(mysql_cmd)"
}

case "$ACTION" in
apply)
  log "1. 시드 주입. 커밋 $REF 의 SQL 을 쓴다"
  run_on_batch "$(pour 'seed-dummy-data.sql seed-members.sql seed-coupon.sql')"
  log "완료"
  printf '\n다음 둘은 이 스크립트가 하지 않는다.\n'
  printf '  1. 토큰 찍기      부하 생성기에서 sudo /opt/loadtest/refresh.sh\n'
  printf '  2. 이벤트 열기    앱의 관리자 API. SQL 로 is_active 만 켜면 안 된다\n'
  printf '     카운터 없는 Redis 를 요청이 쳐서 전부 "준비되지 않음" 으로 끝난다\n\n'
  ;;

reset)
  log "1. 되돌리기"
  run_on_batch "$(pour 'reset.sql')"
  log "완료"
  printf '\nreset.sql 이 is_active 를 내린다. 다음 회차 전에 이벤트를 다시 열어야 한다.\n'
  printf '켜져 있으면 여는 API 가 "이미 열렸다" 로 돌아가고 지난 회차 카운터가 그대로 남는다.\n\n'
  ;;

verify)
  # k6 요약으로는 몇 장이 나갔는지 모른다. 예산을 넘겨 503 으로 답한 요청도
  # 그 티켓이 큐에 남아 나중에 써지기 때문이다 (loadtest/README.md 6절).
  log "1. 발급 결과"
  run_on_batch "$(printf 'P=/%s\nR=%s\n%s\n%s <<%s\nSELECT COUNT(*) AS issued_rows, MAX(issue_seq) AS max_seq,\n       MAX(issue_seq) - COUNT(*) AS gap, COUNT(DISTINCT member_id) AS members\n  FROM member_coupon WHERE coupon_id = %s;\n%s\n' \
    "$PROJECT" "$REGION" "$(db_preamble)" "$(mysql_cmd)" "SQL" "$COUPON_ID" "SQL")"
  printf '\n읽는 법\n'
  printf '  issued_rows = 재고     재고만큼 나갔다\n'
  printf '  gap = 0                번호만 태우고 사라진 요청이 없다\n'
  printf '  members = issued_rows  1인 1매가 지켜졌다\n\n'
  ;;

*)
  sed -n '2,17p' "$0" | sed 's/^#//;s/^ //'
  exit 1
  ;;
esac
