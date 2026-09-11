#!/usr/bin/env bash
# register.sh — EKS 를 허브(집 k3s 의 ArgoCD)에 등록한다.
#
# 허브가 EKS API 를 부르려면 셋이 필요하다 — 주소 · 그 주소의 CA · EKS 안의 자격(토큰).
# 셋을 허브의 argocd 네임스페이스에 클러스터 Secret 한 장으로 넣으면 등록이 끝난다.
#
# 등록만으로는 아무것도 배포되지 않는다. AppProject 가 이 클러스터를 허용하고
# Application 이 이 클러스터를 가리켜야 배포가 시작된다.
#
# 전제
#   kubeconfig 에 컨텍스트 둘
#     EKS    aws eks update-kubeconfig --region ap-northeast-2 --name cgv-stg --alias cgv-stg
#     허브    집 k3s.  kubeconfig 에서의 이름을 HUB_CONTEXT 로 준다
#   EKS 쪽 자격은 클러스터를 만든 IAM 주체(terraform apply 를 친 자격)다
#
# 실행      HUB_CONTEXT=<허브 컨텍스트> ./register.sh
# 다시 돌려도 된다 — 전부 apply 다. 클러스터를 다시 만든 날은 주소와 토큰이 바뀌므로 다시 돌린다.
set -euo pipefail
cd "$(dirname "$0")"

EKS_CONTEXT="${EKS_CONTEXT:-cgv-stg}"
HUB_CONTEXT="${HUB_CONTEXT:?허브(집 k3s) 컨텍스트 이름을 HUB_CONTEXT 로 준다. kubectl config get-contexts 로 확인}"
CLUSTER_NAME="${CLUSTER_NAME:-cgv-stg}"

eks() { kubectl --context "$EKS_CONTEXT" "$@"; }
hub() { kubectl --context "$HUB_CONTEXT" "$@"; }

# ---------- 선행 검사 ----------
# 두 컨텍스트를 뒤바꿔 주면 EKS 에 만들 것이 허브에 생긴다. 주소로 각자를 확인한다.
command -v kubectl >/dev/null || { echo "kubectl 없음." >&2; exit 1; }

EKS_SERVER=$(kubectl config view --context "$EKS_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
case "$EKS_SERVER" in
  https://*.eks.amazonaws.com) ;;
  *)
    echo "컨텍스트 ${EKS_CONTEXT} 가 EKS 가 아니다(server: ${EKS_SERVER:-없음})." >&2
    echo "  aws eks update-kubeconfig --region ap-northeast-2 --name ${CLUSTER_NAME} --alias ${EKS_CONTEXT}" >&2
    exit 1 ;;
esac

# EKS API 는 apply 시점의 집 공인 IP 에만 열려 있다(public_access_cidrs).
#   DDNS 라 그 뒤에 IP 가 바뀌면 여기서도 허브에서도 못 붙는다 → terraform apply 를 다시 치면 갱신된다.
eks auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || {
  echo "${EKS_CONTEXT} 에 닿지 않거나 클러스터 관리 권한이 없다." >&2
  echo "  자격 확인: aws sts get-caller-identity  (terraform apply 를 친 주체여야 한다)" >&2
  echo "  닿는지 확인: kubectl --context ${EKS_CONTEXT} get nodes  (시간 초과면 집 공인 IP 가 바뀐 것)" >&2
  exit 1; }

hub -n argocd get deploy/argocd-server >/dev/null 2>&1 || {
  echo "컨텍스트 ${HUB_CONTEXT} 에 argocd 가 없다. 허브 컨텍스트가 맞는지 확인해라." >&2; exit 1; }

# ---------- 1. EKS 쪽 — 허브가 쓸 신원 ----------
echo "[1/3] EKS 에 argocd-manager (ServiceAccount · cluster-admin 바인딩 · 토큰 Secret)"
# 대체 명령: kubectl --context cgv-stg apply -f argocd-manager.yaml
eks apply -f argocd-manager.yaml

# 토큰 컨트롤러가 Secret 에 token · ca.crt 를 채울 때까지 기다린다.
TOKEN_B64=""
for i in $(seq 1 30); do
  TOKEN_B64=$(eks -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null || true)
  [ -n "$TOKEN_B64" ] && break
  [ "$i" = 30 ] && {
    echo "토큰이 60초 안에 채워지지 않았다." >&2
    echo "  kubectl --context ${EKS_CONTEXT} -n kube-system describe secret argocd-manager-token" >&2
    exit 1; }
  sleep 2
done
TOKEN=$(printf '%s' "$TOKEN_B64" | base64 -d)
CA_B64=$(eks -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')

# ---------- 2. 허브에 넣기 전에 그 토큰으로 직접 불러 본다 ----------
# 허브는 등록된 클러스터를 Application 이 가리키기 전까지 연결을 시험하지 않는다(상태 Unknown).
#   틀린 토큰을 넣어도 첫 sync 에서야 드러나므로, 같은 주소 · CA · 토큰으로 여기서 먼저 부른다.
#   이 자리와 허브가 같은 집 공인 IP 로 나간다는 전제에서, 여기서 닿으면 허브에서도 닿는다.
echo "[2/3] argocd-manager 토큰으로 EKS API 를 불러 본다"
# 토큰을 명령 인자로 넘기지 않으려고 임시 kubeconfig 에 쓰고 끝나면 지운다.
TMP_KUBECONFIG=$(mktemp)
trap 'rm -f "$TMP_KUBECONFIG"' EXIT
cat > "$TMP_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: eks
    cluster:
      server: ${EKS_SERVER}
      certificate-authority-data: ${CA_B64}
users:
  - name: argocd-manager
    user:
      token: ${TOKEN}
contexts:
  - name: check
    context:
      cluster: eks
      user: argocd-manager
current-context: check
EOF
# Git Bash 에서는 kubectl.exe 에 Windows 경로로 넘긴다(MSYS 경로 변환에 기대지 않는다).
KCFG="$TMP_KUBECONFIG"
command -v cygpath >/dev/null && KCFG=$(cygpath -w "$TMP_KUBECONFIG")
kubectl --kubeconfig "$KCFG" auth can-i '*' '*' --all-namespaces >/dev/null || {
  echo "argocd-manager 토큰으로 EKS 를 부르지 못했다. 허브에 넣지 않고 멈춘다." >&2; exit 1; }

# ---------- 3. 허브 쪽 — 클러스터 Secret ----------
echo "[3/3] 허브 argocd 네임스페이스에 클러스터 Secret cluster-${CLUSTER_NAME}"
# 라벨 argocd.argoproj.io/secret-type=cluster 가 있어야 ArgoCD 가 클러스터 정의로 읽는다.
# name 과 server 를 둘 다 넣는다 — Application 의 destination 은 둘 중 어느 쪽으로도 이 클러스터를 부를 수 있다.
# 대체 명령(argocd CLI 로 허브에 로그인한 상태에서):
#   argocd cluster add cgv-stg --name cgv-stg
#   EKS 에 자기 몫의 argocd-manager 와 ClusterRole 을 만들고 같은 모양의 Secret 을 허브에 쓴다
hub apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${CLUSTER_NAME}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${CLUSTER_NAME}
  server: ${EKS_SERVER}
  config: |
    {"bearerToken": "${TOKEN}", "tlsClientConfig": {"insecure": false, "caData": "${CA_B64}"}}
EOF

echo
echo "등록했다. 허브는 이 클러스터를 가리키는 Application 이 생길 때 처음 연결한다."
echo "  확인: kubectl --context ${HUB_CONTEXT} -n argocd get secret -l argocd.argoproj.io/secret-type=cluster"
echo "  지울 때: kubectl --context ${HUB_CONTEXT} -n argocd delete secret cluster-${CLUSTER_NAME}  (순서는 README 「지울 때」)"
