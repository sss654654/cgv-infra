# envs/ — 환경별 값 (폴더-per-env, 브랜치 아님)

환경을 **폴더**로 둔다. 전부 `main` 한 브랜치에 있고, Application의 `valueFiles`가 이 폴더를 가리킨다.

| env | 대상 클러스터 | 상태 |
|---|---|---|
| `dev/` | 온프레미스 k3s | **활성**. `apps`·`data` ApplicationSet의 환경 목록에 있고, `mysql` Application이 직접 읽는다 |
| `stg/` | 미정 | 값 골격만. 환경 목록에 없어 배포되지 않는다 |

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

## 환경을 하나 더 켜려면

`apps` · `data` · `manifests` · `platform` ApplicationSet은 (대상 × 환경) matrix다.
**환경 목록에 한 줄을 더하면 그 환경의 Application이 전부 생긴다** — 파일을 새로 쓰지 않는다.

```yaml
# argocd/applicationsets/apps.yaml 의 환경 축
- { env: dev, server: "https://kubernetes.default.svc", registry: "192.168.0.167:5050" }
- { env: stg, server: "https://<새 클러스터>",           registry: "<새 레지스트리>" }   ← 이 한 줄
```

그 전에 `stg/`의 값 파일이 실물이어야 한다. 지금은 `image.tag: stg` 한 줄뿐인 골격이고,
`resources`가 없어 `charts/apps/cgv-app/values.schema.json`이 렌더 단계에서 거부한다 —
ImagePullBackOff까지 가지 않고 ArgoCD가 ComparisonError로 멈춘다. 그 실패가 안전망이다.

`mysql`은 환경 축이 없다. 다른 환경에서는 관리형 데이터베이스를 쓸 예정이라 이 차트를 안 올린다.
그래서 `stg/mysql.yaml`이 없는 것은 결함이 아니라 의도다.
