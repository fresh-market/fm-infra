#!/usr/bin/env bash
#
# G-RELEASE. 배포와 시험 직전에 런타임 상태를 확인한다.
#
# 이 판정은 LLM 게이트가 할 수 없다. AWS API 로 지금 상태를 조회해야 알 수 있고,
# 판정 시점이 PR 이 아니라 실행 직전이며, 결과가 통과 아니면 중단으로 이진이다.
# 사양은 docs/infra-review/preflight-guideline.md 에 있다.
#
#   ./preflight.sh deploy    PRE-1-01 ~ PRE-1-06
#   ./preflight.sh test      위에 더해 PRE-2-*

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
MODE="${1:-deploy}"

fail=0
check() {
  local id="$1" desc="$2" ok="$3"
  if [ "$ok" = "1" ]; then
    printf '  OK    %-12s %s\n' "$id" "$desc"
  else
    printf '  FAIL  %-12s %s\n' "$id" "$desc"
    fail=1
  fi
}

echo "사전 점검 ($MODE)"

# PRE-1-01 RDS 가 available 인가
status=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo missing)
check PRE-1-01 "RDS 상태: $status" "$([ "$status" = "available" ] && echo 1 || echo 0)"

# PRE-1-02 ElastiCache 가 available 인가
cache=$(aws elasticache describe-replication-groups --replication-group-id "$PROJECT-cache" \
  --region "$REGION" --query 'ReplicationGroups[0].Status' --output text 2>/dev/null || echo missing)
check PRE-1-02 "캐시 상태: $cache" "$([ "$cache" = "available" ] && echo 1 || echo 0)"

# PRE-1-03 모니터링 인스턴스가 살아 있는가
mon=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
check PRE-1-03 "모니터링 인스턴스: ${mon}대" "$([ "$mon" -ge 1 ] && echo 1 || echo 0)"

# PRE-1-04 대상 그룹의 healthy 수가 desired 와 같은가
#
# 가장 중요한 항목이다.
# 배포는 신규를 띄우고 구 인스턴스를 지우는 절차라, 시작 시점에 이미 부족하면
# 배포 중에 용량이 더 떨어지고 그것이 배포 때문인지 원래 그랬는지 구분할 수 없다.
#
# 첫 배포는 예외다. 아직 배포된 적이 없으면 healthy 가 0 인 것이 정상이고,
# 이 항목이 막으면 첫 배포가 영원히 불가능해진다. 지킬 용량이 없으므로 지킬 것도 없다.
# 판정은 current-sha 로 한다. 한 번이라도 배포되면 실제 SHA 가 들어가 이 예외가 닫힌다.
deployed_sha=$(aws ssm get-parameter --name "/$PROJECT/current-sha" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo bootstrap)
tg_arn=$(aws elbv2 describe-target-groups --names "$PROJECT-app" \
  --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
if [ "$deployed_sha" = "bootstrap" ]; then
  printf '  SKIP  %-12s %s\n' PRE-1-04 "첫 배포다 (current-sha=bootstrap)"
elif [ -n "$tg_arn" ]; then
  healthy=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$REGION" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  desired=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PROJECT-app" \
    --region "$REGION" --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
  check PRE-1-04 "healthy $healthy / desired $desired" "$([ "$healthy" = "$desired" ] && echo 1 || echo 0)"
else
  check PRE-1-04 "대상 그룹을 찾지 못했다" 0
fi

# PRE-1-05 인증서 잔여일이 30일을 넘는가
#
# ACM DNS 검증은 자동 갱신되지만 검증 레코드가 사라지면 조용히 실패한다.
# 도메인을 아직 붙이지 않았으면 이 항목은 해당 없음이다.
cert=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?contains(DomainName, '$PROJECT')].CertificateArn | [0]" --output text 2>/dev/null || echo None)
if [ "$cert" != "None" ] && [ -n "$cert" ]; then
  not_after=$(aws acm describe-certificate --certificate-arn "$cert" --region "$REGION" \
    --query 'Certificate.NotAfter' --output text)
  days=$(( ( $(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${not_after%%+*}" +%s 2>/dev/null || date -u -d "$not_after" +%s) - $(date -u +%s) ) / 86400 ))
  check PRE-1-05 "인증서 잔여 ${days}일" "$([ "$days" -gt 30 ] && echo 1 || echo 0)"
else
  printf '  SKIP  %-12s %s\n' PRE-1-05 "도메인 미설정"
fi

# PRE-1-06 외부에서 서비스에 닿는가
hc=$(aws route53 list-health-checks --query 'length(HealthChecks)' --output text 2>/dev/null || echo 0)
if [ "$hc" != "0" ]; then
  hc_id=$(aws route53 list-health-checks --query 'HealthChecks[0].Id' --output text)
  hc_status=$(aws route53 get-health-check-status --health-check-id "$hc_id" \
    --query 'HealthCheckObservations[0].StatusReport.Status' --output text)
  check PRE-1-06 "외부 관점: $hc_status" "$(echo "$hc_status" | grep -q 'Success' && echo 1 || echo 0)"
else
  printf '  SKIP  %-12s %s\n' PRE-1-06 "헬스체크 미설정"
fi

# 시험은 배포보다 조건이 하나 더 붙는다.
# 크레딧이 마른 상태에서 부하를 걸면 측정하는 것이 앱 성능이 아니라 크레딧 고갈이 된다.
if [ "$MODE" = "test" ]; then
  # PRE-2-06 인스턴스 타입을 상수로 박지 않고 조회한다.
  # PRE-2-07 RDS 를 계산에 포함한다. EC2 대비 적립량이 절반이라 먼저 마른다.
  for pair in "app:AWS/EC2:CPUCreditBalance" "db:AWS/RDS:CPUCreditBalance"; do
    printf '  TODO  %-12s %s 크레딧 임계는 부하 시험 후 확정\n' PRE-2-02 "${pair%%:*}"
  done
fi

echo
if [ "$fail" = "1" ]; then
  echo "사전 점검 실패. 배포를 중단한다."
  exit 1
fi
echo "사전 점검 통과."
