# 선착순 쿠폰 부하 시험

요구사항이 정한 것은 셋이다 (`backend/docs/coupon/requirement.md`).

```
재고 10,000장에 20,000명이 동시에 요청해도 초과 발급 0건, 1인 최대 1매
ramp-up 60s
도구와 처리량은 평가하지 않는다
```

**마지막 줄이 이 시험의 성격을 정한다.** 재는 것은 성능이 아니라 정확성이다.
p99 와 처리량은 기록하되 합격 판정에 쓰지 않는다.

## 부하의 모양

1인 1매라 사용자 한 명이 요청 하나를 보낸다. 총 요청이 2만 건이다.

0 에서 선형으로 60초 올리면 면적이 사용자 수가 되도록 최고 도착률을 정한다.

```
0.5 * 60 * peak = 20,000   ->   peak = 667 RPS   (평균 333)
```

JMeter 의 "스레드 2만 개를 60초에 걸쳐 시작" 과 같은 모양이다.

재고 1만 장은 램프 중간쯤에서 소진된다. 앞 절반이 200 을 받고 뒤 절반이 409 를 받는다.

## 준비

**토큰 2만 개가 필요하다.** 1인 1매를 Redis 가 판정하므로 VU 마다 다른 회원의 JWT 여야 한다.
같은 토큰이 두 번 쓰이면 두 번째는 `alreadyIssued` 가 되어 발급이 아니라 재요청을 측정하게 된다.

```json
["eyJhbGciOi...", "eyJhbGciOi...", ...]
```

`tokens.json` 에 문자열 배열로 둔다. **커밋하지 않는다.** 서명된 JWT 라 사실상 자격증명이다.
생성은 앱의 서명 키가 필요하므로 백엔드 쪽 스크립트가 맡는다.

메모리 측정용 더미는 스크립트로 만든다. 2만 개면 5 MB 라 저장소에 두지 않는다.

```bash
node gen-dummy-tokens.js 20000 > tokens.json
```

실제 요청에는 쓸 수 없다. 서명이 없어 앱이 거절한다.

## 실행

```bash
# 요구사항 그대로
docker run --rm --network host --ulimit nofile=250000:250000 \
  -v "$PWD:/s" -w /s \
  -e BASE_URL=http://<ALB DNS 이름> -e COUPON_ID=1 \
  grafana/k6:1.7.1 run coupon-issue.js
```

| 환경변수 | 기본 | |
|---|---|---|
| `BASE_URL` | `http://localhost:8080` | ALB DNS 이름 |
| `COUPON_ID` | `1` | 대상 쿠폰 |
| `RAMP_SECONDS` | `60` | 요구사항 값 |
| `USERS` | `20000` | 요구사항 값. 토큰 수와 같아야 한다 |
| `BROWSE_RPS` | `0` | 격벽 검증용 배경 부하. 끈 상태가 기본이다 |
| `MAX_VUS` | `2000` | 부족하면 `dropped_iterations` 가 뜬다 |

## 합격 판정

```
coupon_issued          <= 10000    초과 발급 0건
coupon_already_issued  == 0        토큰이 고유하므로 한 건도 없어야 한다
coupon_soldout         > 0         소진이 실제로 일어났는가
coupon_unexpected      == 0
coupon_token_exhausted == 0        토큰이 모자라지 않았는가
```

`coupon_already_issued` 가 0 이 아니면 재요청이 아니라 **토큰 배분이 깨진 것**이다.

**`dropped_iterations` 를 반드시 본다.** 0 이 아니면 생성기가 못 따라간 것이라
그 결과를 서버 성능으로 읽으면 안 된다. `MAX_VUS` 를 올리거나 인스턴스를 키운다.

**최종 검증은 DB 에서 한다.** k6 는 자기가 보낸 요청만 센다.
`member_coupon` 수와 `total_quantity` 를 대조하는 것은 앱의 정합성 검증 수단이 맡는다.

## 격벽 검증 (기본 꺼짐)

**첫 시험에서는 끈다.** 질문이 "초과 발급 0건인가" 하나이므로 변수를 하나만 둔다.
상품 조회가 함께 돌면 실패했을 때 어느 쪽 문제인지 가리는 데 시간이 든다.

그것이 통과한 뒤에 켜서 따로 본다.

```bash
BROWSE_RPS=20 ... run coupon-issue.js
```

`browse_baseline` 시나리오가 선착순이 도는 동안 `GET /v1/products` 를 낮은 도착률로 계속 친다.
**선착순이 몰리는 동안 상품 조회가 멀쩡해야** 전용 ASG 를 나눈 값을 한 것이다 (`coupon.md` 8장).

`browse_latency` 가 램프 구간에 무너지면 격벽이 새는 것이다.
이 검증에는 `GET /v1/products` 가 응답할 만큼의 상품 데이터가 적재되어 있어야 한다.

## 인스턴스 사이징

VU 당 메모리를 실측했다 (2026-08-28, 더미 토큰 2만 개, k6 1.7.1).

```
VU 1     49.5 MiB      기준선. SharedArray 토큰 5 MB 포함
VU 100   72.7 MiB
VU 500  218.7 MiB      한계 비용 0.365 MiB/VU
```

k6 문서가 드는 VU 당 1~5 MB 보다 훨씬 낮다. 스크립트가 POST 하나뿐이고
토큰을 `SharedArray` 로 공유하기 때문이다.

| 응답시간 | 필요 VU | 필요 메모리 |
|---|---|---|
| 200ms | 133 | 0.10 GB |
| 1초 | 667 | 0.29 GB |
| 3초 | 2,001 | 0.76 GB |
| 10초 (최악) | 6,670 | **2.43 GB** |

최악에도 2.5 GB 다. **`m7i.large`(2 vCPU / 8 GB)로 3배 여유가 있다.**

버스터블을 쓰지 않는 것은 크레딧 때문이 아니라 **측정 안정성** 때문이다.
`standard` 모드였다면 회차마다 크레딧 상태가 달라 같은 코드가 다른 숫자를 낸다.

**CPU 는 실측하지 못했다.** 측정을 로컬 더미 서버로 해서 k6 가 거의 놀았다.
667 RPS 를 2 vCPU 로 만들 수 있는지는 첫 실행에서 `dropped_iterations` 로 확인한다.
0 이 아니면 `m7i.xlarge` 로 올린다.

## 설정을 확인할 때

`k6 inspect` 는 시스템 환경변수를 읽지 않는다. `__ENV` 가 비어 있어 조건부 시나리오가
안 붙은 것처럼 보인다. 확인은 `k6 run` 으로 한다. 시작 직후 시나리오 목록을 찍는다.

```
scenarios: (100.00%) 2 scenarios, ...
         * browse_baseline: 20.00 iterations/s for 43s ...
         * coupon_issue: Up to 667.00 iterations/s for 60s over 1 stages ...
```

## 메모리 재측정

스크립트를 고쳤을 때 다시 잰다. 서버가 없어도 된다.

```bash
MEASURE=1 MEASURE_VUS=500 docker run --rm -v "$PWD:/s" -w /s \
  -e MEASURE=1 -e MEASURE_VUS=500 grafana/k6:1.7.1 run coupon-issue.js
```

도착률 실행기로는 VU 수를 고정할 수 없어 `constant-vus` 로 바뀐다.
