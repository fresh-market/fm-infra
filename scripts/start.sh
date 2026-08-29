#!/usr/bin/env bash
#
# 세션 재가동. 기술 스택 확정 문서 부록 A.4 절차를 그대로 옮겼다.
#
# 순서가 의존 방향에서 나온다. 의존받는 쪽(RDS)부터 올린다.
# RDS 보다 앱을 먼저 올리면 커넥션 확보 실패로 기동과 교체가 반복된다.
#
# RDS 시작은 인스턴스 복구 때문에 몇 분에서 몇 시간까지 걸릴 수 있다.
# 첫 세션에서 실측해 두어야 이후 일정을 잡을 수 있다 (OPS-1-14).

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
# 앱은 2대로 운영한다. 한 대만 올리려면 DESIRED=1 로 부른다.
DESIRED="${DESIRED:-2}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# stop.sh 가 disable-alarm-actions 로 꺼 둔 것을 되돌린다.
enable_alarms() {
  aws cloudwatch enable-alarm-actions --region "$REGION" \
    --alarm-names "$PROJECT-healthy-host-count" "$PROJECT-monitoring-status"
}
started=$(date +%s)

# 1. RDS 와 모니터링을 함께 올린다. 서로 무관하다.
status=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo missing)
if [ "$status" = "stopped" ]; then
  log "1. RDS 시작"
  aws rds start-db-instance --db-instance-identifier "$PROJECT-db" --region "$REGION" > /dev/null
else
  log "1. RDS 상태가 $status 다"
fi

for role in monitoring batch; do
  id=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=$role" "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  if [ "$id" != "None" ] && [ -n "$id" ]; then
    log "1. $role 인스턴스 시작 $id"
    aws ec2 start-instances --instance-ids "$id" --region "$REGION" > /dev/null
  fi
done

# 2. RDS 가 available 이 된 뒤에 앱을 올린다.
#    이 대기가 이 스크립트의 핵심이다. 먼저 올리면 앱이 커넥션을 못 잡고 교체된다.
log "2. RDS available 대기"
aws rds wait db-instance-available --db-instance-identifier "$PROJECT-db" --region "$REGION"
log "   RDS 준비 완료 ($(( $(date +%s) - started ))초 경과)"

# 복원이나 페일오버로 엔드포인트가 바뀌었을 수 있다.
# 중지와 시작만으로는 안 바뀌지만, 값이 어긋나면 앱이 옛 주소로 붙으려 한다 (INF-26).
endpoint=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" \
  --region "$REGION" --query 'DBInstances[0].Endpoint.Address' --output text)
current=$(aws ssm get-parameter --name "/$PROJECT/db-endpoint" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo unset)
if [ "$endpoint" != "$current" ]; then
  log "   DB 엔드포인트가 바뀌었다. SSM 갱신"
  aws ssm put-parameter --name "/$PROJECT/db-endpoint" --value "$endpoint" \
    --type String --overwrite --region "$REGION" > /dev/null
fi

# 배치와 모니터링은 중지했다 시작한 것이라 .env 가 부팅 시점 값 그대로다.
# 그동안 엔드포인트가 바뀌었으면 여기서 따라잡는다.
batch_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=batch" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$batch_id" != "None" ] && [ -n "$batch_id" ]; then
  log "2. 배치 .env 갱신 $batch_id"
  aws ssm send-command --instance-ids "$batch_id" --document-name AWS-RunShellScript \
    --region "$REGION" \
    --parameters "commands=[\"set -e\",\"/usr/local/bin/$PROJECT-refresh-env\",\"systemctl restart $PROJECT.service\"]" \
    --query 'Command.CommandId' --output text > /dev/null
fi

mon_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$mon_id" != "None" ] && [ -n "$mon_id" ]; then
  log "2. 모니터링 .env 갱신 $mon_id"
  aws ssm send-command --instance-ids "$mon_id" --document-name AWS-RunShellScript \
    --region "$REGION" \
    --parameters "commands=[\"set -e\",\"/usr/local/bin/$PROJECT-refresh-monitoring-env\",\"systemctl restart observability.service\"]" \
    --query 'Command.CommandId' --output text > /dev/null
fi

# 올릴 수 있는 버전이 있는지 먼저 본다.
#
# current-sha 가 bootstrap 이면 받을 이미지가 없다. 인프라를 내려둔 동안 main 에 머지하면
# 이미지는 GHCR 에 올라가지만 deploy.sh 가 preflight 에서 멈춰 이 값을 못 채운다.
#
# 그대로 desired 를 올리면 없는 태그를 받으려는 인스턴스가 교체를 반복한다.
# 앱 버그처럼 보이지만 원인은 태그가 없는 것이고, healthy 대기 상한을 태우고서야 드러난다.
sha=$(aws ssm get-parameter --name "/$PROJECT/current-sha" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo bootstrap)

if [ "$sha" = "bootstrap" ] || [ "$sha" = "unset" ]; then
  log "3. ASG 를 올리지 않는다. current-sha 가 $sha 라 받을 이미지가 없다"
  log "   배포를 돌리면 그때 current-sha 가 채워지고 인스턴스가 뜬다."
  log "     ./scripts/deploy.sh <커밋 SHA>"
  log "   또는 GitHub Actions 의 배포 워크플로를 다시 실행한다."
  log "   나머지(RDS, 모니터링, 배치)는 올라와 있다."
  enable_alarms
  exit 0
fi

log "3. ASG desired $DESIRED (이미지 $sha)"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$PROJECT-app" \
  --desired-capacity "$DESIRED" --region "$REGION"

# 4. readiness 확인. 배포 절차의 사전 점검과 같은 것을 본다.
log "4. 대상 그룹 healthy 대기 (상한 600초)"
tg_arn=$(aws elbv2 describe-target-groups --names "$PROJECT-app" \
  --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text)
deadline=$(( $(date +%s) + 600 ))
while true; do
  healthy=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$REGION" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  [ "$healthy" -ge "$DESIRED" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    # 실패해도 알림은 되살린다. 이 상태는 진짜 장애라 알람이 우는 것이 맞다.
    enable_alarms
    log "   healthy $healthy / $DESIRED. 상한 초과. 앱 로그를 확인하라"
    exit 1
  fi
  sleep 15
done

# 5. stop.sh 가 꺼 둔 알림을 되살린다.
#    healthy 를 확인한 뒤에 켠다. 먼저 켜면 기동 중인 구간이 장애로 잡힌다.
log "5. 알람 알림 재개"
enable_alarms

log "재가동 완료. 총 $(( $(date +%s) - started ))초"
log "이 값을 OPS-1-14 실측치로 기록한다"
