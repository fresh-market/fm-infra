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

포트를 밖으로 열지 않는다. SSM 포트 포워딩으로 본다.

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

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
