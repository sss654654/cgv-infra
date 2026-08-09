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

# 봉인본 개수 검사 — 계약(docs/시크릿-계약.md)이 요구하는 13종이 커밋돼 있어야 한다.
#   초기 10종(seal-secrets.sh 일괄) + 나중에 낱개로 더한 셋:
#   argocd-repo-cgv-infra(ArgoCD가 저장소를 읽는 자격),
#   argocd-secret(webhook 발신자 확인 키를 기존 Secret에 얹는다),
#   gitlab-registry(노드가 이미지를 받아오는 자격. dockerconfigjson이라 seal-one.sh가 아니라
#                   kubectl create secret docker-registry로 만든다).
# 파일이 부족한 채로 apply하면 argocd는 성공으로 보이는데 워크로드만 조용히 실패한다.
#
# ⚠️ argocd-repo-cgv-infra는 이 스크립트 전에 손으로 apply해야 한다. 그 Secret이 없으면
#    ArgoCD가 저장소를 못 읽어 sealed-secrets App을 sync할 수 없고, 그 App이 배달하는 것이
#    바로 그 Secret이라 순환에 걸린다(docs/시크릿-계약.md 조건부 항목).
SECRET_DIR="../workloads/manifests/secrets"
COUNT=$(find "$SECRET_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l)
EXPECTED=14
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

# root Application이 참조하는 AppProject를 먼저 세운다.
#   root-app.yaml은 project: bootstrap을 참조하는데, 그 AppProject를 만드는 매니페스트가
#   root가 관리하는 argocd/ 트리 안에 있다(argocd/projects/bootstrap.yaml).
#   ArgoCD는 참조한 AppProject가 없으면 Application을 sync하지 않고 멈추므로,
#   빈 클러스터에서는 root가 자기 프로젝트를 스스로 만들지 못해 그 자리에서 정지한다.
#   저장소 자격(argocd-repo-cgv-infra)과 같은 유형의 순환이라 같은 방식으로 푼다 —
#   한 번만 손으로 세우고, 그 뒤로는 GitOps가 같은 것을 관리한다.
echo "AppProject bootstrap 선행 apply (root가 참조하는 프로젝트)."
kubectl apply -f ../argocd/projects/bootstrap.yaml

echo "root-app apply → argocd/ 하위(AppProject·ApplicationSet·Application)를 argocd가 인계한다."
kubectl apply -f root-app.yaml

echo
echo "진행 확인: kubectl -n argocd get applications -w"
echo "초기에는 의존 순서가 강제되지 않아 일부 App이 red로 보이다가 selfHeal로 수렴한다."
echo "argocd UI 접근(traefik 뜨기 전): kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "traefik이 뜬 뒤: http://argocd.cgv.lan — 접근하는 기기의 hosts나 DNS가 traefik 주소로 풀어줘야 한다."
