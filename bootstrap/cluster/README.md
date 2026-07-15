# cgv-infra — 클러스터 프로비저닝 (L0)

맨 VM → k3s 클러스터. **cgv-infra(install.sh~)의 앞 단계.**

**경계(실행 모델):** 여기 = 노드/SSH 레벨(k3s 설치·조인). cgv-infra = 클러스터 API(Calico~root-app).
**handoff:** "k3s 3노드 조인됨(CNI 없어 NotReady)" → cgv-infra `install.sh` 첫 단계 Calico가 Ready로.

## 순서
0. **Proxmox VE 설치**(외장 SSD) + 브리지(vmbr0 WAN / vmbr1 LAN) — 수작업(learn-by-doing).
1. **VM 3개**: 각 4vCPU / 8GB / 40GB boot + 용도별 LV(노드배치-cgv.md §1: mysqldata·kafkadata·lgtmdata·miniodata). Ubuntu/Debian.
2. **OS prep**: 정적 IP(Phase1 172.30.1.201-203), SSH키, unattended-upgrades.
   ★ **용도별 LV를 local-path 저장경로에 마운트** — mysqldata→k3s-1 · lgtmdata→k3s-2 · miniodata→k3s-3 · kafkadata→각 노드. 각 LV를 그 노드의 `/var/lib/rancher/k3s/storage`(local-path 기본경로)에 fstab UUID로 마운트해야, nodeSelector로 핀된 stateful 파드의 PVC가 부트디스크가 아니라 그 LV에 잡힌다.
3. 각 노드에 `k3s/config.yaml` 복사 — 스크립트가 함.
4. **k3s-1**: `./k3s/01-server-init.sh` → 출력된 명령으로 토큰 확인.
5. **k3s-2**: `./k3s/02-server-join.sh <k3s-1_IP> <TOKEN> obs`
   **k3s-3**: `./k3s/02-server-join.sh <k3s-1_IP> <TOKEN> obj`
6. `kubectl get nodes` → 3 NotReady(정상). → **cgv-infra/bootstrap/install.sh** 로 넘어감.

## Phase1 → Phase2 (노드배치-cgv.md §1b)
Phase1 = vmbr0 직결(172.30.1.x, 스켈레톤). 검증 후 폐기 → vmbr1+OPNsense(10.0.0.x)로 재형성.
`config.yaml`의 `tls-san`에 양쪽 IP를 미리 넣어 재형성 시 API 인증서가 안 깨짐.

## 나중 (Terraform/Ansible로 승격)
0-5단계(Proxmox VM·OS prep·k3s)를 Terraform(Proxmox provider)·Ansible로 자동화하면 여기 담긴다.
그때가 이 repo가 진짜 값을 하는 시점(지금은 스크립트 + 체크리스트).
