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
   **데이터 디스크를 `/mnt/disks/<용도>`에 마운트** — 각 디스크를 `mkfs.ext4` 후 fstab UUID로 마운트(통마운트, 서브디렉터리 mkdir 없음). local-path는 config.yaml에서 disable — PVC는 정적 PV(`bootstrap/storage/`, install.sh [3/12]이 apply)에 바인딩된다.
3. 각 노드에 `k3s/config.yaml` 복사 — 스크립트가 함.
4. **k3s-1**: `./k3s/01-server-init.sh` → 출력된 명령으로 토큰 확인.
5. **k3s-2**: `./k3s/02-server-join.sh <k3s-1_IP> <TOKEN> obs`
   **k3s-3**: `./k3s/02-server-join.sh <k3s-1_IP> <TOKEN> obj`
6. `kubectl get nodes` → 3 NotReady(정상). → **cgv-infra/bootstrap/install.sh** 로 넘어감.

## Phase1 → Phase2
Phase1 = vmbr0 직결(192.168.0.x, 스켈레톤). 검증 후 폐기 → vmbr1+OPNsense(10.0.0.x)로 재형성.
`config.yaml`의 `tls-san`에 양쪽 IP를 미리 넣어 재형성 시 API 인증서가 안 깨짐.

## 나중 (Terraform/Ansible로 승격)
0-5단계(Proxmox VM·OS prep·k3s)를 Terraform(Proxmox provider)·Ansible로 자동화하면 여기 담긴다.
그때가 이 repo가 본래 역할을 하는 시점(지금은 스크립트 + 체크리스트).
