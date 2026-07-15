#!/usr/bin/env bash
# k3s-1 (첫 서버) — embedded etcd cluster-init. 노드배치-cgv.md §1b.
# 노드 라벨은 설치 시 박음(사후 X — stateful nodeSelector 핀이 배포 전에 있어야 함).
set -euo pipefail

sudo mkdir -p /etc/rancher/k3s
sudo cp "$(dirname "$0")/config.yaml" /etc/rancher/k3s/config.yaml

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --cluster-init --node-label cgv.io/data=db" sh -

echo
echo "완료. 토큰(2·3 조인에 필요):"
echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
echo "다음: nodes 2·3에서 ./02-server-join.sh <k3s-1_IP> <TOKEN> <obs|obj>"
