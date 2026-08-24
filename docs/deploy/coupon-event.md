# 선착순 쿠폰 이벤트 인프라

이벤트 구간에만 켜는 별도 경로를 만든다. 평소에는 리소스가 0 이고 과금도 없다.

앱 설계는 `fm-backend` 의 `docs/coupon/README.md` 가 갖는다. 이 문서는 **그 구조를 AWS 에 어떻게 올리고 내리는가**만 다룬다.

---

## 1. 무엇이 생기나

```
                       ALB (기존)
        +-----------------+-----------------+
   priority 20                          default
   path = 발급 경로                      그 밖의 모든 경로
        |                                   |
   tg-coupon                            tg-app (기존)
   asg-coupon (prod,coupon)             asg-app (prod)
        |                                   |
        +----------------+------------------+
                         |
              ElastiCache          RDS (기존, 단일)
              primary + replica
```

| 리소스 | 평소 | 이벤트 |
|---|---|---|
| `aws_lb_target_group.coupon` | 없음 | 1 |
| `aws_lb_listener_rule.coupon` | 없음 | 1 |
| `aws_autoscaling_group.coupon` | 없음 | 1 (desired N) |
| `aws_launch_template.coupon` | 없음 | 1 |
| ElastiCache 복제본 | 0 | 1 |

**전부 `coupon_event_enabled` 하나로 켜고 끈다.** `load_test_enabled` 와 같은 방식이다. 상시 가동 전제의 명시적 예외라 `count` 로 다룬다.

---

## 2. 왜 별도 ASG 인가

같은 이미지를 쓰면서 ASG 만 나누는 이유는 셋이다.

**격벽.** 선착순 트래픽이 톰캣 스레드와 커넥션 풀을 다 먹어도 상품 조회와 주문은 다른 인스턴스에서 돈다. 규칙 하나를 지우면 선착순만 차단하고 나머지는 살릴 수 있다.

**커넥션 예산.** 전용 프로파일(`prod,coupon`)로 Hikari 풀을 앱보다 작게 잡는다. 5장을 보라.

**측정.** 전용 인스턴스만 재면 다른 트래픽이 지표를 오염시키지 않는다. 버전 비교가 목적이므로 이게 중요하다.

### 규칙이 없으면 기존 앱이 받는다

ALB 규칙을 안 만들면 발급 경로도 `tg-app` 의 기본 동작으로 흘러간다. **선착순 기능이 사라지는 것이 아니라 전용 격벽이 없어질 뿐이다.** 이벤트를 안 하는 평소에는 그게 맞는 상태다.

---

## 3. 켜는 순서

순서가 의존 방향에서 나온다. **캐시 복제본이 먼저, 트래픽이 마지막이다.**

```bash
# 1. 인프라를 올린다. 캐시 복제본과 전용 ASG 가 함께 생긴다.
#    캐시 복제본 추가는 수 분 걸리고 그동안 primary 는 정상 동작한다.
coupon_event_enabled = true
coupon_desired       = 2
./scripts/apply.sh

# 2. 전용 인스턴스가 healthy 인지 본다. 여기서 실패하면 3번을 하지 않는다.
aws elbv2 describe-target-health --target-group-arn <tg-coupon> --region ap-northeast-2

# 3. 트래픽을 보낸다. ALB 규칙은 1번에서 이미 만들어졌으므로 여기서 할 일은 확인뿐이다.
curl -i https://<alb>/v1/coupons/1/issue
```

**2번을 건너뛰지 않는다.** 규칙이 먼저 서고 인스턴스가 안 떠 있으면 발급 경로가 통째로 503 이 된다.

### 내리는 순서

올리는 순서의 역순이다.

```bash
coupon_event_enabled = false
./scripts/apply.sh
```

ALB 규칙이 먼저 사라지고 트래픽이 `tg-app` 으로 돌아간 뒤 ASG 가 내려간다. Terraform 이 의존 그래프로 그 순서를 잡는다.

**이벤트 종료 직후에 내리지 않는다.** 발급 기록 정산(`coupon.issued_quantity` 갱신)과 지표 수집이 끝난 뒤에 내린다. 인스턴스를 내리면 그 호스트의 지표가 Prometheus 에서 사라진다.

---

## 4. 배포와 겹치면 안 된다

`deploy.sh` 는 `$PROJECT-app` ASG 만 다룬다. **전용 ASG 는 배포 대상이 아니다.**

이벤트 중에 배포하면 두 가지가 어긋난다.

* `asg-app` 은 새 SHA 로 갈리는데 `asg-coupon` 은 옛 SHA 로 남는다
* 혼재 구간이 측정을 오염시킨다 (`시스템 디자인 종합` 7.3절이 부하 시험에 대해 같은 것을 금지한다)

**이벤트 구간에는 배포하지 않는다.** 이벤트 전에 배포를 끝내고, 전용 ASG 는 그 뒤에 올린다. 그러면 두 ASG 가 같은 SHA 를 본다. `current-sha` 를 SSM 에서 읽기 때문에 자동으로 맞는다.

이벤트 중 긴급 배포가 필요하면 **먼저 이벤트를 내린다.**

---

## 5. 커넥션 예산

DB 는 한 대다. 전용 인스턴스를 늘려도 그 앞에서 막힌다.

```
db.t4g.micro 의 max_connections 약 60 (예측. OPS-1-11 로 실측)
평상시 사용                     약 33
```

전용 인스턴스가 앱과 같은 풀(10)을 쓰면 이렇게 된다.

| 전용 | 추가 | 합계 |
|---|---|---|
| 2대 | 20 | 53 |
| 3대 | 30 | **63 초과** |

**그래서 전용 프로파일이 필요하다.** `application-coupon.yml` 이 풀을 4~5 로 줄인다. 선착순 발급은 `insert` 한 번이라 긴 트랜잭션이 없어 작은 풀로도 처리량이 나오는지 부하 시험에서 본다.

풀을 줄이지 않으려면 DB 클래스를 올려야 한다. `max_connections` 가 클래스 메모리에 비례하므로 한 단계 올리면 두 배가 된다. 비용이 는다.

---

## 6. 캐시 복제본

이벤트 구간에는 캐시가 순번의 판정 주체라 **죽으면 이벤트가 멈춘다.** 평상시 단일 노드 전제(`INF-04`)는 캐시가 Degradable 이라는 근거 위에 서 있는데 이 구간에는 그 전제가 성립하지 않는다.

```hcl
num_cache_clusters         = var.coupon_event_enabled ? 2 : 1
automatic_failover_enabled = var.coupon_event_enabled
multi_az_enabled           = var.coupon_event_enabled
```

**복제본 추가와 제거는 무중단이다.** primary 는 계속 동작한다. 다만 수 분 걸리므로 이벤트 직전에 하지 말고 여유를 둔다.

복제가 비동기라 페일오버 시 카운터가 몇 건 뒤로 밀릴 수 있다. **밀려도 초과 발급은 나지 않는다.** `member_coupon` 의 제약 두 개가 막는다. 그 처리는 앱 설계의 몫이다.

---

## 7. 관측

전용 ASG 도 기존 스크랩 잡에 자동으로 걸린다. `prometheus.yml` 의 `node` 와 `cadvisor` 잡이 `instance-state-name=running` 만 보므로 새 인스턴스가 뜨면 바로 대상이 된다.

`app` 잡은 `tag:Role` 로 거른다. **전용 인스턴스에 `Role=app` 태그를 붙여야** actuator 지표가 걷힌다. 태그를 `coupon` 으로 따로 주면 `prometheus.yml` 에 잡을 추가해야 한다.

**태그를 `app` 으로 준다.** 잡을 늘리지 않고, 대신 `instance` 라벨로 구분한다. 그래야 기존 알람(`HikariPendingHigh` 등)이 전용 인스턴스에도 그대로 적용된다.

---

## 8. 아직 안 정한 것

| | |
|---|---|
| 발급 경로의 정확한 path pattern | 앱 API 설계가 확정되면 채운다 |
| `coupon_desired` 기본값 | 부하 시험으로 정한다. 5장의 상한이 3대 미만이다 |
| 전용 프로파일의 풀 크기 | 같은 시험에서 정한다 |
| 이벤트 중 스케일 정책 | 지금은 고정 desired 다. 오토스케일링은 상한이 낮아 도입할 자리가 없다 |
