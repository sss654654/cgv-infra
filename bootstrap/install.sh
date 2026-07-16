#!/usr/bin/env bash
# install.sh — 부트스트랩(set-once). argocd 밖 인프라를 순서대로 깔고, 마지막에 root-app으로 GitOps 인계(§0-2, §3-7).
# 전제: 각 노드에 k3s가 cluster/config.yaml로 설치·조인됨(NotReady 상태). 이 스크립트는 k3s-1(server)에서 실행.
# ⚠️ 차트 버전(calico/strimzi 등)은 build 때 helm search / 릴리스 확인으로 확정. kubeconfig = /etc/rancher/k3s/k3s.yaml.
set -euo pipefail
cd "$(dirname "$0")"

echo "[1/12] Calico (CNI) — 닭-달걀. tigera-operator + 우리 Installation CR (없으면 노드 NotReady)"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml
kubectl apply -f calico/custom-resources.yaml
kubectl -n calico-system rollout status ds/calico-node --timeout=300s || true

echo "[2/12] 네임스페이스 + PodSecurity 라벨 (app/data=restricted, observability=privileged)"
kubectl apply -f namespaces/

echo "[3/12] MetalLB (LoadBalancer)"
helm repo add metallb https://metallb.github.io/metallb >/dev/null
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --wait
kubectl apply -f metallb/pool.yaml              # IPAddressPool + L2Advertisement

echo "[4/12] Traefik (Ingress 컨트롤러) — k3s 번들 Traefik은 disable했으므로 자체 설치"
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace -f traefik/values.yaml --wait

echo "[5/12] cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true --wait

echo "[6/12] sealed-secrets 컨트롤러 (개인키 백업 필수 — §7 비가역)"
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n kube-system --wait
# <TODO> kubeseal 개인키를 클러스터 밖에 암호화 백업

echo "[7/12] prometheus-operator CRDs (ServiceMonitor/PodMonitor — Alloy가 읽음, §6). 오퍼레이터 아님, CRD만."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds -n kube-system --wait

echo "[8/12] Strimzi 오퍼레이터 1.1.0 (KafkaCluster/Topic CR 감시. data ns watch)"
helm repo add strimzi https://strimzi.io/charts >/dev/null
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n data --create-namespace --wait \
  --version 1.1.0 --set watchNamespaces="{data}"

echo "[MySQL 시크릿 선행] mysql-secret 수동 apply — [9] 전 필수(argocd 배달은 [10] 이후라 여기서)"
# ★선후 함정(런북 부록 #1): [9] MySQL이 existingSecret: mysql-secret을 --wait로 요구하는데,
#   SealedSecret 배달경로는 argocd sealed-secrets App(wave -2)이고 그건 [12] root-app 이후에나 돈다.
#   → [6] 컨트롤러 up 뒤, argocd를 기다리지 말고 여기서 봉인본을 직접 apply(컨트롤러가 언실).
#   봉인은 §4에서 컨트롤러([6]) up 후 kubeseal로 생성·커밋해야 이 파일이 존재한다.
if [ ! -f ../workloads/manifests/secrets/mysql-secret.yaml ]; then
  echo "  ✗ mysql-secret.yaml 없음 → 지금 컨트롤러는 떴으니 §4대로 mysql-secret 봉인·커밋 후 install.sh 재실행(helm 멱등)."
  exit 1
fi
kubectl apply -f ../workloads/manifests/secrets/mysql-secret.yaml
echo "  → 컨트롤러가 SealedSecret 언실 대기(평문 Secret 생성까지)"
for i in $(seq 1 30); do kubectl -n data get secret mysql-secret >/dev/null 2>&1 && break; sleep 2; done
kubectl -n data get secret mysql-secret >/dev/null 2>&1 || { echo "  ✗ 60s 내 mysql-secret 언실 실패 — 봉인 오류/컨트롤러 확인(kubectl -n kube-system logs -l name=sealed-secrets-controller)."; exit 1; }

echo "[9/12] MySQL (데이터 안전상 argocd 밖). ★사전: mysql-secret SealedSecret 필요(시크릿-계약)"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
helm upgrade --install mysql bitnami/mysql -n data -f mysql/values.yaml --wait

echo "[10/12] argocd"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f argocd/values.yaml --wait

echo "[11/12] argocd 준비 대기"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo "[12/12] root-app apply → 이하 전부 GitOps로 인계 (§3-7 폭포)"
kubectl apply -f root-app.yaml

echo
echo "완료. argocd가 argocd/를 sync: kubectl -n argocd get applications -w"
echo "⚠️ 앱보다 먼저: SealedSecret 9종 봉인(dev HA — docs/시크릿-계약.md · workloads/manifests/secrets/README.md). mysql-secret은 위 [MySQL 시크릿 선행]에서 이미 apply됨."
