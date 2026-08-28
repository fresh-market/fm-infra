# 배포

## 무엇이 어디 있나

| 것 | 어디 | 왜 |
|---|---|---|
| `scripts/preflight.sh` | 이 저장소 | G-RELEASE. 런타임 상태 조회라 LLM 이 판정할 수 없다 |
| `scripts/deploy.sh` | 이 저장소 | ASG 이름과 SSM 경로가 Terraform 이 정한 값이다 |
| `scripts/rollback.sh` | 이 저장소 | 이전 SHA 로 배포를 다시 하는 것뿐이다 |
| `scripts/apply.sh` | 이 저장소 | 올린다. bootstrap 순서와 시크릿 검사를 흡수한다 |
| `scripts/stop.sh` `start.sh` | 이 저장소 | 세션 단위로 껐다 켠다 |
| `scripts/destroy.sh` | 이 저장소 | 전부 지운다 |
| `backend-deploy-workflow.yml` | 이 저장소가 원본 | fm-backend 에 복사해서 쓴다 |

배포 절차가 인프라 결정에서 나오므로 원본을 여기 둔다. backend 워크플로가 `actions/checkout` 으로 받아 쓴다. `llm-verify` 가 형제 저장소를 받아 쓰는 것과 같은 방식이다.

## main 병합 시에만 배포한다

세 겹으로 걸린다.

```
1. git-convention   팀원은 develop 으로만 PR 을 연다. main 은 관리자의 릴리스 PR 뿐이다
2. 워크플로 트리거   on: push: branches: [main]
3. AWS 신뢰 정책     repo:fresh-market/fm-backend:ref:refs/heads/main
```

**3번이 결정적이다.** 워크플로 파일을 고쳐 다른 브랜치에서 돌려도 STS 가 자격증명을 주지 않는다. 파일 수정으로 뚫리지 않는다.

## 배치는 앱 뒤에 교체한다

`deploy.sh` 10번 단계다. 배치는 ASG 밖이라 `desired` 로 다룰 수 없어 SSM 으로 서비스를 재시작한다.

```
9.  앱 구 인스턴스 종료
10. 배치 교체              SSM SendCommand -> refresh-env -> systemctl stop/start
11. 최종 확인
```

**앱보다 뒤에 하는 이유는 스키마 확장 후 축소 때문이다.** 앱이 먼저 새 버전이 되어야 배치가 새 스키마를 전제해도 안전하다.

**`.env` 를 통째로 다시 만든다.** `GIT_SHA` 한 줄만 고치지 않는다. user-data 는 최초 부팅에만 돌아서 나머지 값이 부팅 시점에 굳는데, RDS 복원은 항상 새 인스턴스를 만들어 엔드포인트가 바뀐다(`INF-26`). 부분 수정으로는 배치가 그 변화를 영원히 따라가지 못한다.

`refresh-env` 는 `terraform/templates/refresh-env.sh.tftpl` 에서 나오고 user-data 가 부팅 때 인스턴스에 심는다. **부팅과 재배포가 같은 코드를 쓴다**(`MNT-3-01`).

**롤링으로 하지 않는다.** 구버전과 신버전 배치가 겹치면 "프로세스는 항상 하나" 라는 전제가 깨지고, 분산 락이 없어 아무것도 막지 못한다. 그래서 중지 후 시작이다.

배치 교체가 실패하면 **앱은 이미 새 버전이고 배치만 옛 버전인 구간**이 남는다. 스크립트가 그 사실을 로그로 남기고 종료 코드 1로 끝낸다. 되돌리지 않는 이유는, 배치만 옛 버전인 상태가 앱까지 되돌리는 것보다 대개 덜 위험하기 때문이다.

## Terraform 과 스크립트의 경계

| 대상 | 누가 |
|---|---|
| ASG, 시작 템플릿, 대상 그룹, 리스너 | Terraform |
| **SSM 파라미터 리소스** | Terraform (시크릿은 `apply.sh` 2단계가 만든다) |
| **SSM 파라미터의 값** | **스크립트**, 시크릿은 사람이 CLI 로 |
| **desired capacity** | **스크립트** |
| 대상 등록과 해제 | 스크립트 |

Terraform 이 값이나 desired 를 건드리면 배포가 깨진다. 그래서 `ignore_changes` 를 걸어 두었다.

## 처음부터 다시 세운다

세 줄이다. 인자를 붙이지 않는다.

```bash
./scripts/destroy.sh      # 계정 ID 를 입력하면 진행된다. 15분쯤
./scripts/apply.sh        # 15~25분. RDS 와 캐시 생성이 대부분이다
./scripts/deploy.sh       # main 최신을 배포한다. 6~8분
```

중간에 **확인 메일의 링크를 눌러야 한다.** SNS 구독이 파괴되고 다시 만들어지므로 그렇고, AWS 가 사람 확인을 요구해 자동화할 수 없다. 재구축마다 남는 유일한 수동 작업이다.

`apply.sh` 는 오래 걸린다. **중간에 끊으면 상태 잠금과 고아 리소스가 남는다.** 그때는 이렇게 푼다.

```bash
terraform -chdir=terraform force-unlock -force <잠금ID>     # 먼저 terraform 프로세스가 죽었는지 확인한다
terraform -chdir=terraform import <주소> <실제ID>           # AWS 에는 있는데 상태에 없는 것
```

## 처음 적용할 때

```bash
./scripts/apply.sh
```

`bootstrap` 을 먼저 돌리고, 시크릿 자리를 만들고, 다 찼는지 본 뒤, 본 구성을 올리고, 엔드포인트를 SSM 에 싣는다. **순서를 기억할 필요가 없다.**

마지막 단계가 필요한 이유는 Terraform 이 `db-endpoint` 와 `cache-endpoint` 를 **만들기만 하고 채우지 않기** 때문이다. `ignore_changes = [value]` 가 걸려 있어서인데, RDS 복원이 항상 새 인스턴스를 만들어 주소가 바뀌므로(`INF-26`) 스크립트가 갱신한 값을 다음 `apply` 가 되돌리면 안 되기 때문이다. 그 대가로 **최초 1회를 채울 주체가 없었다.** 두 값이 `unset` 으로 남으면 앱이 `jdbc:mysql://unset:3306` 으로 붙으려 한다.

두 구성이 갈라져 있어 Terraform 이 순서를 세워 주지 못한다. 시크릿을 `bootstrap/` 에 둔 것은 `destroy.sh` 를 견디게 하려는 것이고(표준 파라미터라 유지 비용이 0 이다), 그 대가로 생긴 의존을 스크립트가 흡수한다.

시크릿이 비어 있으면 **과금이 시작되기 전에** 멈추고 이름과 명령어를 찍는다.

```
아직 값이 없는 시크릿이 있다.

  /freshmarket/db-password
  /freshmarket/ghcr-token
  ...
```

값을 넣고 다시 실행하면 된다. `bootstrap apply` 는 멱등해서 몇 번을 돌려도 no-op 이다.

| 이름 | 출처 |
|---|---|
| `db-password` | 직접 정한다. RDS 마스터 |
| `db-exporter-password` | **`db-password` 와 같은 값.** 아래를 보라 |
| `jwt-signing-key` | `openssl rand -base64 48` |
| `github-token` | PAT. `fm-infra` **Contents Read-only.** 모니터링이 클론만 한다 |
| `ghcr-token` | classic PAT, **`read:packages`.** 인스턴스가 이미지를 받는다 |
| `slack-webhook-*` | Incoming Webhook 3개. 채널이 달라야 의미가 있다 |

**`mysqld_exporter` 는 마스터 계정으로 붙는다.** 그래서 `db-exporter-password` 는 `db-password` 와 같아야 한다.

전용 계정(`exporter`)을 쓰는 편이 권한상 옳지만, RDS 는 `CREATE USER` 를 자동으로 해 주지 않는다. 전용 계정을 쓰려면 재구축할 때마다 사람이 DB 에 붙어 계정을 만들어야 하는데, 그 절차가 어디에도 없으면 잊힌다. 그 대가로 **감시 도구가 DB 전권을 갖는다.**

전용 계정으로 되돌리려면 RDS 기동 후 아래를 실행하고 `observability/compose.yaml` 의 `--mysqld.username` 을 `exporter` 로 고정한다. 이름은 환경변수가 아니라 플래그로만 들어간다. 익스포터가 환경변수로 읽는 것은 `MYSQLD_EXPORTER_PASSWORD` 하나뿐이다.

```sql
CREATE USER 'exporter'@'%' IDENTIFIED BY '<db-exporter-password>';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
```

**`db-password` 만 Terraform 이 따로 막는다**(`rds.tf` 의 postcondition). 나머지는 `unset` 이어도 apply 가 통과하고 인스턴스가 뜬 뒤에야 드러난다. GHCR 로그인 실패로 컨테이너가 안 뜨거나, `JWT_SECRET` 이 없어 앱이 기동을 못 하거나, Slack 알림이 조용히 안 가는 식이다. 그래서 스크립트가 전부를 한 번에 본다.

**다른 기계에서 클론했다면** `bootstrap/terraform.tfstate` 가 없다. gitignore 되어 따라오지 않는다. 그대로 돌리면 이미 있는 버킷을 다시 만들려다 죽으므로, 스크립트가 그 상황을 먼저 감지해 `terraform import` 명령을 알려 준다.

### 최초 1회만 하는 것

```bash
cd terraform
terraform output github_role_arns   # deploy 값을 fm-backend 의 AWS_DEPLOY_ROLE_ARN 변수로

cp docs/deploy/backend-deploy-workflow.yml ../backend/.github/workflows/deploy.yml
```

역할 이름이 `freshmarket-gha-deploy` 로 결정적이라 ARN 이 재구축에도 변하지 않는다. **한 번 넣으면 다시 넣지 않는다.**

CDN 도메인과 ALB 주소는 재구축마다 바뀌지만 **손댈 것이 없다.** 앞의 것은 `apply.sh` 5단계가 SSM `cdn-domain` 에 실어 앱 컨테이너까지 보내고, 뒤의 것은 `deploy.sh` 가 스모크 직전에 직접 조회한다.

### 재구축마다 남는 수동 작업

**SNS 이메일 구독 확인 하나뿐이다.** 구독 리소스가 파괴되고 다시 만들어지므로 확인 메일이 다시 오고, 링크를 눌러야 CloudWatch 알람이 갈 곳이 생긴다. AWS 가 사람 확인을 요구해 자동화할 수 없다.

첫 인스턴스는 `current-sha` 가 `bootstrap` 인 채로 떠서 이미지를 못 받고 unhealthy 가 된다. **이것은 손댈 필요가 없다.** 사전 점검이 healthy 0 을 지킬 용량 없음으로 보고 통과시키고, 배포가 새 인스턴스를 띄운 뒤 그 인스턴스를 종료한다.

## 세션 단위로 껐다 켠다

상시 가동이 필요 없을 때 쓴다.

```bash
./scripts/stop.sh     # ASG desired 0 -> 모니터링/배치 중지 -> RDS 중지
./scripts/start.sh    # RDS 와 인스턴스 시작 -> 엔드포인트 갱신 -> desired 1 -> healthy 대기
```

## 부하 생성기

`load_test_enabled = true` 로 올린다. 시험이 끝나면 다시 내린다.

```
m7i.large   2 vCPU / 8 GB
```

**버스터블도 flex 도 쓰지 않는다.** 크레딧 때문이 아니라 측정 안정성 때문이다.
회차마다 크레딧 상태가 다르면 같은 코드가 다른 숫자를 낸다.

**크기는 실측으로 정했다.** VU 당 0.365 MiB 이고 최악 시나리오에도 2.5 GB 다.
근거와 재측정 방법은 `loadtest/README.md` 에 있다.

**토큰을 `SharedArray` 로 넣어야 한다.** 1인 1매라 VU 마다 다른 회원의 JWT 가 필요한데,
평범하게 `open()` 으로 읽으면 VU 마다 배열 전체가 복제된다. 2만 개면 VU 당 16 MB 라
어떤 인스턴스로도 감당하지 못한다. 위 실측치는 `SharedArray` 를 쓴 값이다.

### 커널 값은 user-data 가 올린다

2만 연결을 짧은 창에 열고 닫으므로 기본값으로는 임시 포트와 파일 디스크립터가 먼저 마른다.
`ip_local_port_range`, `tcp_tw_reuse`, `nofile 250000` 을 부팅 때 건다.

**컨테이너로 돌리면 호스트 설정이 그대로 적용되지 않는다.** 두 옵션을 붙인다.

```bash
docker run --rm --network host --ulimit nofile=250000:250000 \
  -v "$PWD:/scripts" grafana/k6:1.7.1 run /scripts/coupon-burst.js
```

`--network host` 는 브리지 NAT 를 건너뛴다. 안 붙이면 NAT 테이블에서 포트가 먼저 마른다.

## 선착순 이벤트

용량 조절은 `scripts/coupon-event.sh` 가 한다.

```bash
./scripts/coupon-event.sh status      # 지금 상태
./scripts/coupon-event.sh open 2      # 전제 확인 후 전용 ASG 를 2대로
./scripts/coupon-event.sh close       # 0 으로 내리고 드레인 대기
```

`open` 이 먼저 보는 것은 셋이다. **캐시가 2노드이고 페일오버가 켜져 있는가**(이벤트 구간에는 캐시가
판정 주체라 단일 노드면 그 노드와 함께 멈춘다), **RDS 가 available 인가**, 그리고 **커넥션 예산이
남는가**다. `max_connections` 실측값 60 에 평상시 33 을 빼면 전용 인스턴스가 쓸 수 있는 몫이 나온다.

풀 10 기준으로 **2대까지 통과하고 3대부터 막힌다.**

| 대수 | 커넥션 | |
|---|---|---|
| 1 | 43 / 60 | 통과 |
| 2 | 53 / 60 | 통과 |
| 3 | 63 / 60 | `--force` 필요 |

`application-coupon.yml` 이 풀을 4~5 로 줄였다면 실제로는 넘지 않으므로 `--force` 로 넘긴다.
줄이지 않은 채 강행하면 세 번째 인스턴스가 커넥션을 못 잡는다. Hikari 의 `minimum-idle` 기본값이
`maximum-pool-size` 라 기동하면서 10 개를 채우려 들기 때문이다. readiness 가 실패하고 ASG 가
교체하고 새 인스턴스가 같은 벽에 부딪힌다. **앱 버그처럼 보이지만 원인은 커넥션 한도이고,
healthy 대기 상한 600초를 태우고서야 드러난다.**

**전용 ASG 는 `coupon_dedicated_enabled = true` 로 apply 해야 생긴다.** 없으면 `open` 이 거절한다.

**이 스크립트는 이벤트 상태를 건드리지 않는다.** Redis 네 키 정리와 `is_active` 스위치는
앱의 관리자 API 가 갖는다. 용량과 이벤트 상태를 한 스크립트에 섞으면 앱을 고칠 때마다
여기를 함께 고쳐야 한다.

**스케일링 정책에 맡기지 않고 미리 올리는 이유가 있다.** 2만 건이 몇 초에 몰리는데 알람 평가와
부팅에 수 분이 걸린다. 확장이 끝나기 전에 이벤트가 끝난다. 정책은 길게 이어지는 부하의 안전망이다.

**중지로는 절반밖에 못 줄인다.** ALB 와 ElastiCache 는 중지라는 개념이 없어 이 둘만으로 월 약 41 USD 가 계속 나간다.
캐시를 2노드로 올린 뒤(`INF-37`) 이 금액이 12 USD 늘었다. 중지 방식의 절감폭이 그만큼 줄어든 것이다.

`stop.sh` 가 앱부터 내리는 것은 의존 방향 때문이다. RDS 를 먼저 내리면 커넥션 오류가 마지막 구간의 지표를 오염시킨다. 모니터링과 배치는 ASG 밖이라 `desired` 가 아니라 `stop-instances` 로 다룬다. 앱을 `stop-instances` 로 내리면 ASG 가 비정상으로 보고 교체해 세션이 끝나지 않는다(`INF-23`).

**RDS 중지는 최대 7일이다.** 그 뒤 자동으로 다시 시작되므로 주 1회 이상 다시 내려야 한다.

## 전부 지운다

오래 안 쓸 때 쓴다.

```bash
./scripts/destroy.sh            # 계정 ID 를 직접 입력해야 진행된다
./scripts/destroy.sh --yes      # 확인을 건너뛴다. 터미널이 없을 때만 쓴다
```

`terraform destroy` 만으로는 되지 않는다. 세 겹이 막는다.

| 막는 것 | 어디서 거부되나 |
|---|---|
| `lifecycle { prevent_destroy }` 5곳 | Terraform 이 plan 단계에서 |
| `deletion_protection` (RDS, ALB) | AWS 가 API 호출을 |
| `skip_final_snapshot = false` | RDS 가 스냅샷 이름을 요구하며 |

그래서 스크립트가 **가드를 걷어내고 apply 를 한 번 돌린 뒤에야** destroy 한다. 삭제 보호는 코드만 고쳐서는 안 꺼지고 AWS 에 반영되어야 한다.

걷어낸 가드는 `trap` 으로 **반드시 되돌린다.** 중간에 실패해도 마찬가지다. 방어가 코드에 살아 있어야 다음 재구축이 안전하다. 그래서 가드 파일에 커밋 안 된 변경이 있으면 시작하지 않는다. 원복이 그것까지 되돌리기 때문이다.

**destroy 가 끝나도 EBS 볼륨이 남는다.** `delete_on_termination = false` 인 모니터링 루트 볼륨이다. 관측 데이터를 지키려는 설정이라 Terraform 이 일부러 안 지운다. 스크립트가 따로 찾아 지운다.

남는 것들은 정상이다.

- **`bootstrap/` 이 갖는 것 전부.** tfstate 버킷과 **SecureString 시크릿**이다. 대상이 아니라 그대로 살아남는다
- **KMS 키 3개** (`aws/ebs`, `aws/rds`, `aws/ssm`). AWS 관리형이라 무료이고 삭제할 수 없다
- **IAM 역할이 0 이 아니면** Terraform 밖에서 만든 것이다. 콘솔 활동의 잔재일 수 있다

**시크릿을 남기는 것이 의도다.** SSM 표준 파라미터는 무료라 지워도 아끼는 것이 없는데, 지우면 재구축 때 전부를 손으로 다시 넣어야 한다. 그래서 Terraform 밖에 둔다. 파괴하고 다시 올려도 **비밀 재입력이 없다.**

마지막에 `terraform state` 가 아니라 **AWS 에 직접 조회해** 잔여를 센다. 상태와 실제가 어긋날 수 있다.
