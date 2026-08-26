# 관측 스택

모니터링 인스턴스에서 도는 것들이다. Terraform 이 기계를 만들고 여기가 그 위에서 무엇을 돌릴지 정한다.

## 왜 Terraform 이 아닌가

알람 임계값은 부하 시험 후에 여러 번 고칠 값이다. Terraform 에 넣으면 한 줄 고칠 때마다 `apply` 를 해야 한다.

`INF-32` 가 "알람 규칙과 설정을 Git 으로 관리하고 읽기 전용 마운트" 로, `OPS-2-18` 이 "설정을 Git 으로 변경 후 reload 로 반영되고 인스턴스 재생성 후에도 유지되는가" 로 이 분리를 요구한다.

```
설정 커밋  ->  인스턴스에서 git pull  ->  해당 컨테이너 재시작
```

**`reload` 만으로는 반영되지 않는다.** 설정 파일을 파일 단위로 바인드 마운트하는데, `git pull` 은 파일을 제자리에서 고치지 않고 새 파일로 갈아치운다. 컨테이너는 옛 파일을 계속 들고 있어 `POST /-/reload` 가 200 을 돌려주면서도 내용은 그대로다.

실제로 그렇게 놓쳤다. `rules.yml` 의 CPU 크레딧 알람을 고치고 reload 했는데 Prometheus 는 몇십 분 동안 옛 표현식을 평가하고 있었다. `curl` 의 응답 코드만 보면 성공으로 보인다.

```bash
cd /opt/freshmarket/infra && git pull --ff-only
cd observability && docker compose restart prometheus       # 규칙과 스크레이프 설정
docker compose up -d --force-recreate cloudwatch-exporter   # 익스포터 설정
```

반영됐는지는 파일이 아니라 **프로세스에 물어본다.**

```bash
curl -s localhost:9090/api/v1/rules | grep -o '"query":"[^"]*"'
```

## 포트

문서에 없어 여기서 정한다. 보안 그룹이 이 값을 참조한다.

| 프로세스 | 포트 | 어디서 도나 |
|---|---|---|
| Prometheus | 9090 | 모니터링 |
| Grafana | 3000 | 모니터링 |
| Loki | 3100 | 모니터링 |
| Alertmanager | 9093 | 모니터링 |
| mysqld_exporter | 9104 | 모니터링 |
| redis_exporter | 9121 | 모니터링 |
| cloudwatch_exporter | 9106 | 모니터링 |
| **node_exporter** | **9100** | **모든 인스턴스** |
| **cAdvisor** | **8082** | **모든 인스턴스** |
| Alloy | 12345 | 모든 인스턴스 |

Alloy 는 로그를 **밀어 넣는다**. 지표 스크랩과 방향이 반대라 `SG-mon` 에 3100 인바운드가 필요하다.

**cAdvisor 기본값은 8080 인데 앱과 겹쳐 8082 로 옮겼다.**

앞의 일곱은 모니터링 인스턴스 안에서만 오가므로 보안 그룹을 열지 않는다. `node_exporter` 와 `cAdvisor` 는 앱과 배치 인스턴스에도 떠서 모니터링이 긁어야 하므로 `SG-app` 과 `SG-batch` 에 규칙이 필요하다.

## 화면 보는 법

경로가 둘이다. 도메인이 없으면 첫 번째뿐이다.

### SSM 포트 포워딩 (도메인 없을 때)

Grafana 의 3000 은 인터넷에 열지 않는다.

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

인스턴스 ID 는 태그로 찾는다.

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

Prometheus(9090)나 Alertmanager(9093)도 `portNumber` 만 바꾸면 같은 방식으로 본다.

### 브라우저 (도메인이 있을 때)

`https://grafana.<도메인>` 이다. ALB 가 Google 로 인증을 끝낸 뒤에만 뒤로 넘긴다.
Grafana 의 3000 은 여전히 안 열린다. `SG-mon` 에 ALB 출처로만 규칙이 하나 생길 뿐이다.

팀원은 Grafana 계정을 따로 만들지 않는다. ALB 가 넘겨준 이메일로 Viewer 가 자동 생성된다.

여는 순서는 이렇다.

```bash
# 1. Google Cloud Console 에서 OAuth 2.0 클라이언트 ID 를 만든다 (유형: 웹 애플리케이션).
#    승인된 리디렉션 URI 에 아래를 넣는다. ALB 가 고정으로 쓰는 경로다.
#      https://grafana.<도메인>/oauth2/idpresponse

# 2. 클라이언트 보안 비밀번호를 SSM 에 넣는다.
#    apply.sh 의 시크릿 목록에는 없다. 넣으면 Grafana 를 안 쓰는 동안에도 apply 가 막힌다.
aws ssm put-parameter --name /freshmarket/grafana-oidc-client-secret \
  --type SecureString --value '<client secret>' --region ap-northeast-2

# 3. tfvars 에 클라이언트 ID 와 도메인을 채우고 apply 한다.
#      domain_name            = "api.example.com"
#      grafana_oidc_client_id = "....apps.googleusercontent.com"

# 4. 모니터링 인스턴스에서 .env 를 다시 만들고 Grafana 를 재시작한다.
#    ROOT_URL 과 인증 프록시 설정이 여기서 들어간다.
sudo /usr/local/bin/freshmarket-refresh-monitoring-env
cd /opt/freshmarket/infra/observability && docker compose up -d grafana
```

`terraform output grafana_url` 이 주소를 알려준다. 비어 있으면 아직 1~3 단계가 안 끝난 것이다.

#### 이미 떠 있는 모니터링 인스턴스에는 4단계 전에 한 걸음이 더 있다

`refresh-monitoring-env` 는 user-data 가 최초 부팅에 한 번만 설치한다.
모니터링은 EBS 에 관측 데이터가 있어 재생성하지 않으므로 (`INF-24`), 템플릿을 고쳐도 떠 있는 인스턴스의 스크립트는 옛 것이다.
`apply` 는 성공하는데 `.env` 에 `GRAFANA_` 두 줄이 안 들어가고, Grafana 는 인증 프록시가 꺼진 채로 뜬다.
막히지는 않고 팀원이 Grafana 로그인 화면을 보게 되는 형태로 어긋난다.

박스에서 스크립트를 다시 깐다. 템플릿이 쓰는 값은 셋뿐이라 치환으로 끝난다.

```bash
cd /opt/freshmarket/infra && git pull --ff-only
sed -e 's/${project}/freshmarket/g' \
    -e 's/${region}/ap-northeast-2/g' \
    -e 's/${db_username}/freshmarket/g' \
    terraform/templates/refresh-monitoring-env.sh.tftpl \
  | sudo tee /usr/local/bin/freshmarket-refresh-monitoring-env > /dev/null
sudo chmod 755 /usr/local/bin/freshmarket-refresh-monitoring-env
```

이 템플릿을 고칠 때마다 같은 일이 필요하다. 재구축으로 인스턴스가 새로 뜨는 경우에는 필요 없다.

## 대시보드

`grafana/dashboards/*.json` 이 Git 에 있고 프로비저닝으로 올라간다.
화면에서 고친 것은 저장되지 않는다 (`allowUiUpdates: false`). 데이터소스를 코드로 넣은 것과 같은 이유다 (`OPS-2-18`).

| 파일 | 화면 | 무엇을 보나 |
|---|---|---|
| `01-overview.json` | 01 서비스 개요 | 요청률, 5xx 비율, 응답시간 분위수, ALB 지표 |
| `02-hosts.json` | 02 호스트 | CPU 크레딧, CPU, 메모리, 디스크, 컨테이너 재기동 |
| `03-app-jvm.json` | 03 앱과 JVM | 힙, GC, HikariCP, 톰캣 스레드, 배치 마지막 성공 |
| `04-data-stores.json` | 04 데이터 저장소 | MySQL 커넥션과 쿼리, RDS 메모리, 캐시 적중률 |

**임계값이 있는 패널에는 선을 그어 두었다.** `rules.yml` 의 값과 같은 값이다.
CPU 크레딧 173 과 58, 디스크 80%, Hikari 대기 9, 컨테이너 재기동 3회, 배치 1800초다.
알람이 울리기 전에 어디쯤 와 있는지 화면에서 먼저 보라고 맞춰 둔 것이다.

**`(미정)` 을 채울 값을 읽는 자리도 표시해 두었다.** p99 기준선, 톰캣 스레드 사용률,
RDS 여유 메모리가 그것이고, 해당 패널 설명에 적어 두었다. 부하 시험 뒤 이 화면에서 읽어 `rules.yml` 에 넣는다.

고치는 절차는 설정 파일과 같다.

```bash
cd /opt/freshmarket/infra && git pull --ff-only
# 프로비저닝이 30초마다 파일을 다시 읽어 재시작이 필요 없다.
```

### CloudWatch 지표 이름 확인

`cloudwatch_exporter` 는 CloudWatch 이름을 자기 규칙으로 바꿔 내보낸다.
`aws_ec2_cpucredit_balance_average` 는 `rules.yml` 이 쓰고 있어 확인된 이름이지만,
ALB 와 RDS 쪽 이름은 첫 기동 때 한 번 맞춰 보는 것이 빠르다.

```bash
curl -s localhost:9106/metrics | grep -o '^aws_[a-z_0-9]*' | sort -u
```

다르면 `01-overview.json` 과 `04-data-stores.json` 의 해당 패널 `expr` 을 고친다.

## 아직 채우지 못한 임계값

문서가 `(미정)` 으로 둔 것들이다. 부하 시험 전에는 값을 지어내지 않는다.

| 알람 | 무엇이 필요한가 |
|---|---|
| 502 발생 | 정상 구간의 502 발생률 |
| RDS 여유 메모리 | 정상 구간의 여유 메모리 |
| 톰캣 스레드 사용률 | 정상 구간의 사용률 |
| ConsumedLCUs | 정상 구간의 LCU 소비 |
| p99 응답시간 | 기준선 |
| 배치 미실행 | 배치 주기 |
| 정합성 검증 실패 | 검증 쿼리와 그 결과를 내보내는 경로 |

`rules.yml` 하단에 자리만 주석으로 남겨 두었다.
