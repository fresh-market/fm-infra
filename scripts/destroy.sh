#!/usr/bin/env bash
#
# 전부 파괴한다. 오래 안 쓸 때 쓴다. stop.sh 로는 절반밖에 못 줄인다.
#
# terraform destroy 만으로는 되지 않는다. 세 겹이 막는다.
#   1. lifecycle prevent_destroy   Terraform 이 plan 단계에서 거부한다
#   2. deletion_protection         AWS 가 API 호출을 거부한다. 끄려면 apply 를 먼저 해야 한다
#   3. skip_final_snapshot=false   RDS 가 최종 스냅샷 이름을 요구한다
#
# 그래서 가드를 걷어내고 apply 를 한 번 돌린 뒤에야 destroy 가 된다.
# 걷어낸 가드는 마지막에 되돌린다. 방어가 코드에 살아 있어야 다음 재구축이 안전하다.
#
# destroy 가 끝나도 남는 것이 있다. delete_on_termination=false 인 EBS 볼륨이다.
# 모니터링 루트 볼륨이 그렇다. 관측 데이터를 지키려는 설정이라 Terraform 이 일부러 안 지운다.
#
# bootstrap/ 이 갖는 것은 대상이 아니다. tfstate 버킷과 SecureString 시크릿이 살아남는다.
# 시크릿은 표준 파라미터라 무료이므로 지워봐야 아끼는 것이 없고 재입력만 생긴다.
#
# 이 스크립트는 대상이 없어 실제로 검증된 적이 없다. 절차는 2026-08-21 수동 파괴에서 나왔다.
# 다음 재구축 후 첫 파괴 때가 실검증이다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/terraform"

# 가드가 박혀 있는 파일들. 마지막에 이 목록을 그대로 되돌린다.
GUARDED=(alb.tf dns.tf instances.tf rds.tf storage.tf)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

restore_guards() {
  log "가드 원복"
  (cd "$ROOT" && git checkout -- "${GUARDED[@]/#/terraform/}")
}

# 중간에 죽어도 가드는 반드시 되돌린다. 지운 채로 남으면 다음 apply 가 무방비가 된다.
trap restore_guards EXIT

# 1. 확인. 계정을 잘못 보고 지우는 사고가 가장 크다.
account=$(aws sts get-caller-identity --query Account --output text)
log "1. 대상 계정 $account / 리전 $REGION / 프로젝트 $PROJECT"

if [ "${1:-}" != "--yes" ]; then
  [ -t 0 ] || die "비대화 실행에는 --yes 가 필요하다"
  printf '계정 %s 의 모든 리소스를 지운다. RDS 데이터와 S3 미디어는 복구할 수 없다.\n' "$account"
  printf '계속하려면 계정 ID 를 그대로 입력하라: '
  read -r typed
  [ "$typed" = "$account" ] || die "입력이 계정 ID 와 다르다. 중단한다"
fi

(cd "$ROOT" && git diff --quiet -- "${GUARDED[@]/#/terraform/}") \
  || die "가드 파일에 커밋 안 된 변경이 있다. 원복이 그것까지 되돌린다. 먼저 정리하라"

# 2. 가드를 걷어낸다.
log "2. 가드 해제"
cd "$TF"
sed -i '' 's/^\( *\)prevent_destroy = true$/\1prevent_destroy = false/' "${GUARDED[@]}"
sed -i '' 's/^\( *\)enable_deletion_protection = true$/\1enable_deletion_protection = false/' alb.tf
sed -i '' 's/^\( *\)deletion_protection\( *\)= true$/\1deletion_protection\2= false/' rds.tf
sed -i '' 's/^\( *\)skip_final_snapshot\( *\)= false$/\1skip_final_snapshot\2= true/' rds.tf
# S3 는 비어 있지 않으면 삭제가 거부된다.
sed -i '' 's|^resource "aws_s3_bucket" "media" {$|resource "aws_s3_bucket" "media" {\n  force_destroy = true|' storage.tf

terraform fmt . > /dev/null
terraform validate > /dev/null || die "가드 해제 후 validate 실패"

# 3. AWS 쪽 삭제 보호를 실제로 끈다. 이 단계 없이 destroy 하면 RDS 와 ALB 에서 거부당한다.
log "3. apply (삭제 보호 해제)"
terraform apply -auto-approve -input=false

# 4. 파괴.
log "4. destroy"
terraform destroy -auto-approve -input=false

# 5. Terraform 이 일부러 안 지우는 것을 지운다.
#    delete_on_termination=false 로 살아남은 볼륨이다. 붙어 있는 인스턴스가 없어야 한다.
log "5. 고아 EBS 볼륨 정리"
orphans=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text)
if [ -n "$orphans" ]; then
  for v in $orphans; do
    log "   삭제 $v"
    aws ec2 delete-volume --region "$REGION" --volume-id "$v"
  done
else
  log "   없다"
fi

# 6. terraform state 가 아니라 AWS 에 직접 물어본다. 상태와 실제가 어긋날 수 있다.
log "6. 잔여 확인"
printf '  EC2(정지 포함) %s\n' "$(aws ec2 describe-instances --region "$REGION" \
  --filters 'Name=instance-state-name,Values=running,pending,stopping,stopped' \
  --query 'length(Reservations[].Instances[])' --output text)"
printf '  EBS            %s\n' "$(aws ec2 describe-volumes --region "$REGION" --query 'length(Volumes)' --output text)"
printf '  RDS            %s\n' "$(aws rds describe-db-instances --region "$REGION" --query 'length(DBInstances)' --output text)"
printf '  RDS 수동스냅샷 %s\n' "$(aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual --query 'length(DBSnapshots)' --output text)"
printf '  ElastiCache    %s\n' "$(aws elasticache describe-replication-groups --region "$REGION" --query 'length(ReplicationGroups)' --output text)"
printf '  ALB            %s\n' "$(aws elbv2 describe-load-balancers --region "$REGION" --query 'length(LoadBalancers)' --output text)"
printf '  ASG            %s\n' "$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --query 'length(AutoScalingGroups)' --output text)"
printf '  VPC(기본 제외) %s\n' "$(aws ec2 describe-vpcs --region "$REGION" --query 'length(Vpcs[?IsDefault==`false`])' --output text)"
printf '  EIP            %s\n' "$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text)"
# 시크릿은 남는 것이 정상이다. 0 이면 오히려 잘못됐다.
# 개수를 적지 않는다. 목록은 apply.sh 2단계가 갖고 있어 늘어나면 이쪽이 먼저 낡는다.
#
# length() 로 세지 않는다. CLI 가 응답을 페이지로 나누고 --query 를 페이지마다 적용해,
# 항목이 한 페이지를 넘으면 "10" 과 "2" 처럼 쪼개진 숫자가 각각 출력된다.
# 이름을 전부 받아 세면 페이지 수와 무관하다.
printf '  SSM 파라미터   %s (시크릿은 남는 것이 정상. Terraform 이 만든 것만 사라진다)\n' "$(aws ssm describe-parameters --region "$REGION" --query 'Parameters[].Name' --output text | wc -w | tr -d ' ')"
printf '  CloudWatch알람 %s\n' "$(aws cloudwatch describe-alarms --region "$REGION" --query 'length(MetricAlarms)' --output text)"
printf '  로그 그룹      %s\n' "$(aws logs describe-log-groups --region "$REGION" --query 'length(logGroups)' --output text)"
printf '  Route53 존     %s\n' "$(aws route53 list-hosted-zones --query 'length(HostedZones)' --output text)"

# IAM 은 글로벌이다. 서비스 연결 역할은 AWS 것이라 뺀다.
printf '  IAM 역할       %s\n' "$(aws iam list-roles \
  --query 'length(Roles[?!starts_with(Path, `/aws-service-role/`)])' --output text)"

echo
log "파괴 완료"
log "  KMS 키 3개(aws/ebs, aws/rds, aws/ssm)는 AWS 관리형이라 남는다. 무료이고 삭제할 수 없다"
log "  bootstrap/ 이 갖는 것은 남는다. tfstate 버킷과 SecureString 시크릿이다"
log "  시크릿은 표준 파라미터라 무료다. 지워봐야 아끼는 것이 없고 재입력만 생긴다"
log "  IAM 역할이 0 이 아니면 Terraform 밖에서 만든 것이다. 콘솔 활동의 잔재일 수 있다"
