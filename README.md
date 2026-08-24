# infra

fresh-market 백엔드의 인프라다. Terraform 으로 AWS 를 만들고, `main` 병합을 트리거로 배포한다.

## 어디부터 읽나

| 하려는 것 | 볼 곳 |
|---|---|
| 처음 올린다 | `./scripts/apply.sh`. 근거는 [`docs/deploy/README.md`](docs/deploy/README.md) |
| 껐다 켠다, 지운다 | 같은 문서의 "세션 단위로", "전부 지운다" |
| 배포가 어떻게 도는지 | 같은 문서 |
| 선착순 이벤트를 연다 | [`docs/deploy/coupon-event.md`](docs/deploy/coupon-event.md) |
| 왜 이렇게 정했는지 | [`docs/system-design/`](docs/system-design/) |
| 코드가 결정과 맞는지 본다 | [`docs/infra-review/`](docs/infra-review/) |

## 구성

```
terraform/       AWS 리소스. 단일 환경이라 모듈로 쪼개지 않는다
bootstrap/       파괴를 견디는 계층. 상태 버킷과 시크릿 8개. 로컬 상태로 관리한다
observability/   모니터링 인스턴스에서 도는 것들. Terraform 이 아니라 git clone 으로 배포한다
scripts/         런타임을 다루는 것들. Terraform 이 건드리면 안 되는 영역이다
docs/            설계 근거와 판정 기준
verify.sh        G-LOCAL 진입점. 본체는 common 저장소에 있다
```

**`bootstrap/` 이 따로인 이유**는 둘이다. 상태 버킷은 자기 자신을 상태에 담을 수 없어 닭과 달걀이고, 시크릿은 `destroy.sh` 를 견뎌야 한다. SSM 표준 파라미터는 무료라 지워도 아끼는 것이 없는데 지우면 재구축 때 전부를 손으로 다시 넣어야 한다. `./scripts/apply.sh` 가 두 구성의 순서를 흡수한다.

**`observability/` 를 Terraform 이 갖지 않는 이유**는 알람 임계값을 고칠 때마다 `apply` 를 하지 않기 위해서다(`INF-32`, `OPS-2-18`). 모니터링 인스턴스가 이 저장소를 클론하고, 설정을 고치면 거기서 `git pull` 한다.

## Terraform 과 스크립트의 경계

이 경계가 깨지면 배포가 깨진다.

| 대상 | 누가 |
|---|---|
| ASG, 시작 템플릿, 대상 그룹, 리스너, SSM 파라미터 **리소스** | Terraform |
| SSM 파라미터의 **값**, desired capacity, 대상 등록과 해제 | 스크립트 |

Terraform 쪽에 `ignore_changes` 를 걸어 두었다. 자세한 것은 [`docs/deploy/README.md`](docs/deploy/README.md).

## 스크립트

| | 언제 |
|---|---|
| `apply.sh` | 인프라를 올린다. bootstrap 순서, 시크릿 검사, 엔드포인트 반영을 흡수한다 |
| `deploy.sh` | `main` 병합 시 워크플로가 부른다. 인자 없이 직접 돌리면 `main` 최신을 배포한다 |
| `rollback.sh` | 이전 SHA 로 배포를 다시 한다 |
| `preflight.sh` | 배포 직전 차단 게이트(G-RELEASE) |
| `stop.sh` / `start.sh` | 세션 단위로 껐다 켠다. 절반 정도 줄어든다 |
| `destroy.sh` | 전부 지운다. 오래 안 쓸 때 |

## 계정을 잘못 보고 실행하는 것을 막는다

`terraform/versions.tf` 가 `allowed_account_ids` 와 `profile` 을 함께 건다. 다른 계정 자격증명으로 돌리면 plan 단계에서 멈춘다.

```
Error: AWS account ID not allowed: <다른 계정>
```

`destroy.sh` 는 한 겹 더 두어, 대상 계정 ID 를 사람이 직접 입력해야 진행한다.

## 검증

```bash
cd terraform && terraform fmt -check -recursive && terraform validate
./verify.sh                  # G-LOCAL. 아직 push 하지 않은 커밋 전부
```

판정 항목은 `.github/llm-verify/items.yml` 이 갖는다. `docs/infra-review/*-guideline.md` 를 고치면 **재생성해야 한다.** 안 하면 `registry-check` 가 PR 을 막는다.
