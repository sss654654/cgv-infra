#!/usr/bin/env bash
# k3s-2 / k3s-3 (조인 서버, 3-server etcd HA).
# 사용: ./02-server-join.sh <k3s-1_IP> <obs|obj>   — 토큰은 실행 중 입력한다.
#   k3s-2 → obs (LGTM 노드) / k3s-3 → obj (MinIO 노드)
# 한 대씩 순차로. k3s-2가 붙어 노드 2대가 보인 뒤 k3s-3을 돌린다(동시 조인 시 쿼럼이 흔들림).
set -euo pipefail

K3S_VERSION="v1.36.2+k3s1"   # 첫 서버와 동일해야 한다

SERVER_IP="${1:?k3s-1 IP 필요}"
LABEL="${2:?라벨 필요: obs 또는 obj}"

# 라벨은 Node 객체가 처음 생길 때만 박힌다 — 오타로 박으면 재실행해도 안 고쳐지고
# 7부에서 MySQL·Loki·Tempo·MinIO가 Pending으로만 뜬다. 값을 여기서 걸러낸다.
case "$LABEL" in obs|obj) ;; *) echo "라벨은 obs 또는 obj (입력: $LABEL)" >&2; exit 1;; esac
[ "$(hostname)" != "k3s-1" ] || { echo "02는 조인 노드(k3s-2·k3s-3) 전용" >&2; exit 1; }

# config.yaml은 상대경로로 읽으므로 검사보다 cd가 먼저 와야 한다.
# 순서가 반대면 호출자의 현재 디렉터리에서 찾게 돼, 파일이 스크립트 옆에 있어도 가짜 실패가 난다.
cd "$(dirname "$0")"
[ -f config.yaml ] || { echo "config.yaml이 스크립트와 같은 디렉터리에 없다" >&2; exit 1; }

# 첫 서버가 실제로 응답하는지 먼저 본다(내려간 상태로 조인하면 원인 모를 실패가 난다).
curl -sk --connect-timeout 5 "https://${SERVER_IP}:6443/livez" >/dev/null \
  || { echo "k3s-1(${SERVER_IP}:6443) 미응답 — 첫 서버부터 확인" >&2; exit 1; }

# 토큰은 인자로 받지 않는다. 커맨드라인에 두면 ps·셸 히스토리·k3s.service(0644)에 남는다.
# K3S_TOKEN 환경변수로 넘기면 인스톨러가 k3s.service.env(0600)에만 기록한다.
read -rsp "k3s-1의 node-token 붙여넣기: " TOKEN; echo
[ -n "$TOKEN" ] || { echo "토큰이 비었다" >&2; exit 1; }

sudo mkdir -p /etc/rancher/k3s
sudo cp config.yaml /etc/rancher/k3s/config.yaml

curl -sfL --connect-timeout 10 --max-time 180 --retry 3 https://get.k3s.io -o /tmp/k3s-install.sh
INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_TOKEN="$TOKEN" \
  INSTALL_K3S_EXEC="server --server https://${SERVER_IP}:6443 --node-label cgv.io/data=${LABEL}" \
  sh /tmp/k3s-install.sh

echo
echo "완료. k3s-1에서 확인:"
echo "  kubectl get nodes -L cgv.io/data     # 노드 수와 라벨(db·obs·obj)을 함께 본다"
echo "  (CNI 없어 NotReady 정상 → cgv-infra/bootstrap/install.sh의 Calico가 Ready로)"
