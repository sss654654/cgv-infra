#!/usr/bin/env bash
# root-app.sh — GitOps 인계. install.sh(부트스트랩)와 분리한 이유:
#   root-app을 apply하면 argocd가 mysql·redis·minio·grafana·LGTM을 곧바로 배포하는데,
#   이들은 전부 SealedSecret이 풀린 Secret을 요구한다. 봉인은 sealed-secrets 컨트롤러가 뜬 뒤에만 가능하므로
#   "install.sh(컨트롤러까지) → 봉인·커밋 → root-app.sh" 순서가 강제돼야 한다.
#   한 스크립트로 붙여두면 봉인 전에 폭포가 시작돼 전 스택이 시크릿 없이 실패한다.
set -euo pipefail
cd "$(dirname "$0")"

# kubeconfig 결정 — install.sh와 같은 규칙. 실행 위치를 노드로 한정하지 않는다.
#   노드에서: /etc/rancher/k3s/k3s.yaml · 그 밖에서: ~/.kube/config
if [ -z "${KUBECONFIG:-}" ]; then
  if   [ -r /etc/rancher/k3s/k3s.yaml ]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  elif [ -r "$HOME/.kube/config" ];      then export KUBECONFIG="$HOME/.kube/config"
  else echo "kubeconfig를 찾을 수 없다(/etc/rancher/k3s/k3s.yaml · ~/.kube/config)." >&2; exit 1; fi
fi

command -v kubectl >/dev/null || { echo "kubectl 없음." >&2; exit 1; }
kubectl -n argocd get deploy/argocd-server >/dev/null 2>&1 || {
  echo "argocd가 없다. install.sh를 먼저 완주해라." >&2; exit 1; }

# 봉인본 개수 검사 — 계약(docs/시크릿-계약.md)이 요구하는 10종이 커밋돼 있어야 한다.
# 파일이 부족한 채로 apply하면 argocd는 성공으로 보이는데 워크로드만 조용히 실패한다.
SECRET_DIR="../workloads/manifests/secrets"
COUNT=$(find "$SECRET_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l)
EXPECTED=10
if [ "$COUNT" -lt "$EXPECTED" ]; then
  echo "SealedSecret 봉인본이 ${COUNT}개다(필요 ${EXPECTED}종). ${SECRET_DIR}/ 확인." >&2
  echo "계약: docs/시크릿-계약.md · 봉인법: workloads/manifests/secrets/README.md" >&2
  echo "봉인을 건너뛰고 진행하려면: SKIP_SECRET_CHECK=1 ./root-app.sh" >&2
  [ "${SKIP_SECRET_CHECK:-0}" = "1" ] || exit 1
  echo "SKIP_SECRET_CHECK=1 — 검사를 건너뛴다. 시크릿 소비 워크로드는 실패한다." >&2
fi

# 봉인본이 git에 push돼 있어야 argocd가 본다(로컬 파일이 아니라 repoURL을 읽는다).
if git -C .. rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C .. status --porcelain "$SECRET_DIR" 2>/dev/null)" ]; then
    echo "경고: ${SECRET_DIR}에 커밋되지 않은 변경이 있다. argocd는 원격 repo를 읽으므로 push까지 해야 반영된다." >&2
  fi
fi

echo "root-app apply → argocd/ 하위(AppProject·ApplicationSet·Application)를 argocd가 인계한다."
kubectl apply -f root-app.yaml

echo
echo "진행 확인: kubectl -n argocd get applications -w"
echo "초기에는 의존 순서가 강제되지 않아 일부 App이 red로 보이다가 selfHeal로 수렴한다."
echo "argocd UI 접근(traefik 뜨기 전): kubectl -n argocd port-forward svc/argocd-server 8080:443"
