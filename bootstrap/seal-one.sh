#!/usr/bin/env bash
# SealedSecret 낱개 봉인 — seal-secrets.sh(초기 10종 일괄)와 달리 뒤에 하나씩 더할 때 쓴다.
# 값은 프롬프트로 받고(-s: 화면·히스토리에 안 남음), 원문 Secret은 파일로 만들지 않고
# 표준입력으로 kubeseal에 흘린다. 결과 암호문만 workloads/manifests/secrets/에 남는다.
#
#   ./seal-one.sh <이름> <네임스페이스> [라벨 key=value ...]
#
# 예) ArgoCD가 GitLab 저장소를 읽을 자격:
#   ./seal-one.sh argocd-repo-cgv-infra argocd argocd.argoproj.io/secret-type=repository
#     type=git / url=<repoURL과 글자까지 같게> / username=<deploy token 사용자명> / password=<토큰>
set -euo pipefail
cd "$(dirname "$0")"
OUT="../workloads/manifests/secrets"

USAGE="사용법: $0 <이름> <네임스페이스> [라벨 key=value ...]"
NAME=${1:?$USAGE}
NS=${2:?$USAGE}
shift 2
LABELS=("$@")

command -v kubeseal >/dev/null || { echo "kubeseal 없음" >&2; exit 1; }
[ -d "$OUT" ] || { echo "$OUT 폴더 없음" >&2; exit 1; }
[ -e "$OUT/$NAME.yaml" ] && { echo "$OUT/$NAME.yaml 이미 있다 — 덮으려면 지우고 다시" >&2; exit 1; }

# 공개키는 컨트롤러에서 한 번만 받아 재사용(seal-secrets.sh와 같은 방식).
# 컨트롤러 이름이 차트 기본값(sealed-secrets-controller)과 달라 매번 지정해야 한다.
CERT="$(mktemp)"; trap 'rm -f "$CERT"' EXIT
kubeseal --fetch-cert --controller-name sealed-secrets --controller-namespace kube-system > "$CERT" \
  || { echo "공개키 fetch 실패 — 컨트롤러가 떠 있나?" >&2; exit 1; }

echo "== 키·값 입력 (키를 비우고 엔터면 끝) =="
ARGS=()
while :; do
  read -rp "  키: " k
  [ -z "$k" ] && break
  read -rsp "  값: " v; echo >&2
  echo "    (${#v}자 입력됨)" >&2
  ARGS+=(--from-literal="$k=$v")
done
[ ${#ARGS[@]} -gt 0 ] || { echo "입력된 값이 없다" >&2; exit 1; }

render() { kubectl create secret generic "$NAME" -n "$NS" "${ARGS[@]}" --dry-run=client -o yaml; }

if [ ${#LABELS[@]} -gt 0 ]; then
  render | kubectl label --local -f - "${LABELS[@]}" --dry-run=client -o yaml
else
  render
fi | kubeseal --format yaml --cert "$CERT" \
       --controller-name sealed-secrets --controller-namespace kube-system \
     > "$OUT/$NAME.yaml"

echo "  ok $NAME ($NS) → $OUT/$NAME.yaml"
echo "다음: git add → commit → MR → main (ArgoCD는 git에서 읽는다. 머지 전엔 없는 것과 같다)"
