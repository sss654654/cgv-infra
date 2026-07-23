#!/usr/bin/env bash
# k3s-2 / k3s-3 (조인 서버, 3-server etcd HA).
# 사용: ./02-server-join.sh <k3s-1_IP> <TOKEN> <obs|obj>
#   k3s-2 → obs (LGTM 노드) / k3s-3 → obj (MinIO 노드)
set -euo pipefail

SERVER_IP="${1:?k3s-1 IP 필요}"
TOKEN="${2:?node-token 필요 (k3s-1의 /var/lib/rancher/k3s/server/node-token)}"
LABEL="${3:?라벨 필요: obs 또는 obj}"

sudo mkdir -p /etc/rancher/k3s
sudo cp "$(dirname "$0")/config.yaml" /etc/rancher/k3s/config.yaml

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --server https://${SERVER_IP}:6443 --token ${TOKEN} --node-label cgv.io/data=${LABEL}" sh -

echo
echo "완료. k3s-1에서: kubectl get nodes"
echo "  (CNI 없어 NotReady 정상 → cgv-infra/bootstrap/install.sh의 Calico가 Ready로)"
