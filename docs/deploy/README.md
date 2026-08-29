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

`scripts/loadtest-box.sh` 가 띄우고 내린다.

```bash
./scripts/loadtest-box.sh up       # 띄우고 토큰까지 준비될 때까지 기다린다
./scripts/loadtest-box.sh status   # 가동 시간과 누적 비용
./scripts/loadtest-box.sh down     # 지운다. 과금이 멈춘다
```

**`load_test_enabled` 를 tfvars 에 두지 않는다.** `true` 로 적어 두면 다른 이유로 apply 할
때마다 되살아난다. 시간당 과금이라 켜져 있는 것을 알아채는 데 며칠이 걸린다.
스크립트가 `-var` 로 넘기므로 이걸로 켠 동안만 존재한다.

대가는 시험 중에 누가 apply 를 돌리면 인스턴스가 사라진다는 것이다. `up` 을 다시 부르면 되고,
반대쪽 실수보다 싸다.

**공짜가 아니다.** `m7i-flex.large` 가 free-tier-eligible 로 나오는 것은 프리 티어 계정이
띄울 수 있는 타입이라는 뜻이지 무료라는 뜻이 아니다. 무료 할당은 `t3.micro` 계열 월 750시간뿐이다.

| | |
|---|---:|
| 시간당 | 0.1177 USD |
| 하루 | 2.83 USD |
| 한 달 | 85.93 USD |

프리 티어 크레딧에서 차감된다.

```
m7i.xlarge   4 vCPU / 16 GB
```

ramp-up 을 "동시 사용자 수가 60초에 걸쳐 2만에 도달" 로 읽었으므로 VU 가 2만 개 뜬다.
목 서버 상대로 실제로 돌려 5.0 GB 를 썼다.

**버스터블도 flex 도 쓰지 않는다.** 크레딧 때문이 아니라 측정 안정성 때문이다.
회차마다 크레딧 상태가 다르면 같은 코드가 다른 숫자를 낸다.

**크기는 실측으로 정했다.** k6 1.7.1 로 목 서버를 상대로 VU 를 올려가며 쟀다 (2026-08-28).

```
VU     1      49.5 MiB     기준선. SharedArray 토큰 5 MB 포함
VU   100      72.7 MiB
VU   500     218.7 MiB
VU  1000     489.3 MiB
VU  3000    1119.2 MiB
VU  6000    1967.1 MiB     한계 비용 0.28 MiB/VU 로 안정
VU 20000    5076.0 MiB     60초 램프 전 구간
```

k6 문서가 드는 VU 당 1~5 MB 보다 훨씬 낮다. 스크립트가 POST 하나뿐이고
토큰을 `SharedArray` 로 공유하기 때문이다. **평범한 배열로 두면 VU 마다 사본이 생겨
2만 VU 에서 감당할 수 없다.**

`m7i.large`(8 GB)로도 63% 라 들어가지만 여유가 얇다. 목 서버는 응답이 빨라
in-flight 버퍼가 적게 잡혔는데 실제 서버는 큐에서 밀려 그보다 커진다.
**시연 한 번을 날리는 값이 인스턴스 차액보다 크다.**

**CPU 는 실측하지 못했다.** 목 서버가 먼저 막혀 k6 가 한계까지 안 갔다.
첫 실행에서 아래 셋을 보고 다음 회차에 조정한다.

| 확인 | 어긋나면 |
|---|---|
| 램프 끝에 `20000/20000 VUs` 에 도달했는가 | VU 생성이 CPU 를 못 따라갔다. `m7i.2xlarge` |
| `dropped_iterations == 0` 인가 | 부하를 다 못 보냈다. VU 상한이나 인스턴스를 올린다 |
| 연결 실패가 0 인가 | 요청이 앱까지 닿지 못했다. ALB 연결 한도, 포트 고갈, accept 큐 |

**시나리오와 토큰과 씨딩은 백엔드 저장소가 갖는다** (`fm-backend/loadtest/`).
API 계약과 스키마에 붙어 있어 코드와 함께 바뀌기 때문이다.
이 저장소는 그것을 돌릴 환경만 갖는다.

**토큰을 `SharedArray` 로 넣어야 한다.** 1인 1매라 VU 마다 다른 회원의 JWT 가 필요한데,
평범하게 `open()` 으로 읽으면 VU 마다 배열 전체가 복제된다. 2만 개면 VU 당 16 MB 라
어떤 인스턴스로도 감당하지 못한다. 위 실측치는 `SharedArray` 를 쓴 값이다.

### 커널 값은 user-data 가 올린다

2만 연결을 짧은 창에 열고 닫으므로 기본값으로는 임시 포트와 파일 디스크립터가 먼저 마른다.
`ip_local_port_range`, `tcp_tw_reuse`, `nofile 250000` 을 부팅 때 건다.

**k6 는 컨테이너로 안 돌린다.** user-data 가 apt 로 직접 깐다. 2만 연결을 만드는 것이 일이라
호스트의 `nofile` 과 포트 범위를 그대로 써야 하는데, 컨테이너로 두면 위 설정이 안 먹어
`--ulimit` 와 `--network host` 를 또 맞춰야 하고 네트워크 네임스페이스가 한 겹 더 낀다.

### 시나리오와 토큰은 부팅 때 준비된다

`user_data` 가 `fm-backend` 의 `loadtest/` 를 받고 토큰을 찍어 둔다.
**레포가 public 이라 자격증명 없이 클론한다.** SSM 에서 읽는 것은 `jwt-signing-key` 하나다.

```
/opt/loadtest/
├── fm-backend/loadtest/    시나리오 (issue.js, seed-*.sql, mint-tokens.py)
│   └── tokens.csv          토큰 2만 장
├── refresh.sh              다시 받고 다시 찍는다
├── mint.out                관리자 토큰 (0600)
├── k6-version.txt          이 회차에 쓴 k6 버전
└── env                     BASE_URL=http://<alb-dns>
```

**시험 직전에 `refresh.sh` 를 한 번 돌려라.**

```bash
sudo /opt/loadtest/refresh.sh
```

토큰이 6시간짜리다 (`mint-tokens.py` 의 `VALIDITY_SECONDS`). 인스턴스를 아침에 띄우고
오후에 시험하면 전부 만료된 채로 시작하고, **401 이 쏟아지는 모양이 앱 장애로 보인다.**

### 돌린다

```bash
cd /opt/loadtest/fm-backend/loadtest
set -a; source /opt/loadtest/env; set +a
k6 run -o experimental-prometheus-rw -e BASE_URL="$BASE_URL" -e COUPON_ID=900001 issue.js
```

`set -a` 로 감싸는 것은 `K6_PROMETHEUS_RW_*` 가 환경 변수로 나가야 k6 가 읽기 때문이다.

**출력 이름이 `experimental-prometheus-rw` 다.** 1.7.1 기준이고 `prometheus-rw` 는 없다.
버전을 올릴 때 이 이름이 바뀔 수 있으니 `k6 run -o bogus x.js` 로 목록을 먼저 본다.

### Grafana 에서 본다

Grafana 의 **05 부하 시험** 대시보드다. 도는 중에 실시간으로 보인다.

**이 화면만 보면 안 된다.** 같은 시간대로 **03 앱과 JVM**, **04 데이터 저장소**를 함께 열어야
p99 가 튄 이유를 읽을 수 있다. 부하 시험에서 알고 싶은 것은 지연 그 자체가 아니라
그것이 튈 때 힙과 커넥션 풀과 락 대기가 무엇을 하고 있었나이기 때문이다.

지표 이름은 k6 1.7.1 로 실제 확인했다. 트렌드는 **초 단위**다 (요약 출력의 ms 와 다르다).
`dropped_iterations` 하나만 확인하지 못했다. 드롭이 있을 때만 나오는 값이라 확인 회차에서 안 났다.

CSV 도 함께 남기려면 `--out csv=result.csv` 를 붙인다. 둘 다 된다.

### 회차 결과를 남긴다

```bash
./scripts/loadtest-export.sh --since 30m --label v4-1차
```

Prometheus 에서 그 구간의 지표를 내려 `loadtest-runs/<시각>_<이름>/` 에 저장한다.
k6 뿐 아니라 JVM, HikariCP, MySQL, Redis, 호스트 지표를 같은 시간축으로 함께 받는다.
**k6 만 받으면 "느려졌다" 까지만 알고 왜 느려졌는지는 못 읽는다.**

`meta.json` 에 커밋 SHA, 인스턴스 타입, ASG 대수를 함께 적는다. 회차를 비교할 때
무엇이 달라서 숫자가 다른지 읽으려면 이것이 있어야 한다.

**그림이 아니라 데이터를 남기는 이유가 있다.**

그라파나 스냅샷은 `grafana-data` 도커 볼륨에 저장된다. destroy 하면 함께 사라지는데
이 프로젝트는 재구축을 반복하므로 회차 기록으로 못 쓴다. PNG 자동 생성은 이미지 렌더러
(헤드리스 크로미움)를 모니터링에 얹어야 하는데, 그 박스는 관측 스택으로 2 GB 를 이미
쓰고 있어 넣을 자리가 없다. 배치가 같은 이유로 OOM 난 직후라 더욱 그렇다.

데이터로 남기면 destroy 해도 남고, 대시보드 JSON 이 Git 에 있으므로 같은 그림을 언제든
다시 만들 수 있다. **Prometheus 보존이 15일이라 그 전에 내려야 한다.**

화면으로 볼 때는 그냥 https://freshmenmarket.duckdns.org 에서 보고 필요한 것을 캡처한다.
`loadtest-runs/` 는 gitignore 대상이다. 보관할 회차만 골라 문서에 붙인다.

**시드 SQL 은 자동으로 안 들어간다.** DB 에 쓰는 동작이라 부팅 때 돌면 위험해서 뺐다.
아래 순서로 먼저 넣는다.

### 시드는 배치 인스턴스를 거친다

`scripts/loadtest-seed.sh` 가 한다.

```bash
./scripts/loadtest-seed.sh apply     # 회원 2만, 쿠폰 900001, 주변 데이터
./scripts/loadtest-seed.sh verify    # 몇 장이 나갔는지
./scripts/loadtest-seed.sh reset     # 회차 사이 되돌리기
```

**부하 생성기는 RDS 에 못 붙는다.** SG 가 3306 을 막아 두었고 그대로 둔다. 2만 명을 사칭하는
기계에 DB 자격증명까지 줄 이유가 없다. 그래서 배치 인스턴스에 SSM Run Command 로 붙는다.
DB 에 닿을 수 있는 것 중 이 일에 가장 가깝다. 앱은 ASG 가 언제든 갈아치우고 모니터링은 관측용이다.

SQL 은 `raw.githubusercontent.com` 에서 바로 받는다. 레포가 public 이라 자격증명이 없고,
**시나리오와 같은 커밋의 시드를 쓰게 되어 둘이 어긋나지 않는다.** 다른 커밋을 쓰려면 `BACKEND_REF` 로 준다.

비밀번호는 `MYSQL_PWD` 로 넘긴다. 명령줄에 놓으면 `ps` 에 보이고 SSM 명령 이력에도 남는다.

### 전체 순서

| | 무엇 | 어디서 |
|---|---|---|
| 1 | 시드 주입 | `loadtest-seed.sh apply` (로컬에서) |
| 2 | 토큰 찍기 | `sudo /opt/loadtest/refresh.sh` (생성기에서) |
| 3 | 전용 ASG 올리기 | `coupon-event.sh open 3` (로컬에서) |
| 4 | 이벤트 열기 | 앱의 관리자 API |
| 5 | 시험 | `k6 run ...` (생성기에서) |
| 6 | 결과 확인 | `loadtest-seed.sh verify` + Grafana |
| 7 | 되돌리기 | `loadtest-seed.sh reset`, `coupon-event.sh close` |

**4번을 SQL 로 대신하면 안 된다.** `is_active` 만 켜면 카운터 없는 Redis 를 요청이 쳐서
전부 "준비되지 않음" 으로 끝난다. 여는 API 가 Redis 를 세우는 것이 핵심이다.

로컬에서 도는 절차는 `fm-backend/loadtest/README.md` 가 따로 갖는다. 그쪽은 `docker exec` 로
컨테이너 MySQL 에 붓는 방식이라 여기와 다르다.

**k6 버전을 회차 기록에 함께 적어라.** 아래 메모리 실측이 1.7.1 기준이고 apt 는 최신을 깐다.

## 선착순 이벤트

용량 조절은 `scripts/coupon-event.sh` 가 한다.

```bash
./scripts/coupon-event.sh status      # 지금 상태
./scripts/coupon-event.sh open 2      # 전제 확인 후 전용 ASG 를 2대로
./scripts/coupon-event.sh close       # 0 으로 내리고 드레인 대기
```

`open` 이 먼저 보는 것은 셋이다. **캐시가 2노드이고 페일오버가 켜져 있는가**(이벤트 구간에는 캐시가
판정 주체라 단일 노드면 그 노드와 함께 멈춘다), **RDS 가 available 인가**, 그리고 **커넥션 예산이
남는가**다. `max_connections` 실측값 60 에서 평상시 사용을 빼면 전용 인스턴스가 쓸 수 있는 몫이 나온다.
평상시는 앱 ASG 상한(3대 x 풀 8) + 배치 4 + 관리 3 = 31 로 잡는다. 앱이 오토스케일링이라
이벤트 중 몇 대일지 모르므로 상한으로 최악을 잡는 것이다.

**세 대까지 여유롭게 통과한다.** 전용 풀이 2 라 대당 2개씩만 는다.

| 대수 | 커넥션 | |
|---|---|---|
| 1 | 33 / 60 | 통과 |
| 2 | 35 / 60 | 통과 |
| 3 | 37 / 60 | 통과 |

**2026-08-29 이전에는 3대가 막혔다.** 세 프로필이 모두 풀 10 이던 때는 63 이 나와 `--force` 가
필요했다. 백엔드가 앱 8 / 배치 4 / 선착순 2 로 가른 뒤로는 여유가 크다.

스크립트의 `APP_POOL`, `BATCH_POOL`, `COUPON_POOL` 이 그 값을 복사해 둔 것이다.
**`application-*.yml` 을 고치면 여기도 고쳐야 한다.** 어긋나면 검산이 조용히 틀린다.

**전용 ASG 는 `coupon_dedicated_enabled = true` 로 apply 해야 생긴다.** 없으면 `open` 이 거절한다.

**이 스크립트는 이벤트 상태를 건드리지 않는다.** Redis 네 키 정리와 `is_active` 스위치는
앱의 관리자 API 가 갖는다. 용량과 이벤트 상태를 한 스크립트에 섞으면 앱을 고칠 때마다
여기를 함께 고쳐야 한다.

**스케일링 정책에 맡기지 않고 미리 올리는 이유가 있다.** 2만 건이 몇 초에 몰리는데 알람 평가와
부팅에 수 분이 걸린다. 확장이 끝나기 전에 이벤트가 끝난다. 정책은 길게 이어지는 부하의 안전망이다.

**재개했는데 앱이 안 뜨는 경우가 하나 있다.** 인프라를 내려둔 동안 `main` 에 머지하면
이미지는 GHCR 에 올라가지만 `deploy.sh` 가 사전 점검에서 멈춰 `current-sha` 를 못 채운다.

`start.sh` 가 그 상태를 알아보고 ASG 를 올리지 않는다. RDS 와 모니터링과 배치까지만 올리고
배포를 돌리라고 안내한 뒤 끝난다. 그대로 올렸다면 없는 태그를 받으려는 인스턴스가
교체를 반복하다 10분 뒤에야 실패했을 것이다.

```bash
./scripts/start.sh              # 인프라만 올라온다
./scripts/deploy.sh <커밋 SHA>   # current-sha 를 채우고 인스턴스를 띄운다
```

두 번째는 GitHub Actions 에서 실패한 배포 워크플로를 다시 실행해도 된다.

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
