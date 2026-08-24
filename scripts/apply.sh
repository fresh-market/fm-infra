#!/usr/bin/env bash
#
# 인프라를 올린다. bootstrap 을 먼저 돌리는 순서를 사람이 기억하지 않아도 되게 한다.
#
# 두 구성이 갈라져 있어 Terraform 이 순서를 세워 주지 못한다.
# 시크릿을 bootstrap 에 둔 것은 destroy 를 견디게 하려는 것이고(표준 파라미터라 유지 비용이 0 이다),
# 그 대가로 생긴 의존이 이 순서다. 여기서 흡수한다.
#
# bootstrap apply 는 멱등하다. 이미 적용되어 있으면 no-op 이므로 매번 돌려도 안전하다.
#
# 시크릿 검사를 여기서 하는 이유는 Terraform 이 db-password 하나만 보기 때문이다(rds.tf postcondition).
# 나머지 일곱은 unset 이어도 apply 가 통과하고, 인스턴스가 뜬 뒤에야 드러난다.
# GHCR 로그인 실패로 컨테이너가 안 뜨거나, Slack 알림이 조용히 안 가는 식이다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. bootstrap. 상태 버킷을 만든다.
log "1. bootstrap"
cd "$ROOT/bootstrap"

# 상태 파일이 로컬에만 있다. 다른 기계에서 클론하면 없다.
# 그대로 apply 하면 이미 있는 버킷을 다시 만들려다 BucketAlreadyOwnedByYou 로 죽는다.
# 에러를 만나기 전에 무엇을 해야 하는지 알려 준다.
if [ ! -f terraform.tfstate ] \
  && aws s3api head-bucket --bucket "tfstate-$PROJECT" --region "$REGION" 2>/dev/null; then
  die "$(cat <<EOF
bootstrap 상태 파일이 없는데 버킷 tfstate-$PROJECT 은 이미 있다.
다른 기계에서 만든 것이다. 상태는 gitignore 되어 따라오지 않는다.

  cd bootstrap
  terraform import aws_s3_bucket.tfstate tfstate-$PROJECT

시크릿 8개는 Terraform 이 관리하지 않으므로 import 하지 않는다.
아래 3단계가 없는 것만 다시 만든다.
EOF
)"
fi

terraform init -input=false > /dev/null
terraform apply -auto-approve -input=false

# 2. 시크릿 자리를 만든다. 없는 것만 만들고 있는 것은 건드리지 않는다.
#
# Terraform 이 아니라 여기서 하는 이유는 bootstrap/main.tf 주석에 있다.
# 요약하면 refresh 가 값을 복호화해 읽어 상태 파일에 평문으로 적기 때문이다.
#
# 값은 여기서 넣지 않는다. unset 으로 자리만 만들고 3단계가 빈 것을 잡아낸다.
log "2. 시크릿 자리"
while IFS='|' read -r key desc; do
  [ -z "$key" ] && continue
  aws ssm get-parameter --name "/$PROJECT/$key" --region "$REGION" > /dev/null 2>&1 && continue
  aws ssm put-parameter --name "/$PROJECT/$key" --region "$REGION" \
    --type SecureString --value unset --description "$desc" > /dev/null
  log "   $key 생성"
done <<'SECRETS'
jwt-signing-key|JWT signing key. rotated by kid
db-password|RDS master password
db-exporter-password|mysqld_exporter password. same as master
github-token|used by monitoring to clone observability config
ghcr-token|used by instances to pull images from GHCR. needs read:packages
slack-webhook-critical|Alertmanager critical channel
slack-webhook-warning|Alertmanager warning channel
slack-webhook-watchdog|Alertmanager watchdog channel
kakao-client-id|Kakao OAuth REST API key
kakao-client-secret|Kakao OAuth client secret
kakao-app-id|Kakao app id. unlink webhook 이 소유자 확인에 쓴다
kakao-admin-key|Kakao admin key. 로그아웃과 연결 해제에 쓴다
SECRETS

# 3. 시크릿이 다 찼는지 본다.
#
# SecureString 만 본다. 같은 경로에 Terraform 이 만드는 String 파라미터가 섞여 있는데
# (db-endpoint, cache-endpoint, cdn-domain, current-sha) 그것들은 일부러 unset 으로 태어나
# 5단계와 배포 스크립트가 채운다. 사람이 넣을 값이 아니다.
#
# 경로 전체를 보면 4단계가 한 번이라도 돈 뒤에는 그 셋이 걸려 여기서 멈춘다.
# 그러면 이 스크립트가 멱등하지 않게 되어 중단된 apply 를 다시 이어 붙일 수 없다.
log "3. 시크릿 확인"
unset_names=$(aws ssm get-parameters-by-path --path "/$PROJECT" --region "$REGION" \
  --with-decryption --query 'Parameters[?Value==`unset` && Type==`SecureString`].Name' --output text)

if [ -n "$unset_names" ]; then
  printf '아직 값이 없는 시크릿이 있다.\n\n'
  for n in $unset_names; do printf '  %s\n' "$n"; done
  printf '\n각각 이렇게 넣는다. 비밀번호에 $ 나 ! 가 들어갈 수 있으므로 작은따옴표를 쓴다.\n\n'
  printf "  aws ssm put-parameter --region %s --overwrite --type SecureString \\\\\n" "$REGION"
  printf "    --name %s --value '<값>'\n\n" "${unset_names%%$'\t'*}"
  printf '서명 키는 직접 정할 이유가 없다.\n\n'
  printf "  --value \"\$(openssl rand -base64 48)\"\n"
  exit 1
fi

# 4. 본 구성. 여기부터 과금이 시작된다.
#
# 승인을 묻지 않는다. 1단계 bootstrap 이 이미 -auto-approve 이고,
# 한쪽만 물으면 15분짜리 작업 중간에 사람을 기다리다 멈춰 선다.
#
# 변경 내용을 검토하려면 이 스크립트가 아니라 plan 을 먼저 돌린다.
#   terraform -chdir=terraform plan -input=false
#
# 넘긴 인자는 그대로 전달된다. -target 이나 -var 를 붙일 수 있다.
log "4. terraform"
cd "$ROOT/terraform"
terraform init -input=false -backend-config=backend.hcl > /dev/null
terraform apply -auto-approve -input=false "$@"

# 5. 엔드포인트를 SSM 에 실어 준다.
#
#    Terraform 은 이 값을 만들기만 하고 채우지 않는다. ignore_changes = [value] 가 걸려 있어서다.
#    RDS 복원은 항상 새 인스턴스를 만들어 주소가 바뀌는데(INF-26), 그때 스크립트가 갱신한 값을
#    다음 apply 가 되돌리면 안 되기 때문이다.
#
#    그 대가로 최초 1회를 채울 주체가 없었다. 신규 구축 직후 두 값이 unset 으로 남아
#    앱이 jdbc:mysql://unset:3306 으로 붙으려 한다. 여기서 메운다.
#
#    start.sh 는 재가동 때 같은 일을 한다. 이쪽은 신규 구축 경로다.
log "5. 엔드포인트 SSM 반영"
for pair in "db-endpoint:db_endpoint" "cache-endpoint:cache_endpoint" "cdn-domain:cdn_domain"; do
  name="${pair%%:*}"
  out=$(terraform output -raw "${pair##*:}")
  cur=$(aws ssm get-parameter --name "/$PROJECT/$name" --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo unset)
  if [ "$out" = "$cur" ]; then
    log "   $name 그대로"
  else
    aws ssm put-parameter --name "/$PROJECT/$name" --value "$out" \
      --type String --overwrite --region "$REGION" > /dev/null
    log "   $name 갱신"
  fi
done

# 6. 모니터링이 새 엔드포인트를 다시 읽게 한다.
#
#    모니터링은 ASG 도 아니고 deploy.sh 대상도 아니라, 스스로 갱신할 계기가 없다.
#    부팅 때 읽은 값이 unset 이면 익스포터가 unset:3306 으로 붙으려다 실패하는데,
#    인스턴스는 살아 있어 monitoring-status 알람도 안 울린다. 지표만 조용히 사라진다.
log "6. 모니터링 .env 갱신"
mon_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$mon_id" != "None" ] && [ -n "$mon_id" ]; then
  aws ssm send-command --instance-ids "$mon_id" --document-name AWS-RunShellScript \
    --region "$REGION" \
    --parameters "commands=[\"set -e\",\"/usr/local/bin/$PROJECT-refresh-monitoring-env\",\"systemctl restart observability.service\"]" \
    --query 'Command.CommandId' --output text > /dev/null
  log "   $mon_id 에 요청함"
else
  log "   실행 중인 모니터링 인스턴스가 없다"
fi

echo
log "완료. 남은 것은 둘이다"
log "  1. 확인 메일의 링크를 누른다. 구독이 다시 만들어져 CloudWatch 알람이 갈 곳이 없다"
log "  2. 배포를 한 번 돌린다. current-sha 가 bootstrap 이라 앱이 아직 뜨지 않는다"
log "       ./scripts/deploy.sh <커밋 SHA>     또는 main 에 병합해 워크플로를 돌린다"
log ""
log "  CDN 도메인과 ALB 주소는 손댈 것이 없다."
log "  앞의 것은 방금 5단계가 SSM 에 실었고, 뒤의 것은 deploy.sh 가 그때 조회한다."
log "  AWS_DEPLOY_ROLE_ARN 은 역할 이름이 결정적이라 최초 1회만 넣으면 된다."
