#!/usr/bin/env bash
# install.sh — 부트스트랩(set-once). argocd 밖 인프라를 순서대로 깔고, 마지막에 root-app으로 GitOps 인계.
# 전제: 각 노드에 k3s가 cluster/config.yaml로 설치·조인됨(NotReady 상태). 이 스크립트는 k3s-1(server)에서 실행.
# ⚠️ 차트 버전(calico/strimzi 등)은 build 때 helm search / 릴리스 확인으로 확정. kubeconfig = /etc/rancher/k3s/k3s.yaml.
set -euo pipefail
cd "$(dirname "$0")"

echo "[1/10] Calico (CNI) — 닭-달걀. tigera-operator + 우리 Installation CR (없으면 노드 NotReady)"
# server-side apply: tigera-operator.yaml은 CRD가 커서 client-side apply가 annotation 크기 초과로 실패,
# create는 재실행(mysql-secret 게이트 exit 후) 시 AlreadyExists로 즉사 → --server-side가 멱등 해법.
kubectl apply --server-side -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml
kubectl apply -f calico/custom-resources.yaml
kubectl -n calico-system rollout status ds/calico-node --timeout=300s || true

echo "[2/10] 네임스페이스 + PodSecurity 라벨 (app/data=restricted, observability=privileged)"
kubectl apply -f namespaces/

echo "[3/10] StorageClass 6종 + 정적 PV 10개 — 워크로드(GitOps 폭포의 mysql·kafka·관측)보다 먼저 있어야 바인딩 가능"
# 선행(손작업): 각 노드에 데이터 디스크 mkfs·/mnt/disks/<용도> 마운트·fstab 완료 상태(storage/pvs.yaml 헤더).
kubectl apply -f storage/

# MetalLB·Traefik은 GitOps로 이동 — argocd/applicationsets/platform.yaml(metallb wave -4 → pool -3 → traefik -2).
#   여기서 손 설치 안 함. argocd는 아래 손 설치 후 kubectl로 root-app apply(ingress 불요) → 폭포가 metallb/traefik를 뒤이어 세움.

echo "[4/10] cert-manager (현재 소비자 없으나 Phase2 예약 — bootstrap 손 유지)"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  -f cert-manager/values.yaml --wait --version v1.21.0   # crds.enabled=true는 values로 이관. 버전 핀

echo "[5/10] sealed-secrets 컨트롤러 (개인키 백업 필수 — 분실 시 기존 봉인본 전체 복호화 불가)"
# helm repo(bitnami-labs.github.io/sealed-secrets)가 404 → GitHub 릴리스 tgz 직접 참조(버전이 URL에 핀)
helm upgrade --install sealed-secrets \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/helm-v2.18.6/sealed-secrets-2.18.6.tgz \
  -n kube-system -f sealed-secrets/values.yaml --wait
# <TODO> kubeseal 개인키를 클러스터 밖에 암호화 백업

echo "[6/10] prometheus-operator CRDs (ServiceMonitor/PodMonitor — Alloy가 읽음). 오퍼레이터 아님, CRD만."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds -n kube-system --wait \
  --version 30.0.1                              # 버전 핀

echo "[7/10] Strimzi 오퍼레이터 1.1.0 (KafkaCluster/Topic CR 감시. data ns watch)"
helm repo add strimzi https://strimzi.io/charts >/dev/null
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n data --create-namespace --wait \
  --version 1.1.0 -f strimzi/values.yaml          # watchNamespaces는 values 파일로 전달(--set 사용 안 함)

# MySQL도 GitOps로 이동 — argocd/applications/mysql.yaml(wave -1, prune=false, 벤더 차트 cgv-mysql).
#   mysql-secret은 sealed-secrets App(wave -2)이 선배달 → 수동 apply 게이트 불필요. 봉인·커밋은 root-app 전 필수(secrets/README.md).

echo "[8/10] argocd"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f argocd/values.yaml --wait \
  --version 10.1.4                              # 버전 핀

echo "[9/10] argocd 준비 대기"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo "[10/10] root-app apply → 이하 전부 GitOps로 인계(app-of-apps 폭포: metallb -4 → pool -3 → traefik -2 → 미들웨어 -1 → 관측 0~1 → 앱 3)"
kubectl apply -f root-app.yaml

echo
echo "완료. argocd가 argocd/를 sync: kubectl -n argocd get applications -w"
echo "⚠️ root-app 전 필수: SealedSecret 10종 봉인·커밋(docs/시크릿-계약.md · workloads/manifests/secrets/README.md). mysql-secret 포함 — sealed-secrets App(wave -2)이 배달 후 mysql App(wave -1)이 sync."
echo "ℹ️ argocd는 traefik(GitOps) 뜨기 전엔 ingress 없음 → 초기 접근은 port-forward: kubectl -n argocd port-forward svc/argocd-server 8080:443"
