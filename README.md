# cgv-infra — CGV 온프렘 k3s 인프라 (GitOps)

CGV 티켓팅 폴리글랏 MSA([cgv-onprem](https://github.com/sss654654/cgv-onprem) — queue·booking·frontend)를
온프레미스 k3s 클러스터에 GitOps로 배포·운영하는 인프라 코드.
물리 노드부터 CNI·LB·Ingress·스토리지·관측·미들웨어·시크릿까지 직접 구성한다.

이 repo로 노드 프로비저닝부터 CGV 서비스 기동까지 재현한다: 노드 프로비저닝 스크립트(`bootstrap/cluster/`) → 플랫폼 부트스트랩(`bootstrap/install.sh`) → GitOps 선언(`argocd/` + `workloads/`).

**동작 중인 서비스: [ticket.subinhong.dev](https://ticket.subinhong.dev)** — 클러스터가 노트북 한 대 위에 있어 23:30에 꺼지고 07:30에 켜진다. 그 사이에는 응답하지 않는다.

> 노트북 한 대를 열어 여기까지 오는 과정은 편별로 기록했다 — 각 편에서 무엇을 했고 무슨 개념을 짚었는지는 [만든 과정](#만든-과정--편별-기록)에.

---

## 목적

티켓팅(생중계 좌석 예매) 대기열 처리 MSA를 온프렘 환경에서 운영한다.
클라우드 매니지드가 대신 제공하던 것을 직접 구성하고 GitOps로 선언한다.

```
EKS   →  k3s 3-server · embedded etcd 쿼럼 3
ELB   →  MetalLB
RDS   →  MySQL (StatefulSet · 정적 PV)
S3    →  MinIO
(없음) →  Calico(CNI) · Traefik(Ingress) · 정적 PV(스토리지) · SealedSecret(시크릿)
```

---

## 상태 (2026-08-30)

플랫폼·관측·미들웨어·앱이 전부 GitOps로 수렴했고, 그 GitOps 원본은 GitLab이다. ArgoCD는 자기 자신도 Application으로 관리한다. 서비스는 인터넷에 공개돼 있다.

```
Application 30 개    플랫폼 · 관측 · 미들웨어 · 시크릿 · 정책 · 공개 경로 · 앱 3종
서비스 접속          https://ticket.subinhong.dev
                    Cloudflare 엣지 → 공유기 → OPNsense → Traefik(10.0.0.240) → 앱
관리 접속            WireGuard 터널 → argocd.cgv.lan · grafana.cgv.lan  (443 에는 없다)
```

코드 push부터 롤아웃까지 자동이다: push → CI 5단 게이트(check·test·build·scan·publish) →
불변 태그 이미지 → argocd-image-updater가 태그를 이 저장소에 write-back → ArgoCD 롤아웃.

### 부하 실측으로 정한 값

판을 두 번에 나눠 돌렸다 — 격리망 안에서 21회, 공개 경로가 생긴 뒤 같은 경로로 13회.
아래 값은 전부 그 판에서 나왔고, 각 값의 근거 수치는 해당 values 주석에 있다.

```
동시 입장 정원      1,000        MAX_SESSIONS.  좌석 4,000 이 상한을 정한다 —
                                2,500 이면 100초에 소진돼 정상 구간이 없다
세션 만료          300초         회차 조회 10-30 + 좌석 선택 30-120 + 결제 60-180 의 합
좌석 점유          180초         좌석 선택에서 결제 진입까지
입장 인증          600초         회수 이벤트 유실 시 최후 방어.  세션의 2배
승격 배치 / 주기    25 / 0.5초    상한(초당 50명)은 100/2초 와 같고 뭉텅이만 4분의 1
DB 커넥션 풀        30           10 일 때 대기 397건
booking            2코어 · limit 1,536Mi · heap 상한 768Mi (1Gi 에서 OOMKill)
queue              4 replicas · limit 1코어 / 256Mi
traefik            3 replicas · limit 2Gi
```

**시간 값 셋의 순서가 깨지면 자원이 멀쩡해도 처리량이 무너진다** — 좌석 180 < 세션 300 < 인증 600.
좌석을 고르는 중에 자리가 회수되면 선택이 403이 된다.

1만 명 판정 결과는 `5xx 0 / 759,813 요청` · 확정 초당 15.58건 · 전원 여정 완주이고,
자원 최다는 Redis master CPU 41%였다. 3만 명에서는 노드 메모리(8GB × 3)가 먼저 걸려
kubelet이 파드를 축출했다 — 애플리케이션 한계가 아니라 물리 한계다.

### 데모 데이터 초기화

좌석과 대기열은 모든 방문자가 공유한다. 두면 4,000석이 차고 그 뒤에 온 사람은 매진 화면만 본다.
[`reset-app`](workloads/manifests/reset-app/)의 CronJob이 하루 여섯 번(08·11·14·17·20·23시, Asia/Seoul)
**대기열을 먼저, 그다음 예매 기록을** 비운다 — 순서가 반대면 지우는 동안 승격된 관객이 좌석을 잡아
잔재가 남는다. 이 파드도 `app`의 기본 차단 정책에 걸리므로 통로를 따로 열었다.

공개 사이트에서 보이는 대기열 정원은 위 표의 실측값(1,000)이 아니라 더 낮은 값이다 —
1,000이면 방문자가 가상 관객을 넣어도 전원이 즉시 입장해 대기열이 화면에 안 나타난다.

---

## 실행 스택 — 물리 → 가상 → 클러스터

```
┌──────────────────────────────────────────────────────────────┐
│  노트북 (31.3GB RAM) — 전원·호스트                             │
│  └─ 외장 USB SSD                                              │
│     └─ Proxmox VE (하이퍼바이저, 부팅 디스크)                   │
│        ├─ vmbr1 (물리 NIC 없음 — 격리망)                       │
│        │   ├─ VM: k3s-1  (4 vCPU / 8GB)  10.0.0.11  ┐         │
│        │   ├─ VM: k3s-2  (4 vCPU / 8GB)  10.0.0.12  ├ 클러스터 │
│        │   └─ VM: k3s-3  (4 vCPU / 8GB)  10.0.0.13  ┘         │
│        └─ VM: OPNsense — 두 브리지에 다 꽂힌 유일한 기계         │
│             vmbr0 측 192.168.0.210 · vmbr1 측 10.0.0.1        │
└──────────────────────────────────────────────────────────────┘
      데스크탑(별도, 192.168.0.167 — vmbr0 쪽)
        ├─ GitLab CE — ArgoCD가 읽는 GitOps 원본
        └─ CI 러너(docker executor) · Container Registry
```

- **하이퍼바이저 = Proxmox VE**, 외장 SSD에 설치(노트북 부팅 디스크와 분리).
- **k3s 노드 3 = VM**, 각 4 vCPU / 8GB / 40GB 부팅 + 용도별 LV(아래 스토리지). allocatable memory는 노드당 5081Mi다(8GB에서 kubelet 예약과 eviction 임계를 뺀 값).
- **k3s 노드는 `vmbr1`에 있다.** 이 브리지에는 물리 NIC이 없다 — 격리가 규칙이 아니라 배선에서 나온다.
- **OPNsense = 별도 VM**(k3s 노드 아님) — `vmbr0`·`vmbr1` 양쪽에 NIC을 하나씩 가진 유일한 기계이고, 격리망의 게이트웨이·방화벽·DNS·WireGuard 종단을 겸한다.
- **GitLab = 데스크탑**(클러스터 밖, Docker) — ArgoCD가 읽는 저장소가 여기다(아래 [GitOps 원본](#gitops-원본--gitlab)).
  GitHub에는 push 미러로 공개 사본만 나간다. 노드에서 이 주소(`:8929`·`:5050`)로 나가는 길은 OPNsense 허용 규칙 두 줄이다.
- **CI 러너·Container Registry = 같은 데스크탑 GitLab.** 파이프라인이 불변 태그(`dev-<파이프라인번호>-<커밋해시>`) 이미지를 레지스트리에 올리고, 각 노드의 `registries.yaml`이 그 레지스트리를 신뢰한다.

---

## k3s 클러스터 아키텍처

밖에서 여기까지 오는 길은 아래 [네트워크](#네트워크)에 있다. 이 그림은 그 길 끝, 클러스터 안이다.

```
   ┌───────────────────────────────────────────────────────────────┐
   │  k3s 클러스터 — 3 server 노드 (all control-plane + worker)     │
   │                                                                 │
   │   MetalLB 10.0.0.240 ─▶ Traefik ┬ /api/admission → queue        │
   │                                  ├ /api          → booking       │
   │                                  └ /             → frontend      │
   │                                                                 │
   │   k3s-1 (db)          k3s-2 (obs)          k3s-3 (obj)          │
   │   ├ etcd ┐            ├ etcd ┼─ 쿼럼 3 ─┤  ├ etcd ┘             │
   │   ├ MySQL             ├ Loki · Tempo      ├ MinIO(S3 백엔드)    │
   │   └ Kafka broker      └ Kafka broker      └ Kafka broker        │
   │                                                                 │
   │   노드당 1씩 강제(hard anti-affinity):                          │
   │     Kafka 브로커 3 · Mimir ingester 3 · Redis 3 · Traefik 3      │
   │   float(스케줄러 배치): 앱 3종 · ArgoCD · Grafana ·             │
   │     Mimir 나머지 8파드 / DaemonSet: alloy · node-exporter        │
   │                                                                 │
   │   CNI=Calico  ·  LB=MetalLB  ·  Ingress=Traefik  (번들 전부 교체)│
   └───────────────────────────────────────────────────────────────┘
```

- **3노드 전부 k3s `server`**(control-plane+worker) → embedded **etcd 쿼럼 3**. 노드 하나 죽어도 쿼럼 2 유지(HA). 워커 전용 노드 없음.
- **k3s 번들 컴포넌트 전부 교체**: `flannel-backend: none`→**Calico**, `servicelb` disable→**MetalLB**, `traefik` disable→**자체 Traefik**. (`bootstrap/cluster/config.yaml`)
- **네임스페이스와 PodSecurity** — 프로파일은 그 ns에 실제로 뜨는 파드 스펙을 렌더해서 정했다.

  | ns | 프로파일 | 이유 |
  |---|---|---|
  | `app` · `data` · `argocd` · `cert-manager` | restricted | 렌더 실물이 전부 통과 |
  | `observability` | baseline | tempo·alloy·minio가 seccomp·cap drop을 안 채운다. 호스트 접근은 안 하므로 baseline은 통과 |
  | `observability-host` | privileged | node-exporter가 hostNetwork·hostPID·hostPath를 쓴다. 이것만 분리해 나머지를 baseline으로 유지 |
  | `metallb-system` / `traefik` | privileged / restricted | Argo가 만드는 ns라 라벨도 ApplicationSet에서 건다 |
  | `kube-system` · `calico-system` · `tigera-operator` | 없음 | k3s·tigera-operator가 소유한다. 집행을 걸면 클러스터 기동이 막힌다 |

  경계는 **PodSecurity 라벨**과 **NetworkPolicy**(네 네임스페이스 24건, 기본 차단 + 지정 출처만 — 아래 [보안](#보안))다. ResourceQuota는 없다.

---

## 노드별 구성

| 노드 | 스펙 | 라벨 | 용도별 LV | 핀된 stateful | 비고 |
|---|---|---|---|---|---|
| **k3s-1** | 4vCPU/8GB | `cgv.io/data=db` | mysqldata 20G · kafkadata 30G · ingesterwal 5G | **MySQL** · Mimir ingester(1/3) | etcd·CP · Kafka broker |
| **k3s-2** | 4vCPU/8GB | `cgv.io/data=obs` | kafkadata 30G · ingesterwal 5G · lokiwal 5G · tempowal 5G | **Loki · Tempo** · Mimir ingester(1/3) | etcd·CP · Kafka broker |
| **k3s-3** | 4vCPU/8GB | `cgv.io/data=obj` | miniodata 100G · kafkadata 30G · ingesterwal 5G | **MinIO** · Mimir ingester(1/3) | etcd·CP · Kafka broker |

- **stateful 싱글턴은 nodeSelector로 핀** — 전용 LV가 그 노드에 있어서: MySQL→`db`, Loki/Tempo→`obs`, MinIO→`obj`. (miniodata가 100G인 건 MinIO가 LGTM의 S3 데이터 몸통이기 때문.)
- **Kafka 3브로커·Mimir ingester 3 = hard podAntiAffinity로 노드당 1개**(각 노드 kafkadata·ingesterwal LV 사용, 각각 RF3 성립).
- **Redis 3파드·Traefik 3파드도 노드당 1개로 강제**(hard podAntiAffinity). 근거는 워크로드마다 다르다:
  - **Traefik**(파드 3 = 노드 3) — 몰린 노드가 죽으면 MetalLB LB IP는 살아 있는데 백엔드가 0이 되어 전 Ingress가 502다.

    ```
    2파드로 시작    부하 실측(1만 명)에서 연결 메모리가 limit 에 닿았다
    3파드 × 2Gi     지금 값.  근거 수치는 traefik values 주석에 있다
    노드 하나 이탈   파드 하나가 Pending, 남은 두 대가 트래픽을 받는다
    ```
  - **Redis**(파드 3 = 노드 3) — sentinel이 각 파드 안의 사이드카라, **파드가 몰리면 투표권도 몰린다.**

    ```
    2파드가 한 노드에   그 노드가 서면 sentinel 3 중 2가 동시에 사라진다
                       → quorum 2 미달 → failover 가 아예 일어나지 않는다
    1파드씩 세 노드에   노드 하나가 빠지면 파드 하나가 Pending.
                       → 남은 2로 quorum 2를 채워 failover 는 동작한다
    ```
    quorum을 3으로 올리면 이 근거가 무너진다.
- **Mimir stateless(distributor/querier/…)·store_gateway·compactor·grafana·앱·ArgoCD = float**(스케줄러가 배치). store_gateway·compactor는 emptyDir이라 노드 죽어도 재스케줄.
- **alloy·node-exporter는 DaemonSet** — float이 아니라 전 노드에 1개씩.
- ⚠️ hard를 걸면서 감수하는 것 — 노드 한 대가 내려간 상태에서 Redis 차트를 업데이트하면 롤아웃이 Pending 파드에서 멈춘다(`podManagementPolicy` 기본값 `OrderedReady`).

---

## 네트워크

```
인터넷
  │   ticket.subinhong.dev  →  Cloudflare 엣지 (Proxied)
  ▼
공유기 192.168.0.1
  │   포트포워딩 2개 — 443/TCP · 51820/UDP → 192.168.0.210
  ▼
OPNsense   WAN 192.168.0.210 (vmbr0)  ·  LAN 10.0.0.1 (vmbr1)
  │   Destination NAT  443/TCP → 10.0.0.240:443
  │   출발지가 Cloudflare 대역(별칭 cloudflare_v4, URL Table 로 1일마다 갱신)일 때만 통과
  ▼
MetalLB cgv-pool 10.0.0.240-250  →  Traefik  →  경로별 앱
```

- **노드는 `10.0.0.11-13`**, MetalLB 풀은 **`10.0.0.240-250`**(`cgv-pool`). 이 대역은 공유기가 라우팅하는 방법을 모르므로 밖에서 직접 닿지 않는다.
- **밖에서 안으로 들어오는 문은 둘뿐이다.**

  ```
  443/TCP     서비스.  출발지가 엣지 대역일 때만 통과
  51820/UDP   WireGuard.  등록된 공개키로 서명된 패킷이 아니면 한 바이트도 응답하지 않는다
              터널 안에서도 목적지가 10.0.0.0/24 밖이면 버린다
  ```
- **공인 IP를 알아도 엣지를 건너뛰면 들어오지 못한다.** OPNsense가 출발지를 보고 거른다.
  판정을 Traefik이 아니라 OPNsense에 두는 이유 — Traefik Service가 `externalTrafficPolicy: Cluster`라, 노드 간 전달에서 출발지가 노드 주소로 바뀌어 Traefik은 원래 주소를 못 본다.
- **안에서 밖으로 나가는 길은 허용 규칙 네 줄이 정한다.** 위에서부터 대조하고 맞는 것에서 멈춘다.

  ```
  1  → 192.168.0.167 : 8929, 5050   허용      배포 — ArgoCD 동기화 · 이미지 pull
  2  → 192.168.0.200 : 9100         허용      감시 — pve 호스트 지표
  3  → 192.168.0.0/24 나머지         차단+로그
  4  → 그 밖 전부 (인터넷)           허용      이미지 허브 · apt · NTP · Discord
  ```
  1·2가 3보다 위에 있어야 성립한다. 3이 위로 가면 배포가 함께 멈춘다.
- **Ingress** — Traefik(LoadBalancer)에 MetalLB가 IP를 할당하고, 경로로 앱을 가른다([frontend/values.yaml](workloads/charts/apps/frontend/values.yaml)).
  frontend Ingress에는 `host`를 적지 않는다 — 적으면 그 이름으로 온 요청만 받아 LB IP 직접 접근이 끊긴다.
- **관리 UI(`argocd.cgv.lan`·`grafana.cgv.lan`)는 `web` 엔트리포인트에만 붙는다.**

  ```
  안 적으면    Traefik 이 라우터를 80·443 양쪽에 붙인다
               → 443 으로 들어와 Host 헤더만 바꾸면 관리 화면에 닿는다
  web 명시     80 에만 붙는다.  공유기가 443 만 넘기므로 밖에서는 안 닿는다
  ```
  두 이름은 접근하는 기기의 hosts 또는 DNS 가 Traefik 주소로 풀어야 하고, 격리망 밖에서는 WireGuard 터널을 통한다.
- **재구축 시 IP 전환** — `config.yaml`의 `tls-san`에 `192.168.0.x`·`10.0.0.x` 양쪽이 들어 있어 API 인증서가 대역 전환에 깨지지 않는다.

---

## 스토리지 — 정적 PV (프로비저너 없음)

```
외장 USB SSD (단일 물리)
 └ Proxmox 호스트가 용도별 LV로 분할 → 각 노드 VM에 디스크로 attach
    └ 노드 OS가 각 디스크를 mkfs 후 /mnt/disks/<용도> 에 마운트(fstab UUID)
       └ 정적 PV(bootstrap/storage/pvs.yaml)가 그 마운트 지점을 가리킴
          └ SC 6종(no-provisioner·WaitForFirstConsumer)이 용도별 PVC↔PV 바인딩을 가름
             └ PV nodeAffinity → stateful 파드가 자기 디스크 노드에 뜸
```

- **디스크 하나 = 파일시스템 하나 = PV 하나**(전부 통마운트). LGTM 로컬 영속은 ingester WAL(노드당)·loki/tempo WAL뿐이고, store_gateway·compactor는 emptyDir(MinIO에서 재생성).
- k3s 기본 local-path는 **비활성**(`cluster/config.yaml`의 `disable: local-storage`) — 기본 SC로 새서 부트디스크에 쓰는 사고 차단. 모든 PVC는 `storageClassName` 명시.
- 단일 SSD라 디스크 분리는 **용량 격리 + 관측 분해능**(I/O는 물리적으로 공유). `node_filesystem_*{mountpoint=~"/mnt/disks/.*"}` 로 워크로드별 사용량 관측.
- 최근 데이터는 각 관측 컴포넌트 로컬 WAL(작음), truth는 **MinIO(S3)**로 → `miniodata`(유일하게 차오르는 디스크)가 관측 1순위.

---

## 플랫폼 구성요소

| 계층 | 구성요소 | 채널 | 역할 |
|---|---|---|---|
| CNI | **Calico** | install.sh (순환) | 파드 네트워크 (flannel 대체). NetworkPolicy 집행 주체 — 정책 객체를 노드 iptables 규칙으로 옮긴다 |
| LB | **MetalLB** | **GitOps** (wave -4) | 온프렘 LoadBalancer IP 할당 |
| Ingress | **Traefik** | **GitOps** (wave -2) | L7 라우팅 (번들 traefik 대체) — OTel 튜닝을 수동 upgrade 없이 |
| TLS | **cert-manager** | install.sh(차트) + **GitOps**(발급자·인증서) | Let's Encrypt 인증서 발급·갱신(DNS-01). 파드 3개 Running. ClusterIssuer 둘(`letsencrypt-staging`·`letsencrypt-prod`)과 Certificate `ticket-subinhong-dev`를 GitOps로 배달하고, 발급물은 Secret `ticket-tls`로 frontend Ingress가 쓴다 |
| 시크릿 | **sealed-secrets** | install.sh(컨트롤러, 순환) + GitOps(봉인본 배달) | 암호를 Git에 안전하게(암호문만) |
| 관측 CRD | **prometheus-operator-crds** | install.sh (CRD 예외) | ServiceMonitor/PodMonitor(Alloy가 소비, 오퍼레이터 없음) |
| 미들웨어 오퍼레이터 | **Strimzi** | install.sh (operator 예외) | Kafka CR 감시 |
| DB | **MySQL** | **GitOps** (wave -1, prune=false) | booking durable 저장 — 데이터 안전은 Retain PV가 커버(옛 "argocd 밖" 근거 폐기) |
| GitOps | **ArgoCD** | install.sh(helm) → **GitOps 자기관리** | 나머지 전부 선언·reconcile. 인수인계 완료 — 값 변경은 커밋으로만 |

**경계 기준** — 손으로 하는 것은 셋뿐이다(`install.sh` 8유닛).

```
순환      CNI · 시크릿 · argocd     자기가 자기를 배포할 수 없다
CRD       ServiceMonitor 등        객체보다 정의가 먼저 있어야 한다
operator  Strimzi                  CR 을 감시할 주체가 먼저 있어야 한다
```

나머지(metallb·traefik·mysql 포함)는 GitOps다. Traefik을 `install.sh`로 두면 수동 helm upgrade 때 순단이 난다.

---

## 미들웨어

- **Redis** ([cgv-redis](workloads/charts/data/cgv-redis)) — 큐 상태·좌석락·입장인증. dev = Sentinel HA(auth on).

  ```
  구성      동일 스펙 파드 3개인 단일 StatefulSet.  master/replica 가 별도 StatefulSet 이 아니다
            각 파드 안에 redis · sentinel · metrics 컨테이너가 함께 뜬다
  master    매니페스트가 아니라 sentinel 3개의 투표(quorum 2)가 정한다
  앱        sentinel-aware 라 master 승격이 앱까지 반영된다
            queue = NewFailoverClient · booking = redis-sentinel 프로파일
  접속      sentinel  redis.data.svc:26379
  ```
- **Kafka** ([Strimzi CR](workloads/manifests/kafka)) — queue ↔ booking 이벤트. 3브로커 RF3, 오퍼레이터가 CR을 실브로커로 만든다.

  ```
  admissions           입장
  admissions-revoked   회수
  bookings-completed   자리 반환
  admissions.DLT       소비 실패 격리
  보존 3일              kafkadata 30G 산정의 전제값이라 토픽에 명시한다
  ```
  토픽을 선언으로 소유하는 이유 — 선언이 없으면 앱이 붙을 때 브로커가 파티션 1로 만들고, 파티션은 줄일 수 없어 그 값이 굳는다.
  - DLT는 쿠버네티스 객체 이름에 대문자를 못 써서(RFC 1123) `metadata.name: admissions-dlt` · `spec.topicName: admissions.DLT`로 나눠 적는다. 앱이 쓰는 이름은 `topicName` 쪽이다.
  - **브로커 `resources`는 `KafkaNodePool` 소관**이다. `Kafka.spec.kafka.resources`는 v1 스키마에 없어 서버가 거부한다.
- **MySQL** — booking 확정 예매. 스키마 마이그레이션(Flyway)은 앱 코드 과제(#2), dev는 ddl-auto=update.
  - `auth.username: cgvapp` — booking이 접속하는 계정. 권한이 `cgv` 데이터베이스 안으로 한정돼, 그 파드가 침해돼도 다른 데이터베이스·사용자 관리·`SHUTDOWN`·`FILE`에 닿지 않는다.
    ⚠️ 이 칸에 `root`를 넣으면 컨테이너가 `root user is already created`로 기동을 거부한다 — 그 칸은 root와 별개인 "추가로 만들 일반 유저"다.
  - `podManagementPolicy: OrderedReady`를 명시한다. 차트 기본값이 빈 문자열로 렌더되는데 서버는 기본값으로 채워 저장해서, 명시하지 않으면 git과 live가 영원히 달라 `OutOfSync`로 남는다.
  - `ServerSideApply`는 쓰지 않는다. 이 차트는 `affinity: null`·`supplementalGroups: []` 같은 필드를 렌더에 남기는데 서버는 그런 필드를 저장하지 않아 SSA 비교에서 영구 `OutOfSync`가 된다. 일반 apply 비교는 null과 부재를 같게 본다.

---

## 관측 (LGTM + Alloy)

```
앱 방출                     Alloy(DaemonSet)          저장·조회
queue /metrics:9091 ┐
booking /actuator   ┼─ ServiceMonitor/PodMonitor ─▶ remote_write ─▶ Mimir(메트릭)
파드 stdout          ┼─ 로그 수집 ────────────────▶ push ────────▶ Loki(로그)
queue OTLP gRPC 4317 ┐
booking OTLP HTTP 4318┴─ (앱이 직접) ──────────────────────────▶ Tempo(트레이스)
                                                    ↑ S3 백엔드 = MinIO
                                          Grafana ─ 데이터소스(Mimir/Loki/Tempo)로 조회
```

- **Prometheus 오퍼레이터 없이** Alloy가 수집을 전담한다. 3파드 clustering으로 대상을 샤딩해 중복 수집을 막는다.
- 메트릭=**Mimir(distributed 10파드**, ingester 3·RF3 노드당 1 — 사용처 0건인 ruler·alertmanager·overrides_exporter는 끔), 로그=**Loki monolithic**, 트레이스=**Tempo monolithic**, 시각화=Grafana. 백엔드는 전부 **MinIO S3**.

**세 축은 서로 건너갈 수 있게 이어져 있다.** 지표에서 그 요청으로, 그 요청에서 그 로그로 간다.

| 방향 | 설정 | 실제로 하는 일 |
|---|---|---|
| 지표 → 트레이스 | Mimir `exemplarTraceIdDestinations` + `max_global_exemplars_per_user` | p99 그래프의 점을 누르면 그 요청의 트레이스가 열린다 |
| 트레이스 → 로그 | Tempo `tracesToLogsV2` (customQuery) | span 아래 버튼으로 그 트레이스가 남긴 로그만 본다 |
| 로그 → 트레이스 | Loki `derivedFields` (정규식) | 로그 줄의 trace ID를 눌러 되돌아간다 |

**이 배선은 끊겨도 증상이 없다.** 앱·지표·화면이 각각 정상으로 보이고 연결만 사라진다. 실제로 한 번 끊겼다.

```
증상   화면에 그 요청과 무관한 로그가 정상처럼 떴다
원인   ${__span.traceId} 가 Grafana 프로비저닝의 환경변수 치환에 먹혀 빈 문자열로 저장됐다
       ★ 파일에는 원문이 남아 있어 코드를 읽어서는 안 보인다
조치   리터럴 $ 는 $$ 로 escape
확인   파일이 아니라 저장된 값으로 — GET /api/datasources/uid/{tempo,loki}
```

**표본은 booking·queue 모두 1.0(전 요청)이고 프로브만 0이다.**

queue 폴링이 요청의 97%를 차지해 한동안 0.01로 두었다. 0.05로 올려 본 판에서 **exemplar 개수가 늘지 않았다** — 스크레이프(15초)마다 히스토그램 버킷당 하나가 한도라, 표본이 아니라 그 한도가 개수를 정한다.

느린 요청을 훑는 것은 exemplar가 아니라 Tempo 검색(TraceQL)이 한다. 그래서 표본을 1.0으로 올리고 Tempo 쪽 한도를 같이 올렸다.

```
max_traces_per_user   10,000 → 50,000
memory limit          1Gi → 3Gi
GOMEMLIMIT            800MiB → 2600MiB
확인                  tempo_discarded_spans_total{reason="live_traces_exceeded"}
```

⚠️ Tempo의 memory request는 256Mi 그대로다. 세 노드의 memory request 합이 allocatable의 85-91%라 올릴 자리가 없다. 실사용이 request를 크게 넘는 동안 이 파드가 노드 퇴거 1순위가 된다.

**Alloy가 긁는 대상 — 두 갈래다.**

| 갈래 | 대상 | 방식 |
|---|---|---|
| CRD 경유 | 앱(queue·booking) · kube-state-metrics · node-exporter · LGTM 각 컴포넌트 · Redis exporter | ServiceMonitor / PodMonitor 소비 |
| 직접 scrape | **k3s server**(`:10250/metrics`) · **cAdvisor**(`:10250/metrics/cadvisor`) · **MinIO 버킷 사용량** | `role=node` 발견 + 노드 주소 직접 지목 |

노드 프로세스는 대상을 가리킬 Service가 없다 — CRD 경로로는 원리적으로 못 잡는다. etcd(`:2381`)만 예외로, 셀렉터 없는 Service + 수동 Endpoints를 만들어 ServiceMonitor로 붙였다(`bootstrap/control-plane/`).

**노드 주소를 직접 지목하는 이유**는 기본 `kubernetes` Service가 살아 있는 apiserver만 엔드포인트로 유지하기 때문이다. 노드가 죽으면 대상 자체가 목록에서 빠져 `up=0`이 아니라 아예 없어진다 — "죽었다"를 표현하지 못한다. 고정 주소면 대상이 남아 `up=0`으로 나온다.

같은 이유로 **`up{job="k3s-server"}`가 노드 생존의 기준 신호**다. kube-state-metrics 기반 노드 상태는 apiserver·etcd를 통과하므로 쿼럼이 깨지면 값이 갱신을 멈춘 채 마지막 상태로 굳는다.

**`:6443`(apiserver)은 따로 긁지 않는다.** k3s는 apiserver·etcd·scheduler·controller-manager·kubelet을 한 프로세스로 돌려 메트릭 레지스트리가 하나다.

```
실측            :6443/metrics 와 :10250/metrics 가 같은 내용 —
                같은 노드에서 메트릭 이름 536개 전부 일치, 줄 수 동일
둘 다 긁으면     job 라벨만 다른 사본이 두 벌 저장돼 시리즈 상한을 두 배로 먹는다
:10250 을 남긴 이유
                apiserver 인증·flowcontrol 경로를 안 지나, apiserver 가 밀릴 때도 응답한다
                cAdvisor 가 같은 포트의 다른 경로다
```

- `job` 이름을 `kubelet`이 아니라 **`k3s-server`**로 둔 것은 이 레지스트리에 `apiserver_*`·`scheduler_*`·`workqueue_*`가 전부 들어 있어서다. 컴포넌트 구분은 `job`이 아니라 메트릭 이름이 한다.
- 컨트롤플레인이 프로세스로 나뉜 배포판(kubeadm 등)에서는 포트마다 내용이 달라 둘 다 긁는 것이 정상이다. **k3s에서만 사본이 된다.**

**로그는 두 갈래**다 — 파드 stdout과 **쿠버네티스 이벤트**(`job="k8s-events"`). 파드가 왜 죽었는지(OOMKilling·probe 실패·BackOff)는 stdout이 아니라 이벤트에 남고, 이벤트는 etcd에서 약 1시간 뒤 사라지므로 Loki에 적재해야 사후 추적이 된다.

### 시리즈 상한 — 300000

Mimir 기본값 150000으로는 이 클러스터의 수집량을 못 받는다. 상한에 걸리면 초과분이 `per_user_series_limit`으로 거절되어 그 신호가 아예 저장되지 않는다.

```
원천 실측    k3s server 3노드 약 12만-18만 · cAdvisor 약 1.7만
            KSM · node-exporter · LGTM 자기지표 약 3.2만
사본 제거 후  약 22만.  가동 시간에 따라 더 는다(verb × resource × scope 조합이 쌓임)
상한 300000  22만에 여유 36%.  25만은 여유 13%뿐이라 앱 3종이 붙으면 곧 다시 찬다
정착 1차     보유 182,397(61%) · 거절 0/s · ingester RSS 약 470-490MiB
버킷 컷 후   대시보드 사용 0건인 제어면 히스토그램 버킷 drop(전체의 52%)
            → 보유 약 8.1만(27%) · ingester RSS peak 422MiB(6시간) · request 512Mi로 재조정
```

- **상한은 천장이지 메모리 소비가 아니다.** ingester RAM은 상한값이 아니라 실제로 든 시리즈 수(`cortex_ingester_memory_series`)로 정해진다.
- RF3에 ingester도 3대라 **전역 상한이 곧 ingester 한 대가 지는 양**이다. 시리즈당 용량은 고정분이 섞인 평균이라 규모에 따라 변한다 — 초기 산정 4.2KiB는 18.5만 시점 재실측 2,820B로 폐기했고, `ingester`는 request 512Mi(실측 RSS peak + 여유)·limit 2Gi다.
- 앱 3종 투입 뒤 사용 0건인 제어면 버킷을 걷어내 보유가 절반 아래로 내려갔다. 상한 300000은 그대로 둔다 — 부하 때 앱 시리즈가 늘어도 여유가 크다.

### 대시보드 as-code

```
workloads/manifests/dashboards/  ─ ConfigMap(label: grafana_dashboard=1)
   └ argocd/applications/dashboards.yaml 이 배달 (prune·selfHeal on)
      └ grafana sidecar 가 파일로 떨어뜨림 → Grafana 가 읽음
```

- Grafana는 `persistence: false`다. 영속 저장소가 없으므로 **이 경로가 유일한 대시보드 공급원**이고, UI에서 손으로 만든 것은 재시작하면 사라진다. as-code를 강제하는 장치다.
- `prune: true`라 파일을 지우면 대시보드도 사라지고, `selfHeal: true`라 UI에서 손댄 것은 다음 sync에 되돌아간다. **정본은 git이다.**
- `sidecar.searchNamespace`를 릴리스 네임스페이스로 한정한다. `ALL`로 두면 전역 ConfigMap을 감시하느라 RBAC이 전 네임스페이스로 넓어진다.
- **현재 7장.** 아래가 위에서 아래로 좁혀 내려가는 순서다 — 하드웨어 → 클러스터 → 관측 자신 → 서비스 → 컴포넌트. 각 파일 머리 주석이 그 화면의 설계 근거와 "여기 없는 것과 이유"를 적는다.

  | 판 (uid) | 행 구성 | 답하는 질문 |
  |---|---|---|
  | **호스트 하드웨어**<br>`hypervisor-overview` | 지금 → 열 → 전력 → 포화 → 저장 | 노트북이 버티고 있나. 이 판만 pve 호스트를 본다 |
  | **클러스터 인프라**<br>`infra-cluster-overview` | 클러스터 → 노드 메모리 → 노드 CPU → 노드 디스크 → 파드 → 파드 스펙 장부 | 노드가 살아 있나, 어느 파드가 문제인가 |
  | **관측 파이프라인**<br>`observability-pipeline-detail` | 한눈 → 메트릭·로그·트레이스 각 축 → 수집 → 저장소 자원 → 깊이 파기 | 세 축이 다 흐르고 있나 |
  | **공개 서비스**<br>`app-public-service` | 밖에서 오는 것 → 안에서 쓰이는 것 → 시간축 겹치기 → 출처 | 인터넷에 열린 서비스가 제 노릇을 하나 |
  | **queue(traefik) 서비스**<br>`app-queue-detail` | traefik → queue → 실패 → 지연 → 자리의 수지 | 입장 전·대기 구간이 견디나 |
  | **booking 서비스**<br>`app-booking-detail` | booking 파드 → MySQL → 여정 | 입장한 사람이 표를 사기까지 |
  | **Redis · Kafka 공유 계층**<br>`app-redis-kafka` | Redis(인원 축) → Kafka(회전 축) → 원인 파기 | 두 앱이 공유하는 계층이 포화하나 |

- **앞의 셋은 인프라, 뒤의 넷은 서비스다.** 앞은 "이 기계가 도는가", 뒤는 "이 서비스가 되는가"를 묻는다. 부하를 걸었을 때 뒤가 무너지면 앞에서 원인을 찾는 순서로 쓴다.

---

## 보안

**되어 있는 것**

- **PodSecurity** — 위 [k3s 클러스터 아키텍처](#k3s-클러스터-아키텍처)의 ns별 표대로 집행한다. 호스트 접근이 필요한 node-exporter만 별도 ns로 격리해 나머지를 baseline 이상으로 유지한다.
- **네트워크 격리** — 클러스터가 물리 NIC 없는 브리지에 있어 밖으로 나가는 길이 OPNsense 하나다. 들어오는 문 둘, 나가는 규칙 넷, 엣지 우회 차단은 위 [네트워크](#네트워크)에 있다.
- **NetworkPolicy 24건 — 네 네임스페이스** ([netpol](workloads/manifests/netpol/) · [netpol-app](workloads/manifests/netpol-app/))
  ```
  app             10   기본 차단(ingress·egress) + 앱 3종의 인·아웃 + DNS + demo-reset
  data             5   MySQL 3306 · Redis 6379 · Kafka 9092(리스너 networkPolicyPeers)
  observability    5   들어오는 접속을 선언된 출처로 제한
  argocd           4   차트가 만드는 컴포넌트별 정책 — server · repo-server
                       · application-controller · redis
  ```
  기본 차단 위에 지정 출처만 여는 구조다. mysql·redis 차트가 만들던 넓은 정책(`allowExternal: true`라 `from` 절 없이 렌더)은 껐다 — NetworkPolicy는 겹치면 허용의 합집합이라, 넓은 쪽이 남아 있으면 좁은 정책을 더해도 좁아지지 않는다. 라벨 없는 파드에서 접속이 막히는 것을 차단 실증으로 확인했다.
  ⚠️ **세그먼테이션은 인증이 아니다.** 정책은 라벨로 상대를 가르므로, 그 라벨을 달 수 있는 쪽은 통과한다(라벨만 단 파드가 통과하는 것을 실측으로 확인). 신원 확인은 mTLS·SASL의 몫이고 지금은 없다.
- **공개 경로 앞단** ([public-guard](workloads/manifests/public-guard/))
  - `security-headers` — HSTS(3600초) · `nosniff` · `X-Frame-Options: DENY`를 Traefik 미들웨어로 붙인다.
  - `admin-api-deny` — 초기화 API(`/api/admin`·`/api/admission/reset`)를 **443에서만** 끊는다. 실제로 부르는 것은 클러스터 안의 CronJob 하나이고 그것은 Service를 직접 부르므로, 밖에서 살아 있을 이유가 없다. 80에는 걸지 않아 격리망 안에서 손으로 부르는 경로는 남는다.
- **관리 UI가 443에 없다** — 두 Ingress를 `web` 엔트리포인트에만 붙여 WireGuard 터널로만 닿게 했다. 엔트리포인트를 안 적으면 왜 443에 붙는지는 위 [네트워크](#네트워크)에 있다.
- **SealedSecret 17종** — 암호는 kubeseal로 봉인하고 암호문만 Git에 둔다([docs/시크릿-계약](docs/시크릿-계약.md)).
  ```
  data           mysql-secret · redis-secret
  observability  grafana-admin · grafana-discord-webhook · loki-s3-credentials
                 mimir-minio-credentials · minio-lgtm-user · minio-root-secret
                 tempo-s3-credentials
  app            booking-secrets · queue-secrets · gitlab-registry · app-admin-token
  argocd         argocd-repo-cgv-infra · argocd-secret · image-updater-registry
  cert-manager   cloudflare-api-token
  ```
  초기 10종은 `seal-secrets.sh`가 값 5개를 물어 일괄 생성하고, 나머지는 `seal-one.sh`로 낱개로 더했다. `argocd-secret`은 기존 Secret에 키만 얹는 `patch` 방식이고, `gitlab-registry`는 타입이 `dockerconfigjson`이라 만드는 명령이 다르다. `root-app.sh`가 봉인본 개수를 세어 부족하면 GitOps 인계를 막는다.
  - `cloudflare-api-token`은 cert-manager가 DNS-01 챌린지 레코드를 만드는 데 쓴다. 범위는 `subinhong.dev` 한 존의 `DNS:Edit`·`Zone:Read`뿐이고, OPNsense DDNS가 쓰는 토큰과 **값을 따로 발급**했다 — 한쪽이 새면 그것만 회수할 수 있게.
- **저장소 자격도 평문으로 두지 않는다** — GitLab deploy token은 ArgoCD가 저장소를 읽는 데 필요한데, 그 값을 Git에 넣으면 저장소를 읽을 자격이 저장소 안에 있게 된다. 다른 암호와 같은 경로(SealedSecret)로 배달한다.
- **etcd 저장 암호화**: `secrets-encryption: true` — 컨트롤러가 푼 Secret이 etcd에 평문으로 앉지 않게(외장 SSD 반출 대비).
- **RBAC 축소** — 차트 기본값이 SA에 전 네임스페이스 `secrets` 읽기를 붙인다.

  ```
  loki      룰 사이드카를 끈다
  alloy     기본 rules 에서 configmaps · secrets 를 뺀 목록을 명시한다
  사람      rbac/viewer.yaml 로 읽기 전용 ClusterRole — 상태 확인에 전권 kubeconfig 를 쓰지 않는다
  ```
- **TLS** — 인증서가 구간마다 다르다.

  ```
  방문자 → 엣지      Cloudflare 자기 인증서.  연결이 여기서 한 번 끊긴다
  엣지 → Traefik     Let's Encrypt.  SSL 모드 Full (strict) 로 엣지가 이것을 검증한다
  ```
  `Full`이면 브라우저는 못 보고 엣지는 안 봐서 아무도 검증하지 않는 구간이 생긴다. 최소 TLS 버전은 1.2다.
- **앱 SA 토큰 미마운트**: `automountServiceAccountToken: false`. queue·booking·frontend는 쿠버네티스 API를 쓰지 않아, 쓰지 않는 자격증명을 파드에 얹지 않는다.
- **kubelet 자원 예약** — `system-reserved`·`kube-reserved`·`eviction-hard`를 노드 실측값 기준으로 설정한다.

  k3s는 apiserver·etcd를 파드가 아니라 systemd 프로세스로 돌려, kubelet이 그 사용량을 allocatable에서 빼지 않는다. 예약이 없으면 워크로드가 제어면 메모리를 잠식한다. 같은 이유로 **PriorityClass로는 제어면을 보호할 수 없다** — 파드가 아니라서 evict 대상이 아니다.
  - `kube-reserved` **1Gi → 2Gi**

    ```
    파드 0개          645Mi
    App 18개 배포 후   k3s.service anon 이 노드별 1549-1783Mi
                     → 초기 1Gi 추정이 실제의 절반이라, 그만큼을 파드 몫에서 빼 쓰고 있었다
    반영             노드 3대 순차 재시작(2026-08-09) · allocatable 5081Mi 실측
    ```
  - `eviction-hard` **기본 목록을 통째로 교체한다**

    ```
    k3s 기본       nodefs 5% · imagefs 5% 둘뿐 — 메모리·inode 신호가 없다
                   메모리가 말라도 kubelet 이 개입하지 않고 곧장 커널 OOM 으로 간다
    신설           memory.available < 300Mi (약 7941Mi 의 3.8%)
    그 값인 근거    kubelet 확인 주기가 10초라, 선이 낮으면 JVM 같은 큰 할당이 그 사이를 뚫는다
    ```
- **이미지 nonroot**: queue distroless(65532)·booking(1001)·frontend nginx-unprivileged(101).

**아직 없는 것** (선언과 실물을 구분해 적는다)

- **ResourceQuota·LimitRange 0건** — 한 파드가 노드 메모리를 다 먹어도 ns 차원에서 막는 장치가 없다. 지금은 kubelet 예약과 파드별 limit이 방어선이다.
- **Kafka 무인증 평문**

  ```
  지금        type: internal 이 클러스터 밖 노출을 막고,
              리스너 networkPolicyPeers 가 9092 에 닿을 파드를 queue·booking 으로 좁힌다
  한계        그 라벨을 단 파드는 인증 없이 토픽을 읽고 쓴다.
              queue → booking 입장 이벤트가 곧 예매 권한이라, 라벨을 달 수 있으면 그 권한을 얻는다
  가려면      리스너에 authentication 을 켜고 KafkaUser CR 을 만들 userOperator 를 되살린다
  안 한 이유   발급할 자격증명이 0건이라 2026-08-15 에 내렸다
  ```
  ([kafka-cluster.yaml](workloads/manifests/kafka/kafka-cluster.yaml) 주석)
- **JDBC 평문** — `useSSL=false`가 앱의 URL에 리터럴로 있어 인프라에서 끌 수 없다. 바꾸려면 앱 이미지를 다시 구워야 한다.
- **etcd 메트릭 포트(:2381) 무인증** — 인증 없이 읽힌다. 노드가 격리망으로 옮겨져 닿을 수 있는 범위는 `10.0.0.0/24` 안으로 줄었지만, 그 안에서는 여전히 열려 있다(노드 방화벽 미설정).
- **공개 API에 인증·rate limit 없음** — 익명 접속을 받는 것이 이 서비스의 목적이라 접수 단계에서 거를 수 없다.

  rate limit을 안 넣은 이유는 재는 축이 달라서다.
  ```
  막고 싶은 것   한 출처가 여러 몫을 가져가는 것
  세는 것        출발지당 요청 수
  게다가         엣지 뒤에서는 출발지가 전부 엣지 주소로 뭉친다
  ```
  대신 좌석 오염은 주기 초기화(CronJob)가 받고 대량 트래픽은 엣지가 앞에서 받는다. 이 결정은 **엣지를 우회할 수 없다는 전제** 위에 서고, 그 전제는 OPNsense의 출발지 제한이 지킨다.
- **관리 UI에 다중 인증 없음** — Grafana·ArgoCD는 443에서 빠져 있고 WireGuard 터널로만 닿지만, 터널 안에서는 계정 비밀번호 하나가 방어선이다.
- **stg/prd 이미지 승격 경로 미구현** — dev는 CI가 만드는 불변 태그(`dev-<파이프라인번호>-<커밋해시>`) + image-updater write-back으로 전환 완료. stg/prd로 이미지를 올리는 경로는 아직 없다.
- **sealed-secrets 개인키 자동 백업 미구현** — 수동 반출 사본은 확보(2026-08-09). 재설치 절차에 반출 단계가 코드로 없어, 잊으면 Git의 봉인본 전체가 복호화 불가다.

---

## 저장소 구조 (실행 3계층)

폴더는 **① 누가·언제 적용하나 ② 제어 vs 대상**으로 가른다(Argo "config↔source 분리" + Flux/RedHat 공통 골격).

```
cgv-infra/
├── bootstrap/          ① 손으로 (argocd 뜰 때까지 — 순환·CRD·operator만, 9단계)
│   ├── cluster/            k3s 설치·조인(SSH): config.yaml · 01-server-init · 02-server-join
│   ├── install.sh          Calico→namespaces→storage→cert-manager→sealed-secrets→CRD→control-plane→Strimzi→argocd
│   ├── seal-secrets.sh     초기 봉인 — 값 5개를 물어 10종을 일괄 생성
│   ├── seal-one.sh         낱개 봉인 — 그 뒤에 하나가 더 필요할 때(이름·ns·라벨을 받는다)
│   ├── root-app.sh         GitOps 인계(별도 실행 — 봉인 선행을 강제하려고 install.sh와 분리)
│   ├── control-plane/      etcd 메트릭 수집 경로(셀렉터 없는 Service + 수동 Endpoints + ServiceMonitor)
│   ├── calico/ cert-manager/ sealed-secrets/ strimzi/ argocd/ storage/ namespaces/   매니페스트·values
│   └── root-app.yaml       app-of-apps 루트 → argocd/ 인계
├── argocd/             ② GitOps 배선 (제어면 — "무엇을·어디에·누가")
│   ├── projects/           bootstrap · argocd · apps · infra · secrets · cert  (AppProject = 울타리)
│   ├── applicationsets/    apps(directory) · observability(list) · platform(list)  (App 자동 생성기)
│   └── applications/       손으로 나열하는 16개 —
│                           argocd · argocd-image-updater · sealed-secrets · mysql · redis · kafka
│                           metallb-pool · dashboards · alerting · netpol · netpol-app · rbac
│                           cert-issuers · certificates · public-guard · reset-app
├── workloads/          ③ 배포 대상 (charts=정체성 / environments=환경값 / manifests=비-helm)
│   ├── charts/             apps/(cgv-app 틀 + queue·booking·frontend) · data/(cgv-mysql·cgv-redis 래퍼)
│   │                       · observability/(loki·mimir·tempo·grafana·alloy·minio·ksm·node-exporter) · platform/(metallb·traefik)
│   ├── environments/       dev(실물)·stg·prd(골격)
│   └── manifests/          비-helm 매니페스트 12 디렉터리 —
│                           kafka/          Strimzi CR (클러스터·노드풀·토픽 4종)
│                           metallb/        주소 풀 CR (10.0.0.240-250)
│                           secrets/        SealedSecret 17종
│                           dashboards/     Grafana 대시보드 ConfigMap 7장
│                           netpol/         data·observability 로 들어오는 접속 제한
│                           netpol-app/     app 네임스페이스 인·아웃
│                           rbac/           읽기 전용 ClusterRole
│                           alerting/       Grafana 알림 규칙·연락처
│                           cert-issuers/   Let's Encrypt ClusterIssuer 둘
│                           certificates/   Certificate (ticket.subinhong.dev)
│                           public-guard/   보안 헤더 · 초기화 API 443 차단 (Traefik 미들웨어)
│                           reset-app/      데모 데이터 주기 초기화 CronJob
└── docs/               시크릿-계약 · 코드-반영사항
```

**최상위 3폴더가 곧 배포 순서**: `bootstrap`(손) → `argocd`(배선) → `workloads`(대상).

`install.sh`와 `root-app.sh`가 나뉜 이유는 SealedSecret 봉인이 그 사이에 들어가야 해서다. 봉인은 sealed-secrets 컨트롤러가 떠야(install.sh 중반) 가능한데, 봉인 전에 GitOps 폭포가 시작되면 MySQL·Redis·MinIO·Grafana·LGTM이 시크릿을 못 찾아 일제히 실패한다. `root-app.sh`는 봉인본 개수를 세어 부족하면 멈춘다.

> 손으로 하는 구간의 전모 — 9단계가 각각 왜 GitOps가 아닌지, SealedSecret이 무엇이고 왜 별도 구간인지, 봉인에서 틀리기 쉬운 세 지점 — 은 [`bootstrap/README.md`](bootstrap/README.md)에 있다.

---

## GitOps 원본 — GitLab

```
push ─▶ GitLab (데스크탑 192.168.0.167:8929, cgv/cgv-infra) ─ 폴링 3분 ─▶ ArgoCD ─▶ 클러스터
             └─ push 미러 ─▶ GitHub (공개 사본)
```

- **모든 Application의 `repoURL`이 GitLab을 가리킨다.** GitHub는 읽히지 않는 공개 사본이고, GitLab이 배포 상태를 정의한다.
- **자격 = deploy token**(`read_repository`, 무만료). 저장소가 private이라 ArgoCD가 자격 없이는 못 읽는데, 그 자격도 Git에 평문으로 둘 수 없다 — SealedSecret으로 봉인해 `argocd` 네임스페이스로 배달한다(`argocd-repo-cgv-infra`). ArgoCD는 `argocd.argoproj.io/secret-type: repository` 라벨이 붙은 Secret을 저장소 자격으로 인식한다.
- **브랜치는 `main` 하나.** 환경 분리는 이미 `workloads/environments/` 디렉터리가 하므로 브랜치를 환경 축으로 쓰면 축이 둘이 된다. 브랜치는 변경 흐름용(작업 브랜치 → MR → main)이고, `main`은 push 금지·MR만 허용이다.

### AppProject — Application이 할 수 있는 일의 범위

Application 하나는 반드시 프로젝트 하나에 속하고, 그 프로젝트가 반경을 정한다. 지정하지 않으면 `default`(네 축 전부 `*`)로 떨어지므로 전부 명시한다.

| 프로젝트 | 무엇의 울타리 | 허용 저장소 | 네임스페이스 | 만들 수 있는 것 |
|---|---|---|---|---|
| `bootstrap` | root Application | GitLab | `argocd` | `argoproj.io`의 AppProject·Application·ApplicationSet만. **cluster 범위 0** |
| `argocd` | ArgoCD 자신 | GitLab + argo-helm | `argocd` | 전부 — 차트가 CRD·ClusterRole·ClusterRoleBinding을 만든다 |
| `apps` | queue·booking·frontend | GitLab | `app` | ns 범위 전부 |
| `infra` | 플랫폼·관측·미들웨어 | GitLab + 업스트림 차트 6 | `data`·`observability` 등 5 | 전부 |
| `secrets` | SealedSecret 배달 | GitLab | `data`·`app`·`observability`·`argocd`·`cert-manager` | **`SealedSecret`만** |
| `cert` | 인증서 발급자 배달 | GitLab | `cert-manager` | **`ClusterIssuer`만**. 네임스페이스 리소스는 0 |

- **갈린 기준은 네임스페이스가 아니라 "무엇을 하는 App인가"다.** `secrets`가 그 예다 — 네 네임스페이스에 들어가지만 만들 수 있는 것은 `SealedSecret` 하나뿐이라, 그 App이 읽는 디렉터리에 `Deployment`가 섞여도 거부된다.
- `bootstrap`이 좁은 이유는 `root`가 만드는 것이 선언뿐이어서다. 워크로드는 그 선언이 만든 App들이 각자의 프로젝트 안에서 만든다. `root`를 `default`에 두면 저장소에 커밋할 수 있는 쪽이 클러스터에 무엇이든 만들 수 있게 된다.
- `apps`가 업스트림 저장소를 안 여는 것도 같은 축이다. 앱 차트는 이 저장소 안에 있으므로 외부에서 받을 일이 없다.

### ArgoCD가 자기를 관리한다

`argo-cd` 차트는 `install.sh`가 `helm install`로 처음 넣는다 — 클러스터가 비어 있을 때는 배포할 주체가 없다. 그 뒤 `argocd` Application이 같은 리소스를 이어받아, 값 변경이 `helm upgrade`가 아니라 `bootstrap/argocd/values.yaml` 커밋으로 흐른다.

```yaml
sources:
  - repoURL: https://argoproj.github.io/argo-helm   # 차트
    chart: argo-cd
    targetRevision: 10.1.4                          # 설치된 버전과 같게
    helm: { valueFiles: [ $values/bootstrap/argocd/values.yaml ] }
  - repoURL: <GitLab>                               # 값
    ref: values                                     # 이 소스는 배포되지 않는다
syncPolicy:
  automated: { prune: false, selfHeal: false }
```

- `targetRevision`이 설치된 것과 다르면 이 App이 처음 sync하는 순간 ArgoCD가 자기를 업그레이드하며 재시작한다.
- **`prune: false`** — 이 파일이 사라졌을 때 제어면이 자기 리소스를 지우면 되살릴 주체가 없다.
- **`selfHeal: false`** — sync가 `argocd-server`·`application-controller`를 재시작시키고, 그 재시작이 다시 sync를 부르는 순환에 들어갈 수 있다. 대신 클러스터 쪽 drift 교정은 못 얻고, 어긋나면 `OutOfSync`로 드러나는 것까지만 남는다.
- 인수인계 뒤에는 helm release 기록(`sh.helm.release.v1.argocd.*`)을 지운다. ArgoCD의 Helm 지원은 `helm template` 방식이라 release를 만들지 않는데, 옛 기록이 남아 있으면 `helm uninstall argocd` 한 번에 관리 중인 리소스가 통째로 사라진다.

---

## 처음부터 세우는 절차

```
① cluster/ 스크립트 (SSH, 노드에서)   → k3s 3노드 조인 (CNI 없어 NotReady)
② bootstrap/install.sh (9단계)        → Calico(→Ready)→namespaces→storage→cert-manager→sealed-secrets
                                          →CRD→control-plane 수집→Strimzi→argocd
③ SealedSecret 15종 봉인·커밋·push     → 컨트롤러가 뜬 뒤에만 가능. 여기서 손이 한 번 더 들어간다
                                          그중 ArgoCD 저장소 자격 한 장은 apply까지 (없으면 ⑤ 이후가 안 돈다)
④ bootstrap/root-app.sh               → 봉인본 개수 확인 후 root-app apply. 여기서 손 끝
⑤ root-app → argocd/ recurse          → AppProject·ApplicationSet·Application 생성
⑥ ApplicationSet → 플랫폼/앱/관측 Application 자동 생성 · Application이 workloads/ 가리킴
⑦ argocd가 렌더·배포 → CGV 서비스 기동
     ※ argocd는 traefik(GitOps) 뜨기 전엔 ingress 없음 → 초기 접근 port-forward
       traefik이 뜬 뒤 argocd.cgv.lan · grafana.cgv.lan
       두 이름은 접근하는 기기의 hosts 또는 DNS가 traefik 주소로 풀어줘야 한다
```

직접 실행하는 건 `cluster/` 스크립트 · `install.sh` · `root-app.sh` 셋이고, 그 사이에 봉인 작업이 낀다. 나머지는 argocd가 GitOps로 처리한다.

> ⚠️ **sync-wave는 App 간 실행 순서를 강제하지 않는다.** wave가 만드는 것은 root sync 안에서의
> *리소스 생성 순서*(약 2초 간격)뿐이고, ApplicationSet이 만드는 App(metallb·traefik·MinIO·LGTM·앱)은
> 그 sync에 속하지 않아 wave 값이 실효가 없다. 실제 동작은 **전 App이 거의 동시에 생성되어 병렬 sync**이고,
> 의존이 안 뜬 사이의 crashloop는 selfHeal로 수렴한다(초기 red는 정상).
> 그래서 "관측 먼저 → 확인 → 앱"을 sync-wave로 강제할 수는 없다. 앱 3종은 이미지 공급 경로
> (CI 러너 + 레지스트리)가 생긴 뒤에야 뜬다 — 재구축 시에도 그 경로가 서기 전까지는
> 관측·미들웨어만 수렴하고 앱은 `ImagePullBackOff`로 남는 것이 정상이다.

---

## 여기까지 밟은 단계

| | 단계 | 상태 |
|---|---|---|
| 1 | **Proxmox** 설치(외장 SSD) + VM 3개 + 용도별 LV + 네트워크(vmbr) | ✅ 완료 |
| 2 | 각 노드 OS prep(정적 IP·SSH키·**데이터 디스크 10장 mkfs + `/mnt/disks/<용도>` 마운트·fstab**·[cluster/README](bootstrap/cluster/README.md)) | ✅ 완료 (재부팅 검증 통과) |
| 3 | `cluster/01-server-init.sh`(k3s-1) → `02-server-join.sh`(k3s-2·3) | ✅ 완료 (v1.36.2, etcd 3-member, CNI 전이라 NotReady) |
| 4 | `bootstrap/install.sh` — Calico부터 argocd까지. 여기까지는 몇 번을 다시 돌려도 안전하다(전부 멱등) | ✅ 완료 |
| 5 | **SealedSecret 봉인·커밋·push**([secrets/README](workloads/manifests/secrets/README.md)) — sealed-secrets 컨트롤러가 뜬 뒤에만 가능. 초기 10종 + 나중에 더한 저장소 자격·webhook 비밀·이미지 pull 자격·image-updater 폴링 자격·초기화 API 토큰 = 15종 | ✅ 완료 |
| 6 | `bootstrap/root-app.sh` → GitOps 인계. 봉인본이 부족하면 여기서 멈춘다 | ✅ 완료 |
| 7 | `kubectl -n argocd get applications -w` 로 sync 확인 | ✅ 완료 (플랫폼·관측·미들웨어 수렴. 자원값은 실측으로 재조정) |
| 8 | **GitOps 원본을 GitLab으로** — 저장소 이전 · deploy token 봉인 · `repoURL` 전환 · AppProject 울타리 | ✅ 완료 |
| 9 | **ArgoCD self-managed 인수인계** — `argocd` Application이 helm이 만든 리소스를 이어받음 | ✅ 완료 |
| 10 | **이미지 공급 경로**(CI 러너 + 레지스트리) → 앱 3종 기동 | ✅ 완료 (CI 5단 게이트 → 불변 태그 push → image-updater가 태그를 Git에 write-back → 자동 롤아웃. 앱 3종 Running) |
| 11 | **부하 실측** — 앱 지표 배선 · 판 21회로 requests·limits·정원을 추정값에서 실측값으로 | ✅ 완료 |
| 12 | **격리망 이전** — `vmbr1` 신설 · OPNsense VM · 노드를 `10.0.0.11-13`으로 · MetalLB 풀 `10.0.0.240-250` | ✅ 완료 (재구축. `tls-san`이 양쪽 대역을 담고 있어 API 인증서는 유지) |
| 13 | **클러스터 내부 보안** — NetworkPolicy를 `app`·`observability`로 확장 · API 서버 권한 축소 · 읽기 전용 자격 | ✅ 완료 |
| 14 | **인터넷 공개** — 도메인·DNS·DDNS · cert-manager 되살림 · Let's Encrypt 인증서 · 보안 헤더 · 관리 UI를 443에서 제외 · 초기화 API 차단 · CDN 프록시 · 공유기·OPNsense의 443 | ✅ 완료 (`https://ticket.subinhong.dev`) |
| 15 | **공개 서비스 감시** — 공개 서비스 판 · 알림 · 데모 데이터 주기 초기화 CronJob · 호스트 하드웨어 판 | ✅ 완료 |
| 16 | **공개 경로 부하 실측** — 엣지·공유기·OPNsense를 지나는 경로에서 판 13회. 스펙 재확정 | ✅ 완료 |

**실행 위치는 노드로 한정되지 않는다.** `kubectl`·`helm`이 있고 클러스터에 닿으면 어디서든 된다 — 두 도구는 API 서버로 HTTPS 요청을 보낼 뿐이다.

```
kubeconfig 탐색   $KUBECONFIG → /etc/rancher/k3s/k3s.yaml → ~/.kube/config
                  셋 다 없으면 무엇이 필요한지 알리고 멈춘다
시작 전 검사       kubectl · helm · kubeconfig 접근 · 클러스터 응답
                  중간에 죽어 부분 적용 상태가 남는 것을 막는다
```

**4번(install.sh)과 5번(봉인) 사이에 손이 한 번 더 들어가는 것이 설계다.** `kubeseal`은 sealed-secrets 컨트롤러(install.sh 5단계)가 떠야 공개키를 얻으므로, 봉인은 install.sh가 끝난 뒤에만 가능하다. 그래서 GitOps 인계를 `root-app.sh`로 분리했고, 그 스크립트가 봉인본 개수를 세어 부족하면 인계를 막는다.

> **파일은 `git clone`으로 가져간다.** Windows 작업트리는 `core.autocrlf`로 CRLF를 가질 수 있고, 그 트리에서 scp로 직접 복사하면 셸이 `$'do\r'` 같은 문법 오류로 죽는다. `.gitattributes`가 저장소 안 내용을 LF로 고정하므로 clone/pull로 받으면 그 문제가 없다.
> `install.sh`는 `bootstrap/` 트리 전체(calico·namespaces·storage·control-plane·각 values·root-app.yaml)를 상대경로로 읽는다 — 스크립트 한 파일만 옮기면 안 된다.

---

## 관련

- 앱 코드: [cgv-onprem](https://github.com/sss654654/cgv-onprem)
  - **queue** (Go) — 대기열. 순서대로 줄 세우고 정원만큼만 입장시킨다. 입장 이벤트를 Kafka로 발행.
  - **booking** (Java/Spring) — 예매. 입장 인증을 확인하고 좌석을 중복 없이 확정한다.
  - **frontend** (nginx + 정적 SPA) — 대기 화면·좌석 선택 화면.

---

## 만든 과정 — 편별 기록

노트북 한 대를 열어 이 클러스터를 세우기까지를 편별로 남겼다. 각 편은 **그 단계에서 실제로 한 작업**과 **그때 짚은 개념**을 함께 적는다 — 아래 표에서 필요한 편으로 바로 들어갈 수 있다. (전체 목록: [블로그 HomeLab 카테고리](https://zed6740.tistory.com/category/HomeLab))

| 편 | 한 작업 | 다룬 개념 |
|:--|:--|:--|
| **[1부](https://zed6740.tistory.com/209)**<br>왜 k3s, 왜 Proxmox | 쓰던 노트북(RAM 32GB)을 서버로<br>배포판 k3s — 번들은 전부 교체<br>하이퍼바이저 Proxmox VE<br>외장 USB SSD에 설치 | k3s vs 표준 k8s<br>etcd 쿼럼이 홀수 최소 3인 이유<br>Type 1 / Type 2 하이퍼바이저<br>Hyper-V도 Type 1이다 |
| **[2부](https://zed6740.tistory.com/210)**<br>usb 굽기 및 홈 네트워크 분석 | Rufus **DD 모드**로 설치 USB<br>유선 I219-V를 브리지 다리로<br>선을 뽑아가며 집 배선 지도 작성<br>모뎀 빈 포트에 공유기 → "내 골목" | ISO vs DD 모드<br>`vmbr0`에 물리 NIC이 필요한 이유<br>WiFi 위에 브리지를 못 얹는 이유<br>공인 IP와 사설 IP<br>NAT 장부와 포트포워딩 |
| **[3부](https://zed6740.tistory.com/211)**<br>내 골목 개통, 그리고 Proxmox 설치 | 공유기를 모뎀에 WAN으로 물림<br>DHCP 범위를 `.2–.199`로 축소<br>외장 `/dev/sda`에 Proxmox 9.2<br>`192.168.0.200` · 웹UI `:8006` | DHCP 범위와 고정 IP 충돌<br>ping 100% 손실의 두 원인<br>부트 메뉴 장치 식별(`ASMT 2115`)<br>ext4 → LVM + LVM-thin 자동 구성 |
| **[4부](https://zed6740.tistory.com/212)**<br>Proxmox 설치 직후 설정 | 유료 리포 → no-subscription<br>`full-upgrade` 94개(커널 교체)<br>뚜껑 스위치·절전 타깃 `mask`<br>`usbcore.autosuspend=-1`<br>chrony · microcode · `swappiness=10` | deb822 `.sources` 형식<br>`full-upgrade` vs `upgrade`<br>`mask` vs `disable`<br>커널 버전으로 재부팅 발효를 검증<br>강제 종료가 위험한 이유 |
| **[5부](https://zed6740.tistory.com/213)**<br>노드(VM) 구축 | VM 3대 — 4 vCPU / 8GB / 40GB<br>`virtio-scsi-single` · discard · iothread<br>`cpu: host` · **ballooning 해제**<br>Ubuntu 24.04 · 고정 IP `.201–.203`<br>SSH 키 · `qemu-guest-agent` | QEMU와 KVM의 분담<br>실물 재현 vs VirtIO<br>Discard/TRIM과 thin 풀 고갈<br>캐시 모드가 etcd 커밋 보장을 깨는 곳<br>ballooning을 끄는 이유 |
| **[6부](https://zed6740.tistory.com/214)**<br>데이터 디스크와 k3s 클러스터 | 데이터 디스크 10장 → mkfs → fstab<br>`config.yaml` — flannel none · `tls-san`<br>k3s v1.36.2 3노드 조인<br>kubeconfig 확보 | 디스크가 파드에 닿는 여섯 마디<br>정적 PV를 고른 근거<br>관측 분해능이 절단 단위로 결정됨<br>클러스터 접근 3단계(TLS·인증·인가)<br>kubeconfig 세 조각 |
| **[7부](https://zed6740.tistory.com/215)**<br>플랫폼 부트스트랩 | kubelet 자원 예약 3줄<br>`install.sh` 9단계 완주<br>SealedSecret 10종 봉인<br>`root-app.sh`로 GitOps 인계<br>MetalLB → Traefik `.240` · 파드 69개 | `allocatable = Capacity − 예약 − eviction`<br>requests vs limits — 뭐가 cgroup에 걸리나<br>손에 남길 것의 기준 셋<br>PodSecurity 3수준과 restricted 4줄<br>비대칭 키 봉인 · 개인키 분실의 의미 |
| **[8부](https://zed6740.tistory.com/217)**<br>관측 파이프라인 | 사본 진단 — `:6443` = `:10250` 179,225줄<br>apiserver scrape 제거 · `job=k3s-server`<br>시리즈 상한 150k → 300k · ingester 2Gi<br>3축 12패널 대시보드 as-code<br>자원값 3건 교정(전부 `exit 137`) | 스크레이프 · 시리즈 · 카디널리티<br>Mimir 쓰기 / 읽기 경로<br>인제스터만 HA가 필요한 이유<br>head 절단 vs 블록 생성<br>상한 포화와 OOMKilled의 감별<br>실패 카운터 ≠ 고장 |
| **[9부](https://zed6740.tistory.com/218)**<br>GitLab 세우기 | GitLab CE 기동 — 최소 4GB를 2.7GiB로<br>저장소 이전 · GitHub push 미러<br>보호 브랜치 · 스쿼시 + FF<br>deploy token 봉인 · `repoURL` 전환<br>AppProject 울타리 · ArgoCD self-managed | push형 vs pull형 CD<br>webhook은 설정 이전에 네트워크 문제<br>GitLab 부품 9개와 요청의 길<br>머지 3요소 — Merge commit · FF · 스쿼시<br>기계 자격 5종<br>부트스트랩 순환 |
| **[10부](https://zed6740.tistory.com/221)**<br>CI 와 CD | 그룹 러너(docker executor) · Container Registry<br>5단 파이프라인 — check·test·build·scan·publish<br>불변 태그 `dev-<파이프라인>-<커밋>`<br>노드 `registries.yaml` · image-updater write-back<br>캐시 정비 — 파이프라인 6:06 → 0:46 | CI 게이트와 빈 단계의 값<br>불변 태그 vs latest — 무엇이 롤백을 만드나<br>러너 캐시 3층(볼륨·레이어·BuildKit)<br>write-back이 GitOps 정본을 지키는 방식 |
| **[11부](https://zed6740.tistory.com/222)**<br>앱 검증과 시뮬레이터 | 앱 흐름 문서화 · E2E 전 분기 검증<br>프론트를 대기열 시뮬레이터로 재작성<br>정원·좌석 테스트 → CI test 게이트<br>NetworkPolicy — 기본 차단 + 지정 출처<br>`ADMIN_TOKEN` 초기화 API | 폴링 대기열의 상태 전이<br>API 계약을 게이트로 남기는 조건<br>NetworkPolicy는 겹치면 허용의 합집합<br>라벨 셀렉터가 못 막는 것 |
| **[13-1부](https://zed6740.tistory.com/226)**<br>네트워크 격리 | 공개 전 구성의 공백 점검<br>OPNsense VM · `vmbr1` 격리망<br>노드 3대를 `10.0.0.11-13`으로 이전<br>WireGuard 관리 터널 · 임시 통로 폐쇄<br>도메인 구입 · DDNS로 공인 IP 추적 | 물리 NIC 유무가 격리를 만든다<br>NAT 두 겹과 목적지 변환<br>캡슐화 — 패킷을 패킷에 넣는다<br>출발지 주소 대신 공개키 서명<br>이전이 드러낸 옛 주소들 |
| **[13-2부](https://zed6740.tistory.com/228)**<br>클러스터 내부 보안과 감시 | NetworkPolicy — app 인·아웃 · observability<br>API 서버 권한을 실제 사용 범위로<br>읽기 전용 자격 신설<br>booking의 MySQL 계정을 전용 계정으로<br>Redis 계측이 명령 인자를 안 싣게<br>하이퍼바이저 판 · 알림 · 야간 스케줄 | 정책이 판정하는 방식<br>세그먼테이션과 인증은 다른 층<br>누가 무엇을 할 수 있나를 세는 법<br>node-exporter가 재는 층 |
| **[13-3부](https://zed6740.tistory.com/229)**<br>외부 공개와 실서비스 스펙 | 도메인·TLS·Ingress·보안 헤더<br>CDN 프록시 · 공유기·OPNsense의 443<br>밖에서 공개 표면 점검<br>부하 판 13회 — 병목이 여덟 번 옮겨감<br>정원·타임아웃·풀·자원 확정 | 인증서·CA·서명이 각각 하는 일<br>DNS-01 — 포트를 열기 전에 받는다<br>엣지 프록시와 origin의 갈림<br>회전 = 정원 ÷ 체류<br>캐시 스탬피드와 single-flight |
| [번외](https://zed6740.tistory.com/216)<br>e1000e NIC hang | 반씩 좁히기로 업링크 구간 특정<br>`dmesg` — `Hardware Unit Hang` 34회<br>오프로드 off로 복구<br>udev 불발 규명 → `post-up`으로 교체 | carrier(링크) ≠ 데이터 흐름<br>ARP `FAILED`가 뜻하는 것<br>TSO/GSO/GRO와 Intel e1000e 결함<br>장치 개명이 udev 발화를 가름<br>검증의 층위 셋 |
| [번외](https://zed6740.tistory.com/219)<br>WSL2와 커밋 한도 | 죽는 순간 기록 — `exit 137` · `0xc00000fd`<br>물리 여유 6.6GB → 물리 부족 가설 폐기<br>페이지파일 재설정 — 한도 17.9 → 28.0GB<br>`PeakUsage 1MB` → 램 증설 취소 | Windows 커밋 한도 vs 리눅스 오버커밋<br>`Vmmem`이 대표하는 것<br>`free -h`에서 봐야 할 칸<br>`exit 137`이 알려주지 않는 것<br>페이지파일의 역할 둘 |
| [번외](https://zed6740.tistory.com/220)<br>CI 파이프라인 14판의 기록 | 5단 게이트가 굳기까지 판 14번<br>check 게이트 넷 · trivy 2단 스캔<br>러너·Dockerfile의 파일 밖 짝 정리 | 게이트 유예(allow_failure)를 걷는 순서<br>비어 있는 test 칸이 말하는 것<br>캐시 3층이 각각 자르는 시간 |
| [번외](https://zed6740.tistory.com/223)<br>내가 세운 카프카를 읽는다 | 요청이 사라지는 지점에서 출발<br>오프셋 → 토픽 → 파티션 → RF·리더<br>컨슈머 그룹까지 실물 CR과 대조 | 읽고 지우지 않는 큐<br>파티션 — 순서가 보장되는 단위<br>RF3와 리더 선출이 지키는 것 |
| [번외](https://zed6740.tistory.com/224)<br>노드 메모리와 쿠버네티스 메모리 | 리눅스 → cgroup → 쿠버네티스 세 층<br>같은 노드의 "여유"를 층별로 다시 읽기<br>클러스터 대시보드 메모리 행 설계 | 커널이 도로 가져갈 수 있는 메모리<br>cgroup 상한이 노드 물리보다 먼저 온다<br>allocatable과 예약<br>같은 기준 안에서만 뺀다 |
| [번외](https://zed6740.tistory.com/225)<br>컨테이너 메모리와 런타임 메모리 | 힙·스택 → 런타임 → RSS → GC<br>Go(GOGC·GOMEMLIMIT)와 JVM(-Xmx)을 나란히<br>컨테이너 limit과 런타임 상한의 짝 | 런타임이 커널에서 가져와 쥐는 것<br>RSS가 세는 것과 안 세는 것<br>GC 목표·밸러스트<br>limit만 있고 런타임 상한이 없을 때 |
| [번외](https://zed6740.tistory.com/227)<br>쿠버네티스의 인증과 인가 | kubeconfig 세 조각을 열어 본다<br>인증서의 이름·그룹·서명을 대조<br>규칙 묶음과 연결을 따라가 권한을 센다<br>ServiceAccount 토큰이 실리는 자리 | 모든 요청이 API 서버 하나로 간다<br>키 쌍과 서명 · CA가 보증하는 것<br>인가 — 이름에는 힘이 없다<br>파드의 신원 |
