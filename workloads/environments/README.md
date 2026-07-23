# envs/ — 환경별 값 (폴더-per-env, 브랜치 아님)

3환경을 **폴더**로 둔다(브랜치 X). 전부 `main` 한 브랜치에 있고, ArgoCD가 폴더에서 각 env를 배포.

| env | 상태 | 설명 |
|---|---|---|
| `dev/` | **활성** | 실물 값. appset가 이걸 순회해 배포. |
| `stg/` | 골격(정의만) | 승격 중간. 배포 비활성. |
| `prd/` | 골격(정의만) | 승격 최종(수동 승인). 배포 비활성. |

## 왜 브랜치가 아니라 폴더인가
브랜치-per-env는 승격이 merge라 충돌·drift(Argo·Codefresh 안티패턴). 폴더면 **승격 = 이미지태그 bump 커밋(MR)** — 깨끗·감사 가능.

## 협업 브랜치는 별개
`feature → MR(리뷰) → main` 은 "변경을 repo에 넣는 법"(팀 협업). env 구조(폴더)와 직교로 공존.
**승격 흐름**: CI가 dev 태그 bump(자동) → 검증 → `envs/stg` 태그 MR → `envs/prd` 태그 MR(**수동 승인**).

## 활성화(나중, GitLab 붙일 때)
지금 `argocd/applicationsets/apps.yaml`이 `environments/dev`만 하드코딩. stg/prd 배포하려면 env별 appset 추가 또는 (app × env) matrix generator. dev만 굴리는 지금은 골격만 유지(과설계 방지).
