#!/usr/bin/env bash
#
# 부하 시험 중에 장애를 주입하고 되돌린다.
#
#   ./loadtest-fault.sh app         전용 인스턴스 3대 중 1대를 세운다
#   ./loadtest-fault.sh cache       전용 인스턴스에서 캐시로 가는 패킷을 버린다
#   ./loadtest-fault.sh db          전용 인스턴스에서 DB 로 가는 패킷을 버린다
#   ./loadtest-fault.sh app+cache   위 둘을 함께
#   ./loadtest-fault.sh cache-failover  캐시를 실제로 페일오버시킨다 (test-failover)
#   ./loadtest-fault.sh db-failover     DB 를 실제로 페일오버시킨다 (reboot with failover)
#   ./loadtest-fault.sh lost-tail   복제가 밀린 채 승격된 것을 흉내낸다 (가장 흔하다)
#   ./loadtest-fault.sh seq-loss    순번 키(counter)를 지워 재건을 일으킨다
#   ./loadtest-fault.sh cache-wipe  순번 네 키를 전부 지운다 (캐시 전손)
#   ./loadtest-fault.sh status      지금 무엇이 끊겨 있는지
#   ./loadtest-fault.sh restore     무엇이 걸려 있든 되돌린다
#
#   --hold <초>      그 시간 뒤 스스로 되돌린다
#   --lost <건수>    lost-tail 전용. 몇 건의 발급을 유실시킬지 (기본 200)
#   --backlog <초>   seq-loss 전용. 그 시간만큼 DB 를 막아 큐를 쌓은 뒤 지운다
#                    1~2 초로 잡는다. 길게 잡으면 오히려 큐가 빈다 (아래)
#
# 왜 키를 직접 건드리는가.
#
# 페일오버로는 아무것도 안 사라진다. test-failover 는 계획된 승격이라 AWS 가 복제본이
# 따라잡기를 기다린 뒤에 넘긴다. 2026-09-21 회차에서 캐시 페일오버를 걸고도 재건이
# 한 번도 안 일어난 이유가 이것이다.
#
# 어느 것이 실제로 잘 일어나나.
#
#   lost-tail   높다.  Valkey 복제는 비동기다. 복제본이 마지막 쓰기 몇 건을 못 받은 채
#                      승격되면 counter 가 뒤로 간다. 키는 하나도 안 사라진다
#   seq-loss    낮다.  노드가 빈 채로 살아나야 한다. Multi-AZ 복제라 둘이 같이 죽어야 한다
#   cache-wipe  가장 낮다. 전손이다
#
# --backlog 를 길게 잡으면 안 되는 이유.
#
# DB 를 막으면 큐가 쌓일 것 같지만 그렇지 않다. 플러시가 티켓을 꺼내 쓰기에 실패하면
# 그것을 실패로 처리하고 버린다. 큐는 쌓이는 것이 아니라 흘러나간다.
#
# 쌓이는 구간은 차단 직후뿐이다. 그때는 커넥션이 타임아웃까지 매달려 배치 하나가 느려지고,
# 그만큼 유입이 앞선다. 그러다 COUPON_FLUSH_CIRCUIT_OPEN 이 뜨면 배치가 즉시 실패하기
# 시작해 큐가 빠르게 빈다.
#
# 2026-09-22 회차에서 --backlog 5 와 10 으로 돌렸더니 기여 size 가 전부 0 이었다.
# 회로가 열린 뒤에 counter 를 지워서 정작 올릴 것이 없었다.
#
# 주입 시점의 큐 깊이는 coupon_issue_queue_size 의 max_over_time 으로 확인한다.
#
# 무엇이 재건을 부르나.
#
# counter 가 **없을 때만** coupon-issue-seq.lua 가 -2 를 내고 그것을 받은 요청이 재건을
# 띄운다. lost-tail 은 counter 를 줄이기만 하므로 **재건이 안 걸린다.** 이미 DB 에 커밋된
# 번호가 조용히 다시 나가고, 그것을 막는 것은 앱이 아니라 스키마의 uk_mc_coupon_seq 다.
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

# 한 줄에 하나씩 뱉는다.
#
# --output text 는 값이 여럿이면 탭으로 한 줄에 붙인다. 그대로 head -1 하면 세 대가
# 통째로 딸려 와 SendCommand 가 instanceIds 검증에서 거절한다. 실제로 그렇게 깨졌다.
coupon_ids() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=coupon" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | grep -v '^$'
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
  # 표준출력을 여기 담는다. 부르는 쪽이 안 쓰면 그냥 버려진다
  SSM_OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$1" \
        --query StandardOutputContent --output text 2>/dev/null)
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
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    log "$id 에서 $1(:$port) 패킷 차단"
    # OUTPUT 과 FORWARD 둘 다 넣는다. 앱이 도커 브리지 안에서 돌아 컨테이너가 내보내는
    # 패킷은 호스트의 OUTPUT 을 안 지나고 FORWARD 를 지난다. OUTPUT 만 넣었다가 주입이
    # 안 먹은 채로 회차를 통과로 읽을 뻔했다 (2026-08-31).
    run_ssm "$id" "iptables -I OUTPUT -p tcp --dport $port -j DROP; iptables -I FORWARD -p tcp --dport $port -j DROP; echo blocked"
  done <<< "$ids"
  printf 'block|%s|%s|%s\n' "$1" "$port" "$(printf '%s' "$ids" | tr '\n' ' ')" >> "$STATE"
}

stop_one_app() {
  local ids first left
  ids=$(coupon_ids)
  [ -n "$ids" ] || die "도는 전용 인스턴스가 없다"
  first=$(printf '%s\n' "$ids" | head -1)
  left=$(( $(printf '%s\n' "$ids" | grep -c .) - 1 ))
  log "컨테이너 급사(SIGKILL)  $first  (남는 대수 $left)"
  # docker kill 이다. docker stop 은 SIGTERM 을 보내 stop_grace_period 45초 안에 스프링이
  # SmartLifecycle.stop 으로 큐를 비우고 내려간다. 그러면 우아한 종료라 재고 손실이
  # 0 으로 나오는 것이 당연해지고, 시스템이 견딘 것인지 비우고 내려간 것인지 못 가른다.
  #
  # queue-capacity 의 존재 이유가 "앱이 급사했을 때 잃는 건수의 상한"(coupon.md 8장)인데
  # 우아하게 내려가면 그 상한이 한 번도 시험되지 않는다.
  #
  # 저장소의 다른 문서들도 docker kill 을 적고 있다 (operation-guideline.md OPS-2-01,
  # 백엔드공통_앱과DB_장애대응구조.md). 이 스크립트만 어긋나 있었다.
  #
  # systemctl stop 은 쓰지 않는다. compose down 으로 컨테이너를 지워 종료 로그가 사라진다.
  run_ssm "$first" 'docker kill freshmarket >/dev/null && echo killed'
  printf 'stop|%s\n' "$first" >> "$STATE"
}

# ---------------------------------------------------------------- 페일오버

# iptables 단절은 "통째로 안 닿는다" 를 잰다. 운영에서 더 흔한 것은 Multi-AZ 페일오버다.
# 수십 초 동안 부분적으로 끊기고 엔드포인트가 다른 노드를 가리키게 된다.
# db_multi_az 를 켜 둔 이유가 이 시험이다 (terraform.tfvars).
#
# 이 둘은 restore 가 필요 없다. AWS 가 스스로 되돌려 놓는다.
failover_cache() {
  local rg="$PROJECT-cache" node
  node=$(aws elasticache describe-replication-groups --region "$REGION" \
         --replication-group-id "$rg" \
         --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupId' --output text)
  log "캐시 페일오버  $rg  노드그룹 $node"
  aws elasticache test-failover --region "$REGION" \
    --replication-group-id "$rg" --node-group-id "$node" > /dev/null
  printf 'failover|cache\n' >> "$STATE"
}

failover_db() {
  local id="$PROJECT-db"
  log "DB 페일오버  $id  (reboot with failover)"
  aws rds reboot-db-instance --region "$REGION" \
    --db-instance-identifier "$id" --force-failover > /dev/null
  printf 'failover|db\n' >> "$STATE"
}

# ---------------------------------------------------------------- 키 제거

# 캐시에는 앱 인스턴스만 닿는다. 보안 그룹이 앱과 모니터링만 허용하므로 여기서 직접 못 친다.
# 그래서 전용 인스턴스 한 대를 SSM 으로 빌려 거기서 명령을 보낸다.
#
# redis-cli 를 안 쓴다. 인스턴스에 깔려 있지 않고, 도커로 끌어오면 이미지를 받는 동안
# 큐가 다 빠져나가 정작 재려는 순간을 놓친다. bash 의 /dev/tcp 는 아무것도 안 깔고 즉시 끝난다.
#
# 명령을 base64 로 실어 보낸다. SSM 파라미터가 JSON 이라 \r 을 그대로 넣으면 JSON 이
# 그것을 진짜 복귀 문자로 풀어 버려 셸 명령이 그 자리에서 잘린다.

# 명령을 RESP 배열로 엮는다. 인자에 무엇이 들었든 길이로 재므로 따옴표가 안 깨진다
redis_payload() {
  local a
  LC_ALL=C
  printf '*%d\r\n' "$#"
  for a in "$@"; do printf '$%d\r\n%s\r\n' "${#a}" "$a"; done
  printf '*1\r\n$4\r\nQUIT\r\n'
}

# 원격에서 돌릴 스크립트 본문. $1=캐시 호스트, 나머지=보낼 명령의 인자들
#
# 페이로드를 base64 로 실어 보낸다. SSM 파라미터가 JSON 이라 \r 을 그대로 넣으면 JSON 이
# 그것을 진짜 복귀 문자로 풀어 버려 셸 명령이 그 자리에서 잘린다.
redis_script() {
  local host="$1"; shift
  cat <<REMOTE
exec 3<>/dev/tcp/$host/6379 || { echo REDIS-CONNECT-FAILED; exit 1; }
echo $(redis_payload "$@" | base64 | tr -d '\n') | base64 -d >&3
timeout 10 cat <&3 || true
REMOTE
}

# $1.. = 보낼 명령의 인자들  ->  응답 원문을 표준출력으로
redis_send() {
  local host id
  host=$(endpoint_port cache | awk '{print $1}')
  id=$(coupon_ids | head -1)
  [ -n "$id" ] || die "도는 전용 인스턴스가 없다"
  run_ssm "$id" "echo $(redis_script "$host" "$@" | base64 | tr -d '\n') | base64 -d | bash"
  printf '%s' "$SSM_OUT"
}

# 열려 있는 이벤트의 counter 키를 모은다.
#
# KEYS 는 서버를 잠그지만 여기 키스페이스는 이벤트 몇 개와 인증 키뿐이라 밀리초 안에 끝난다.
# SCAN 은 커서를 여러 번 왕복해야 하고 그 왕복이 SSM 이라 오히려 초 단위로 늘어난다.
counter_keys() {
  redis_send KEYS 'coupon:*:counter' | grep -o 'coupon:[0-9]*:counter' | sort -u
}

# 지울 키를 한 줄에 하나씩 뱉는다. $1 = counter|wipe
#
# 주변 IFS 에 기대지 않는다. 개행이 IFS 에 없는 셸에서는 `for k in $keys` 가 전부를
# 한 단어로 묶어 DEL 이 깨진 키 이름을 받는다. 실제로 그렇게 깨졌다.
expand_targets() {
  local mode="$1" k cid
  counter_keys | while IFS= read -r k; do
    [ -n "$k" ] || continue
    cid=${k#coupon:}; cid=${cid%:counter}
    if [ "$mode" = wipe ]; then
      printf 'coupon:%s:counter\ncoupon:%s:seq\ncoupon:%s:free\ncoupon:%s:pending\n' "$cid" "$cid" "$cid" "$cid"
    else
      printf 'coupon:%s:counter\n' "$cid"
    fi
  done
}

# 한 줄에 하나씩 오는 키를 배열로 읽는다
read_targets() {  # $1 = counter|wipe  ->  TARGETS 배열을 채운다
  local k
  TARGETS=()
  while IFS= read -r k; do [ -n "$k" ] && TARGETS+=("$k"); done < <(expand_targets "$1")
  [ ${#TARGETS[@]} -gt 0 ] || die "지울 counter 키가 없다. 이벤트가 열려 있는지 확인하라"
}

# $1 = counter|wipe
drop_keys() {
  read_targets "$1"
  log "키 삭제: ${TARGETS[*]}"
  redis_send DEL "${TARGETS[@]}" > /dev/null
  printf 'keys|%s\n' "$1" >> "$STATE"
}

# 복제가 밀린 채 승격된 것을 흉내낸다. $1 = 유실시킬 건수
#
# 이것이 실제 페일오버에서 확률이 가장 높은 모양이다. Valkey 복제는 비동기라 복제본이
# 마지막 쓰기 몇 건을 못 받은 채로 프라이머리가 된다. 키가 사라지는 것이 아니라
# **counter 가 뒤로 간다.**
#
# 순번 확보는 한 Lua 안에서 HSET/ZADD/INCR 를 함께 하므로 복제 스트림의 꼬리가 잘리면
# 그 세 효과가 통째로 같이 사라진다. 그래서 seq 와 pending 에서도 같은 회원을 지운다.
# counter 만 줄이면 실제로 안 생기는 모양이라 시험의 값이 떨어진다.
#
# **이 경우에는 재건이 안 걸린다.** coupon-issue-seq.lua 는 counter 가 없을 때만 -2 를
# 낸다. 값이 작아진 것은 못 본다. 그래서 이미 DB 에 커밋된 번호가 조용히 다시 나가고,
# 그것을 막는 것은 앱이 아니라 스키마의 uk_mc_coupon_seq 다. 이 회차가 보려는 것이
# 바로 그 지점이다.
LOST_TAIL_LUA=$(cat <<'LUAEOF'
-- KEYS[1]=seq KEYS[2]=pending KEYS[3]=counter  ARGV[1]=유실시킬 건수
local n = tonumber(redis.call('GET', KEYS[3]))
if not n then return {err = 'counter-absent'} end
local floor = n - tonumber(ARGV[1])
if floor < 0 then floor = 0 end

-- 먼저 모으고 나중에 지운다. 훑는 중에 지우면 HSCAN 이 건너뛰거나 두 번 줄 수 있다
local doomed = {}
local cursor = '0'
repeat
  local page = redis.call('HSCAN', KEYS[1], cursor, 'COUNT', 500)
  cursor = page[1]
  local arr = page[2]
  for i = 1, #arr, 2 do
    local v = arr[i + 1]
    local colon = string.find(v, ':')
    local num = tonumber(colon and string.sub(v, 1, colon - 1) or v)
    if num and num > floor then doomed[#doomed + 1] = arr[i] end
  end
until cursor == '0'

for i = 1, #doomed do
  redis.call('HDEL', KEYS[1], doomed[i])
  redis.call('ZREM', KEYS[2], doomed[i])
end

-- DECRBY 로 줄인다. SET 은 counter 의 만료를 지워 네 키의 수명이 갈라진다
redis.call('DECRBY', KEYS[3], n - floor)
return {floor, #doomed}
LUAEOF
)

lose_tail() {
  local lost="$1" k cid out
  case "$lost" in ''|*[!0-9]*) die "--lost 는 건수를 숫자로 받는다: $lost" ;; esac
  counter_keys | while IFS= read -r k; do
    [ -n "$k" ] || continue
    cid=${k#coupon:}; cid=${cid%:counter}
    out=$(redis_send EVAL "$LOST_TAIL_LUA" 3 \
            "coupon:$cid:seq" "coupon:$cid:pending" "coupon:$cid:counter" "$lost" | tr -d '\r')
    log "쿠폰 $cid  counter 를 $lost 만큼 되돌리고 그만큼의 seq 와 pending 을 지웠다"
    # || true 가 필요하다. grep 이 못 찾으면 1 을 내고 그것이 루프 본문의 마지막 값이라
    # set -e 가 스크립트를 죽인다. 실제로 "주입 완료" 를 못 찍고 끝났다
    printf '%s' "$out" | grep -q 'counter-absent' && log "  counter 가 없다. 이미 유실된 상태다" || true
  done
  printf 'keys|lost-tail\n' >> "$STATE"
}

# DB 를 잠깐 막아 큐를 쌓은 뒤 지운다. $1 = 막을 초
#
# 그냥 지우면 기여가 빈다. counter 가 사라진 순간부터 새 요청은 전부 -2 를 받아 큐에 안
# 들어가고, 이미 들어 있던 것은 20밀리초 창에 다 빠져나간다. 2026-09-21 회차가 전부
# 그랬다. 재건은 돌았는데 올릴 것이 없어 lagMillis 표본이 0건이었다.
#
# 그렇다고 길게 막으면 회로가 열려 큐가 도로 빈다 (머리말 참고). 1~2 초가 맞다.
#
# 한 대만 먼저 풀고 그 자리에서 지운다. 재건 주도자는 DB 를 읽어야 하므로 전부 막힌
# 상태에서는 시작조차 못 한다. 푸는 것과 지우는 것을 SSM 두 번으로 나누면 그 왕복
# 몇 초 사이에 큐가 다 빠지므로, 한 대의 같은 셸에서 이어서 한다.
#
# 나머지 대수는 막힌 채로 둔다. 기여는 Redis 만 건드리므로 DB 가 막혀 있어도 올릴 수
# 있고, 그 큐가 두꺼운 덕에 lagMillis 에 실제 표본이 쌓인다.
backlog_then_drop() {
  local secs="$1" port host lead remote
  case "$secs" in ''|*[!0-9]*) die "--backlog 는 초를 숫자로 받는다: $secs" ;; esac
  port=$(endpoint_port db | awk '{print $2}')
  host=$(endpoint_port cache | awk '{print $1}')

  read_targets counter

  cut_link db
  log "${secs}초 동안 큐를 쌓는다"
  sleep "$secs"

  lead=$(coupon_ids | head -1)
  log "$lead 만 DB 를 풀고 그 자리에서 counter 를 지운다"
  # 히어독으로 짓는다. $( ) 는 끝 개행을 지우므로 이어 붙이면 세 조각이 한 줄로 뭉친다
  remote=$(cat <<REMOTE
while iptables -D OUTPUT -p tcp --dport $port -j DROP 2>/dev/null; do :; done
while iptables -D FORWARD -p tcp --dport $port -j DROP 2>/dev/null; do :; done
$(redis_script "$host" DEL "${TARGETS[@]}")
REMOTE
)
  run_ssm "$lead" "echo $(printf '%s' "$remote" | base64 | tr -d '\n') | base64 -d | bash"

  printf 'keys|counter\n' >> "$STATE"
  log "주도자 $lead 가 재건을 이끈다. 나머지는 막힌 채로 두꺼운 큐를 올린다"
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
        # 인스턴스가 사라졌을 수 있다.
        #
        # ASG 가 비정상으로 보고 갈아치우면 그 인스턴스는 없다. run_ssm 이 die 로 끝나면
        # 아래 rm 이 안 돌아 상태 파일이 남고, 다음 회차가 가드에 걸려 주입도 못 한다.
        # 실제로 그렇게 두 회차를 날렸다. 그래서 여기서는 실패해도 넘어간다.
        if aws ec2 describe-instances --region "$REGION" --instance-ids "$a" \
             --query 'Reservations[].Instances[?State.Name==`running`]' --output text 2>/dev/null | grep -q .; then
          log "인스턴스 기동  $a"
          run_ssm "$a" 'docker start freshmarket >/dev/null && echo started' || log "  기동 실패. 넘어간다"
        else
          log "인스턴스가 없다  $a  (ASG 가 갈아치웠다)"
        fi ;;
      failover)
        # AWS 가 스스로 되돌린다. 되돌릴 것이 없고 기록만 지운다
        log "페일오버는 되돌릴 것이 없다  ($a)" ;;
      keys)
        # 손댄 키는 되돌리지 않는다. seq-loss 는 재건이 되살리고, lost-tail 은
        # 되돌릴 수 있으면 애초에 시험이 아니다. 실제 페일오버도 안 되돌아간다
        log "손댄 키는 되돌리지 않는다  ($a)" ;;
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

HOLD=""; BACKLOG=""; LOST=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --hold) HOLD="${2:-}"; shift 2 ;;
    --backlog) BACKLOG="${2:-}"; shift 2 ;;
    --lost) LOST="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -ge 1 ] || die "시나리오를 주어라. app | cache | db | app+cache | lost-tail | seq-loss | cache-wipe | status | restore"

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
  cache-failover) failover_cache ;;
  db-failover)    failover_db ;;
  app+cache-failover) stop_one_app; failover_cache ;;
  lost-tail) [ -z "$BACKLOG" ] || die "--backlog 는 seq-loss 에만 쓴다"
             lose_tail "${LOST:-200}" ;;
  seq-loss)  if [ -n "$BACKLOG" ]; then backlog_then_drop "$BACKLOG"; else drop_keys counter; fi ;;
  cache-wipe) [ -z "$BACKLOG" ] || die "--backlog 는 seq-loss 에만 쓴다"
              drop_keys wipe ;;
  *) die "모르는 시나리오: ${ARGS[0]}" ;;
esac

log "주입 완료: ${ARGS[0]}"
show_status
if [ -n "$HOLD" ]; then log "${HOLD}초 유지한 뒤 되돌린다"; sleep "$HOLD"; restore_all
else log "유지 중. 되돌리려면  ./scripts/loadtest-fault.sh restore"; fi
