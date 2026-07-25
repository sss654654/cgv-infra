#!/usr/bin/env bash
# k3s-1 (첫 서버) — embedded etcd cluster-init.
# 노드 라벨은 설치 시 박음(사후 X — stateful nodeSelector 핀이 배포 전에 있어야 함).
set -euo pipefail

# 버전 핀 — 세 서버가 같은 k3s로 서야 한다(control-plane 버전 불일치는 지원 대상 아님).
# 재구축 시에도 같은 값으로 같은 클러스터가 재현된다.
K3S_VERSION="v1.36.2+k3s1"

cd "$(dirname "$0")"

# 이 스크립트는 새 etcd 클러스터를 만든다. 다른 노드에서 돌면 독립 클러스터가 하나 더 서고
# 복구는 uninstall 뿐이라, 대상 노드와 기존 설치 여부를 먼저 확인한다.
[ "$(hostname)" = "k3s-1" ] || { echo "01은 k3s-1 전용. 현재 호스트: $(hostname)" >&2; exit 1; }
[ -d /var/lib/rancher/k3s/server/db/etcd ] && { echo "이미 etcd 데이터가 있다 — 재실행 중단" >&2; exit 1; }
[ -f config.yaml ] || { echo "config.yaml이 스크립트와 같은 디렉터리에 없다" >&2; exit 1; }

sudo mkdir -p /etc/rancher/k3s
sudo cp config.yaml /etc/rancher/k3s/config.yaml

# 파이프 대신 받아서 실행 — 전송이 끊기면 인스톨러가 반쯤 실행된 채 끝나는 걸 막는다.
curl -sfL --connect-timeout 10 --max-time 180 --retry 3 https://get.k3s.io -o /tmp/k3s-install.sh
INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server --cluster-init --node-label cgv.io/data=db" \
  sh /tmp/k3s-install.sh

echo
echo "완료. 토큰(2·3 조인에 필요):"
echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
echo "다음: nodes 2·3에서 한 대씩 순차로 ./02-server-join.sh <k3s-1_IP> <obs|obj>"
echo "      (토큰은 인자가 아니라 실행 중 입력한다 — 히스토리·프로세스 목록에 안 남게)"
