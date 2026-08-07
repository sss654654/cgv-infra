#!/usr/bin/env bash
# install.sh — 부트스트랩(set-once). argocd 밖 인프라를 순서대로 깐다.
# 전제: 각 노드에 k3s가 cluster/config.yaml로 설치·조인됨(CNI 전이라 NotReady 상태).
# 실행 위치는 kubectl·helm이 있고 클러스터에 닿는 곳이면 된다 — $KUBECONFIG를 쓰고, 없으면 k3s 기본 경로로 떨어진다.
# GitOps 인계(root-app apply)는 이 스크립트에 없다 — SealedSecret 봉인이 선행돼야 하므로 root-app.sh로 분리했다.
set -euo pipefail
cd "$(dirname "$0")"

# kubeconfig 결정. helm은 --kubeconfig / $KUBECONFIG / ~/.kube/config 만 보고
# k3s 기본 경로(/etc/rancher/k3s/k3s.yaml)는 스스로 찾지 않는다. 그래서 여기서 정해 넘긴다.
#
# 실행 위치를 노드로 한정하지 않는다 — kubectl·helm이 있고 클러스터에 닿으면 어디서든 된다.
#   노드에서: /etc/rancher/k3s/k3s.yaml (k3s가 만든 것. config.yaml의 write-kubeconfig-mode 0644로 읽힌다)
#   그 밖에서: ~/.kube/config (노드에서 복사해 server 주소를 노드 IP로 바꾼 것)
# 이미 $KUBECONFIG가 있으면 그대로 존중한다.
if [ -z "${KUBECONFIG:-}" ]; then
  if   [ -r /etc/rancher/k3s/k3s.yaml ]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  elif [ -r "$HOME/.kube/config" ];      then export KUBECONFIG="$HOME/.kube/config"
  else
    echo "kubeconfig를 찾을 수 없다. /etc/rancher/k3s/k3s.yaml 도 ~/.kube/config 도 없다." >&2
    echo "  노드에서 실행하거나, 노드의 kubeconfig를 복사해 KUBECONFIG로 지정해라." >&2
    exit 1
  fi
fi

# 선행 조건 검사 — 없는 채로 [1]부터 돌면 중간에 죽어서 부분 적용 상태가 남는다.
command -v kubectl >/dev/null || { echo "kubectl 없음. k3s가 설치된 노드에서 실행해야 한다." >&2; exit 1; }
command -v helm    >/dev/null || { echo "helm 없음. 설치 후 다시 실행:
  mkdir -p ~/.local/bin && curl -fsSL https://get.helm.sh/helm-v3.21.3-linux-amd64.tar.gz | tar xz -O linux-amd64/helm > ~/.local/bin/helm && chmod +x ~/.local/bin/helm
  (~/.local/bin이 PATH에 없으면: export PATH=\"\$HOME/.local/bin:\$PATH\")" >&2; exit 1; }
[ -r "$KUBECONFIG" ] || { echo "kubeconfig를 읽을 수 없다: $KUBECONFIG (config.yaml의 write-kubeconfig-mode 확인)" >&2; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { echo "클러스터에 접속할 수 없다. k3s 서비스 상태를 확인해라." >&2; exit 1; }

echo "[1/9] Calico (CNI) — 닭-달걀. CRD → tigera-operator → 우리 Installation CR (없으면 노드 NotReady)"
# 버전 v3.32.1 (2026-06-26 릴리스). 이전 핀 v3.29.0은 테스트 대상 k8s가 1.29-1.31이라
# 이 클러스터(k3s v1.36.2 = k8s 1.36)와 5마이너 어긋나 지원 매트릭스 밖이었다.
# v3.32는 테스트 대상에 1.34·1.35·1.36이 명시돼 있어 1.36에 맞는 최신 릴리스다.
# 확인한 것: 매니페스트 URL 3종 HTTP 200 / Installation CRD의 ipPools 필수 필드는 cidr 하나이고
#   우리가 쓰는 blockSize·cidr·encapsulation(enum에 VXLAN 있음)·natOutgoing·nodeSelector가 전부 스키마에 있음
#   → custom-resources.yaml 수정 없이 그대로 통한다. APIServer CR도 spec {} 그대로 유효.
# 확인 못 한 것: 이 클러스터에서의 실제 reconcile(적용해봐야 안다).
# v3.30부터 CRD가 tigera-operator.yaml에서 분리됐다 — CRD를 먼저 깔지 않으면 오퍼레이터가 Installation을 못 읽는다.
# --server-side: CRD 묶음이 약 3MB라 client-side apply는 last-applied 애노테이션 크기 제한에 걸린다.
#   create는 재실행 시 AlreadyExists로 즉사 → --server-side가 멱등 해법.
# --force-conflicts: 재실행 때 오퍼레이터가 소유권을 가져간 필드에서 conflict로 멈추는 걸 막는다.
CALICO_VERSION="v3.32.1"
CALICO_MANIFESTS="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
kubectl apply --server-side --force-conflicts -f "${CALICO_MANIFESTS}/operator-crds.yaml"
# CRD가 Established 되기 전에 CR을 apply하면 "no matches for kind Installation"으로 죽는다.
kubectl wait --for=condition=Established --timeout=120s \
  crd/installations.operator.tigera.io crd/apiservers.operator.tigera.io
kubectl apply --server-side --force-conflicts -f "${CALICO_MANIFESTS}/tigera-operator.yaml"
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s
kubectl apply -f calico/custom-resources.yaml
# 상류 custom-resources.yaml에 있는 Goldmane·Whisker CR은 우리 파일에 없다 —
# 흐름 로그 수집기와 UI라 8GB 노드에서 RAM만 먹고, 관측은 LGTM이 맡는다.
# 오퍼레이터가 Installation CR을 reconcile해 calico-system ns와 DaemonSet을 만들 때까지 기다린다.
# DS가 생기기 전에 rollout status를 부르면 NotFound로 즉시 끝나므로, 먼저 DS 등장을 기다린 뒤 rollout을 본다.
echo "  calico-node DaemonSet 생성 대기..."
for i in $(seq 1 60); do
  kubectl -n calico-system get ds/calico-node >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { echo "calico-node DS가 5분 안에 생성되지 않았다. tigera-operator 로그를 확인해라: kubectl -n tigera-operator logs deploy/tigera-operator" >&2; exit 1; }
  sleep 5
done
kubectl -n calico-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "[2/9] 네임스페이스 + PodSecurity 라벨 (app·data·argocd·cert-manager=restricted, observability=baseline, observability-host=privileged)"
# 아래 [4]cert-manager·[8]argocd의 --create-namespace보다 먼저 돌아야 그 두 ns가 라벨을 달고 만들어진다.
# (helm --create-namespace는 ns가 이미 있으면 아무것도 안 한다 = 여기서 만든 라벨이 유지된다.)
kubectl apply -f namespaces/

echo "[3/9] StorageClass 6종 + 정적 PV 10개 — 워크로드(GitOps 폭포의 mysql·kafka·관측)보다 먼저 있어야 바인딩 가능"
# 선행(손작업): 각 노드에 데이터 디스크 mkfs·/mnt/disks/<용도> 마운트·fstab 완료 상태(storage/pvs.yaml 헤더).
kubectl apply -f storage/

# MetalLB·Traefik은 GitOps로 이동 — argocd/applicationsets/platform.yaml(metallb wave -4 → pool -3 → traefik -2).
#   여기서 손 설치 안 함. argocd는 아래 손 설치 후 kubectl로 root-app apply(ingress 불요) → 폭포가 metallb/traefik를 뒤이어 세움.

# helm repo add는 같은 이름이 다른 URL로 이미 등록돼 있으면 실패한다 → --force-update로 재실행에서도 통과시킨다.
echo "[4/9] cert-manager (현재 소비자 없으나 Phase2 예약 — bootstrap 손 유지)"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
# --timeout 10m: 파드 3개(controller·webhook·cainjector)가 각기 다른 이미지를 받는다.
# 첫 실행은 VM 3대가 USB SSD 한 장을 공유한 채 동시에 pull하므로 helm 기본 5분을 넘길 수 있다.
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  -f cert-manager/values.yaml --wait --timeout 10m --version v1.21.0   # crds.enabled=true는 values로 이관. 버전 핀

echo "[5/9] sealed-secrets 컨트롤러 (개인키 백업 필수 — 분실 시 기존 봉인본 전체 복호화 불가)"
# helm repo(bitnami-labs.github.io/sealed-secrets)가 404 → GitHub 릴리스 tgz 직접 참조(버전이 URL에 핀)
helm upgrade --install sealed-secrets \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/helm-v2.18.6/sealed-secrets-2.18.6.tgz \
  -n kube-system -f sealed-secrets/values.yaml --wait --timeout 5m   # 파드 1개·이미지 1개 → 기본 5분으로 충분
# <TODO> kubeseal 개인키를 클러스터 밖에 암호화 백업

echo "[6/9] prometheus-operator CRDs (ServiceMonitor/PodMonitor — Alloy가 읽음). 오퍼레이터 아님, CRD만."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
# CRD만 있고 파드가 없어 --wait은 사실상 즉시 끝난다 → 타임아웃은 기본값으로 둔다.
helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds -n kube-system --wait \
  --version 30.0.1                              # 버전 핀

# control-plane 메트릭 수집 경로(etcd). 셀렉터 없는 Service + 수동 Endpoints + ServiceMonitor.
# ServiceMonitor CRD가 방금 생겼으므로 여기서 apply한다. observability 네임스페이스는 [2/9]에서 생성됨.
# apiserver 쪽은 인증이 필요해 Alloy 설정에 직접 두었다(alloy/values.yaml).
kubectl apply -f control-plane/

echo "[7/9] Strimzi 오퍼레이터 1.1.0 (KafkaCluster/Topic CR 감시. data ns watch)"
helm repo add strimzi https://strimzi.io/charts --force-update >/dev/null
# --timeout 10m: 오퍼레이터 이미지가 크고(수백 MB) 첫 실행은 디스크 경합이 겹친다.
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n data --create-namespace --wait --timeout 10m \
  --version 1.1.0 -f strimzi/values.yaml          # watchNamespaces는 values 파일로 전달(--set 사용 안 함)

# MySQL도 GitOps로 이동 — argocd/applications/mysql.yaml(wave -1, prune=false, 벤더 차트 cgv-mysql).
#   mysql-secret은 sealed-secrets App(wave -2)이 선배달 → 수동 apply 게이트 불필요. 봉인·커밋은 root-app 전 필수(secrets/README.md).

echo "[8/9] argocd"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
# --timeout 15m: 파드 5개가 서로 다른 이미지 4종(argocd·redis·haproxy 계열)을 받는다. 이 단계가 pull이 가장 많다.
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f argocd/values.yaml --wait --timeout 15m \
  --version 10.1.4                              # 버전 핀

echo "[9/9] argocd 준비 대기"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo
echo "부트스트랩 완료. 여기까지는 다시 돌려도 같은 상태로 수렴한다(apply는 server-side, helm은 upgrade --install)."
echo "  예외: 앞선 실행이 중간에 죽어 helm 릴리스가 pending-* 상태로 남으면 다음 실행이"
echo "  'another operation is in progress'로 거부된다 → helm rollback 또는 helm uninstall 후 재실행."
echo
echo "다음 순서:"
echo "  1) SealedSecret 13종 봉인·커밋 — docs/시크릿-계약.md 표대로."
echo "     seal-secrets.sh 가 10종을 일괄로, 나머지 3종은 낱개로 만든다"
echo "     (argocd ns 2종은 seal-one.sh, app ns 의 gitlab-registry 는 docker-registry 타입)."
echo "     컨트롤러가 지금 떠 있어야 kubeseal이 공개키를 받는다."
echo "     kubeseal --controller-name sealed-secrets --controller-namespace kube-system 를 반드시 붙인다."
echo "  2) ./root-app.sh 실행 → GitOps 인계"
echo
echo "봉인 없이 root-app을 올리면 mysql·redis·minio·grafana·LGTM이 시크릿을 못 찾아 일제히 실패한다."
echo "ℹ️ argocd는 traefik(GitOps) 뜨기 전엔 ingress 없음 → 초기 접근은 port-forward: kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "   traefik이 뜬 뒤에는 http://argocd.cgv.lan · http://grafana.cgv.lan 으로 접근한다."
echo "   두 이름은 MetalLB가 traefik Service에 배정한 주소를 가리킨다 — 접근하는 기기의 hosts 파일이나 DNS에 그 매핑이 있어야 한다."
