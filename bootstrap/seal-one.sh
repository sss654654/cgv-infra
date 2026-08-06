#!/usr/bin/env bash
# SealedSecret 낱개 봉인 — seal-secrets.sh(초기 10종 일괄)와 달리 뒤에 하나씩 더할 때 쓴다.
# 값은 프롬프트로 받고(-s: 화면·히스토리에 안 남음), 원문 Secret은 파일로 만들지 않고
# 표준입력으로 kubeseal에 흘린다. 결과 암호문만 workloads/manifests/secrets/에 남는다.
#
#   ./seal-one.sh [-a 애노테이션 key=value]... <이름> <네임스페이스> [라벨 key=value ...]
#
# 예) ArgoCD가 GitLab 저장소를 읽을 자격:
#   ./seal-one.sh argocd-repo-cgv-infra argocd argocd.argoproj.io/secret-type=repository
#     type=git / url=<repoURL과 글자까지 같게> / username=<deploy token 사용자명> / password=<토큰>
#
# 예) 남이 만든 Secret에 키 하나만 얹기 — argocd-secret에 webhook 검증용 비밀:
#   ./seal-one.sh -a sealedsecrets.bitnami.com/patch=true argocd-secret argocd
#     patch가 없으면 통째 대체라 argocd-server가 런타임에 써넣은
#     admin.password·server.secretkey가 사라진다.
#
#     ⚠️ 컨트롤러는 이 애노테이션을 봉인본이 아니라 클러스터에 이미 있는 Secret에서 읽는다.
#        봉인본에만 적으면 "already exists and is not managed by SealedSecret"으로 거부하므로,
#        대상 Secret이 이미 있는 경우에는 처음 한 번만 손으로 붙여야 한다:
#          kubectl -n argocd annotate secret argocd-secret sealedsecrets.bitnami.com/patch=true
#        한 번 통과하면 이후로는 봉인본의 애노테이션이 Secret에 남아 계속 통과한다.
set -euo pipefail
cd "$(dirname "$0")"
OUT="../workloads/manifests/secrets"

USAGE="사용법: $0 [-a 애노테이션 key=value]... <이름> <네임스페이스> [라벨 key=value ...]"
ANNOTATIONS=()
while getopts ":a:" opt; do
  case "$opt" in
    a) ANNOTATIONS+=("$OPTARG") ;;
    *) echo "$USAGE" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
NAME=${1:?$USAGE}
NS=${2:?$USAGE}
shift 2
LABELS=("$@")

# getopts는 위치 인자를 만나면 멈춘다. 그래서 이름·네임스페이스 뒤에 쓴 -a는 옵션이 아니라
#   라벨로 흘러 들어가고, 값을 다 입력한 뒤에야 kubectl label이 거부하며 죽는다.
#   애노테이션이 빠진 채 봉인되는 것이 더 나쁘므로 여기서 먼저 막는다.
for l in ${LABELS[@]+"${LABELS[@]}"}; do
  case "$l" in
    -*) echo "옵션은 이름 앞에 와야 한다: $l" >&2; echo "$USAGE" >&2; exit 1 ;;
  esac
done

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

# 라벨·애노테이션은 --local 이라 클러스터를 보지 않고 표준입력의 YAML만 고친다.
# 인자를 안 주면 그대로 흘려보내므로 기존 호출(라벨만·둘 다 없음)의 결과는 바뀌지 않는다.
render()      { kubectl create secret generic "$NAME" -n "$NS" "${ARGS[@]}" --dry-run=client -o yaml; }
put_labels()  { if [ ${#LABELS[@]}      -gt 0 ]; then kubectl label    --local -f - "${LABELS[@]}"      --dry-run=client -o yaml; else cat; fi; }
put_annos()   { if [ ${#ANNOTATIONS[@]} -gt 0 ]; then kubectl annotate --local -f - "${ANNOTATIONS[@]}" --dry-run=client -o yaml; else cat; fi; }

# 결과 파일로 바로 리다이렉트하면 파이프라인이 돌기 전에 파일이 생긴다.
#   중간에 실패해도 0바이트 파일이 남고, 위의 중복 검사에 걸려 재시도가 막힌다.
#   임시 파일에 쓰고 성공했을 때만 옮긴다.
TMP="$(mktemp)"; trap 'rm -f "$CERT" "$TMP"' EXIT
render | put_labels | put_annos \
  | kubeseal --format yaml --cert "$CERT" \
      --controller-name sealed-secrets --controller-namespace kube-system \
  > "$TMP"
mv "$TMP" "$OUT/$NAME.yaml"

echo "  ok $NAME ($NS) → $OUT/$NAME.yaml"
echo "다음: git add → commit → MR → main (ArgoCD는 git에서 읽는다. 머지 전엔 없는 것과 같다)"
