# envs/ — 환경별 값 (폴더-per-env, 브랜치 아님)

환경을 **폴더**로 둔다. 전부 `main` 한 브랜치에 있고, Application의 `valueFiles`가 이 폴더를 가리킨다.

| env | 대상 클러스터 | 상태 |
|---|---|---|
| `dev/` | 온프레미스 k3s | **활성**. `apps` ApplicationSet과 `mysql`·`redis` Application이 이 폴더를 읽는다 |
| `stg/` | 미정 | 값 골격만. 배포 배선 없음 |

`prd/`는 두지 않는다. 대상 클러스터가 생기는 시점에 신설한다 —
아무도 참조하지 않는 폴더를 미리 만들면 "있는데 안 도는 것"이 하나 늘 뿐이다.

## 이 폴더에 무엇을 적나

**환경마다 달라야 하는 값만.** resources · replica · 정원 · 커넥션 풀 · 이미지 태그.

포트·프로브·uid처럼 환경이 바뀌어도 안 변하는 값은 서비스 값(`charts/apps/<서비스>/values.yaml`)에 둔다.
여기 두면 환경이 늘 때마다 복제되고, 한쪽만 고치는 날이 온다.

판단 기준은 [`docs/구조-기준.md`](../docs/구조-기준.md) §2.

## 왜 브랜치가 아니라 폴더인가

브랜치-per-env는 승격이 merge라 충돌과 drift가 생긴다(ArgoCD·Codefresh가 안티패턴으로 든다).
폴더면 **승격 = 이미지 태그 커밋(MR)** 이라 이력이 한 줄로 남고 되돌리기가 쉽다.

협업 브랜치는 이것과 별개다. `feature → MR → main`은 "변경을 저장소에 넣는 법"이고,
환경 구조(폴더)와 직교로 공존한다.

## 파일 이름

`<서비스>.yaml`. 폴더가 이미 환경을 말하므로 접두어를 붙이지 않는다.
같은 이름이 층을 관통한다 — `charts/apps/queue/values.yaml` · `envs/dev/queue.yaml`.

## 아직 없는 것

**stg를 배포할 배선이 없다.** `argocd/applicationsets/apps.yaml`이 `envs/dev`를 하드코딩하고 있고,
`mysql`·`redis` Application도 각각 `envs/dev`를 직접 문다.

환경을 하나 더 활성화하려면 파일 한 줄을 바꾸는 것이 아니라
env별 ApplicationSet을 더하거나 (서비스 × 환경) matrix 제너레이터로 바꿔야 한다.
`stg/`에 `mysql.yaml`·`redis.yaml`이 없는 것도 그 배선이 없기 때문이다.
