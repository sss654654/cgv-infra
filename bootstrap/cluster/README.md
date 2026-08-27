# cgv-infra — 클러스터 프로비저닝 (L0)

맨 VM → k3s 클러스터. **cgv-infra(install.sh~)의 앞 단계.**

**경계(실행 모델):** 여기 = 노드/SSH 레벨(k3s 설치·조인). cgv-infra = 클러스터 API(Calico~root-app).
**handoff:** "k3s 3노드 조인됨(CNI 없어 NotReady)" → cgv-infra `install.sh` 첫 단계 Calico가 Ready로.

## 순서
0. **Proxmox VE 설치**(외장 SSD) + 브리지(vmbr0 WAN / vmbr1 LAN) — 수작업(learn-by-doing).
1. **VM 3개**: 각 4vCPU / 8GB / 40GB boot + 용도별 LV. Ubuntu/Debian.
   - k3s-1: mysqldata 20G · kafkadata 30G · ingesterwal 5G
   - k3s-2: kafkadata 30G · ingesterwal 5G · lokiwal 5G · tempowal 5G
   - k3s-3: kafkadata 30G · ingesterwal 5G · miniodata 100G
2. **OS prep**: 정적 IP(Phase1 192.168.0.201-203), SSH키, unattended-upgrades.
   **데이터 디스크를 `/mnt/disks/<용도>`에 마운트** — 각 디스크를 `mkfs.ext4` 후 fstab UUID로 마운트(통마운트, 서브디렉터리 mkdir 없음). local-path는 config.yaml에서 disable — PVC는 정적 PV(`bootstrap/storage/`, install.sh [3/9]가 apply)에 바인딩된다.
3. 세 노드에 `bootstrap/cluster/`의 네 파일(config.yaml·registries.yaml·01·02)을 같은 디렉터리로 복사 — 스크립트가 옆의 config.yaml을 `/etc/rancher/k3s/`로 옮긴다.
   **`registries.yaml`은 손으로 옮긴다** — `sudo cp registries.yaml /etc/rancher/k3s/`.
   k3s가 기동할 때만 읽으므로 이미 떠 있으면 `sudo systemctl restart k3s`까지 해야 반영된다.
   이 파일이 없으면 GitLab 레지스트리가 평문(http)이라 kubelet이 `http: server gave HTTP
   response to HTTPS client`로 거절하고, booking·queue·frontend가 전부 `ImagePullBackOff`에 걸린다.
4. **k3s-1**: `./01-server-init.sh` → 출력된 명령으로 토큰 확인.
5. **한 대씩 순차로** (동시에 조인하면 etcd 쿼럼이 흔들린다). 토큰은 인자가 아니라 실행 중 입력한다.
   **k3s-2**: `./02-server-join.sh <k3s-1_IP> obs` → `kubectl get nodes`로 2대 확인 후
   **k3s-3**: `./02-server-join.sh <k3s-1_IP> obj`
6. `kubectl get nodes -L cgv.io/data` → 3 NotReady(정상) + 라벨 db·obs·obj 확인.
   라벨은 Node 생성 시 한 번만 박히므로 틀렸으면 `kubectl label node <노드> cgv.io/data=<값> --overwrite`.
   → **cgv-infra/bootstrap/install.sh** 로 넘어감.

## config.yaml을 이미 설치된 노드에 다시 반영할 때
`config.yaml`은 k3s가 **기동할 때만** 읽는다. 파일을 고쳐도 도는 클러스터엔 아무 일도 안 생긴다.
세 노드에 새 파일을 `/etc/rancher/k3s/config.yaml`로 복사한 뒤 **한 대씩 순차로** `sudo systemctl restart k3s`.
동시에 재시작하면 3-member etcd에서 살아 있는 멤버가 1개가 돼 쿼럼이 끊긴다.
한 대를 재시작하고 `kubectl get nodes`가 3대를 다시 Ready로 보고할 때까지 기다린 뒤 다음 대로 간다.
반영됐는지는 `kubectl describe node <노드>`의 Allocatable로 확인한다(kubelet 예약이 걸리면 capacity보다 작아진다).

## Phase1 → Phase2
Phase1 = vmbr0 직결(192.168.0.x, 스켈레톤). 검증 후 폐기 → vmbr1+OPNsense(10.0.0.x)로 재형성.
`config.yaml`의 `tls-san`에 양쪽 IP를 미리 넣어 재형성 시 API 인증서가 안 깨짐.

## 나중 (Terraform/Ansible로 승격)
0-5단계(Proxmox VM·OS prep·k3s)를 Terraform(Proxmox provider)·Ansible로 자동화하면 여기 담긴다.
그때가 이 repo가 본래 역할을 하는 시점(지금은 스크립트 + 체크리스트).
