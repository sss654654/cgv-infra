# cgv-infra — CGV 온프렘 k3s 인프라 (GitOps)

CGV 티켓팅 폴리글랏 MSA([cgv-onprem](https://github.com/sss654654/cgv-onprem): queue·booking·frontend)를 온프레미스 k3s 클러스터에 GitOps로 배포·운영하는 인프라 코드. 물리 노드부터 CNI·LB·Ingress·스토리지·관측·미들웨어·시크릿까지 직접 구성한다.

이 repo로 노드 프로비저닝부터 CGV 서비스 기동까지 재현한다: 노드 프로비저닝 스크립트(`bootstrap/cluster/`) → 플랫폼 부트스트랩(`bootstrap/install.sh`) → GitOps 선언(`argocd/` + `workloads/`).

---

## 목적

티켓팅(생중계 좌석 예매) 대기열 처리 MSA를 온프렘 환경에서 운영한다. 클라우드 매니지드(EKS·RDS·ELB·S3)가 대신 제공하는 CNI, 로드밸런서, Ingress 컨트롤러, 스토리지 프로비저닝, etcd 쿼럼, 시크릿 관리를 직접 구성하고 GitOps로 선언·자동화한다.

---

## 실행 스택 — 물리 → 가상 → 클러스터

```
┌─────────────────────────────────────────────────────────────┐
│  노트북 (31.3GB RAM) — 전원·호스트                           │
│  └─ 외장 USB SSD                                             │
│     └─ Proxmox VE (하이퍼바이저, 부팅 디스크)               │
│        ├─ VM: k3s-1  (4 vCPU / 8GB)   ┐                      │
│        ├─ VM: k3s-2  (4 vCPU / 8GB)   ├ k3s 클러스터        │
│        ├─ VM: k3s-3  (4 vCPU / 8GB)   ┘                      │
│        └─ VM: OPNsense (문지기 — 라우터·방화벽·VPN, Phase2) │
└─────────────────────────────────────────────────────────────┘
      데스크탑(별도) = GitLab(git·CI·레지스트리) + 부하생성기
```

- **하이퍼바이저 = Proxmox VE**, 외장 SSD에 설치(노트북 부팅 디스크와 분리).
- **k3s 노드 3 = VM**, 각 4 vCPU / 8GB / 40GB 부팅 + 용도별 LV(아래 스토리지).
- **OPNsense = 별도 VM**(k3s 노드 아님) — 외부노출 단계(Phase2)의 라우터·방화벽·VPN.
- **GitLab·부하생성기 = 데스크탑**(클러스터 밖, 예산 0). 이미지 흐름 = 데스크탑 GitLab CI 빌드 → 레지스트리 → k3s가 LAN으로 pull.

---

## k3s 클러스터 아키텍처

```
                        ┌──────────── Ingress (Traefik) ──────────┐
   외부/브라우저 ──▶ MetalLB LB IP ──▶ /api/admission→queue           │
                                     /api→booking · /→frontend        │
                        └──────────────────────────────────────────┘
   ┌───────────────────────────────────────────────────────────────┐
   │  k3s 클러스터 — 3 server 노드 (all control-plane + worker)     │
   │                                                                 │
   │   k3s-1 (db)          k3s-2 (obs)          k3s-3 (obj)          │
   │   ├ etcd ┐            ├ etcd ┼─ 쿼럼 3 ─┤  ├ etcd ┘             │
   │   ├ MySQL             ├ LGTM(loki/mimir  ├ MinIO(S3 백엔드)     │
   │   ├ Kafka broker      │      /tempo/graf) ├ Kafka broker        │
   │   └ Kafka broker      └ Kafka broker      └ ArgoCD              │
   │        └─ 앱(queue·booking·frontend)·Redis·Allo/ne/ksm = float │
   │                                                                 │
   │   CNI=Calico  ·  LB=MetalLB  ·  Ingress=Traefik  (번들 전부 교체)│
   │   네임스페이스: app · data · observability · argocd            │
   └───────────────────────────────────────────────────────────────┘
```

- **3노드 전부 k3s `server`**(control-plane+worker) → embedded **etcd 쿼럼 3**. 노드 하나 죽어도 쿼럼 2 유지(HA). 워커 전용 노드 없음.
- **k3s 번들 컴포넌트 전부 교체**: `flannel-backend: none`→**Calico**(NetworkPolicy), `servicelb` disable→**MetalLB**, `traefik` disable→**자체 Traefik**. (`bootstrap/cluster/config.yaml`)
- **4 네임스페이스** = RBAC·NetworkPolicy·ResourceQuota 경계: `app`(우리 앱, restricted PSA) · `data`(Redis/Kafka/MySQL, restricted) · `observability`(LGTM, privileged — node-exporter/alloy 호스트 접근) · `argocd`.

---

## 노드별 구성

| 노드 | 스펙 | 라벨 | 용도별 LV | 핀된 stateful | 비고 |
|---|---|---|---|---|---|
| **k3s-1** | 4vCPU/8GB | `cgv.io/data=db` | mysqldata 20G · kafkadata 30G | **MySQL** | etcd·CP · Kafka broker |
| **k3s-2** | 4vCPU/8GB | `cgv.io/data=obs` | lgtmdata 30G · kafkadata 30G | **LGTM(loki/mimir/tempo/grafana)** | etcd·CP · Kafka broker |
| **k3s-3** | 4vCPU/8GB | `cgv.io/data=obj` | miniodata 100G · kafkadata 30G | **MinIO** · ArgoCD | etcd·CP · Kafka broker |

- **stateful 싱글턴은 nodeSelector로 핀** — 전용 LV가 그 노드에 있어서: MySQL→`db`, LGTM→`obs`, MinIO→`obj`. (miniodata가 100G인 건 MinIO가 LGTM의 S3 데이터 몸통이기 때문.)
- **Kafka 3브로커 = podAntiAffinity로 노드 분산**(각 노드 kafkadata LV 사용, RF3 성립).
- **앱(queue/booking/frontend)·Redis·수집기(Alloy/node-exporter/ksm) = float**(stateless라 스케줄러가 RAM 균형으로 배치). topologySpreadConstraints로 replica는 노드에 흩뿌림.

---

## 네트워크

```
Phase1 (walking-skeleton)          Phase2 (외부노출)
 vmbr0 직결                          WAN=vmbr0 ─ OPNsense ─ LAN=vmbr1
 노드 172.30.1.201-203               노드 10.0.0.11-13
 MetalLB LB 172.30.1.240-250         (OPNsense가 라우팅·방화벽·WireGuard VPN)
```

- **Phase1 → Phase2 = 재구축**(라이브 마이그레이션 X). `config.yaml`의 `tls-san`에 양쪽 IP를 미리 넣어 재형성 시 API 인증서가 안 깨짐.
- **Ingress**: Traefik(LoadBalancer) ← MetalLB가 IP 할당. 브라우저는 한 IP만 보고 `/api/admission`→queue, `/api`→booking, `/`→frontend로 경로 라우팅([frontend/values.yaml](workloads/values/apps/frontend/values.yaml)).
- **외부노출**: Cloudflare 프록시 + DDNS + WireGuard VPN(운영 접근). OPNsense가 vmbr1로 클러스터를 격리.

---

## 스토리지

```
외장 USB SSD (단일 물리)
 └ Proxmox 호스트가 용도별 LV로 분할 → 각 노드 VM에 attach
    └ 노드 OS가 LV를 /var/lib/rancher/k3s/storage 에 마운트(fstab)
       └ local-path(k3s 기본 프로비저너)가 그 경로에 PVC를 만듦
          └ nodeSelector 핀 → stateful 파드가 자기 LV 노드에 뜸 → PVC가 그 LV에 잡힘
```

- 단일 SSD라 LV 분리는 **논리 격리**(I/O는 물리적으로 공유). node_filesystem_* 로 마운트포인트별 관측.
- 최근 데이터는 각 관측 컴포넌트 로컬(작음), 대용량은 **MinIO(S3)**로 → `miniodata` ≫ `lgtmdata`.

---

## 저장소 구조 (실행 3계층)

폴더는 **① 누가·언제 적용하나 ② 제어 vs 대상**으로 가른다(Argo "config↔source 분리" + Flux/RedHat 공통 골격).

```
cgv-infra/
├── bootstrap/          ① 손으로 한 번 (argocd 뜰 때까지)
│   ├── cluster/            k3s 설치·조인(SSH): config.yaml · 01-server-init · 02-server-join
│   ├── install.sh          Calico→MetalLB→Traefik→cert-manager→sealed-secrets→CRD→Strimzi→MySQL→argocd→root-app
│   ├── calico/ metallb/ traefik/ mysql/ argocd/ namespaces/   각 단계 매니페스트·values
│   └── root-app.yaml       app-of-apps 루트 → argocd/ 인계 (유일한 수동 apply)
├── argocd/             ② GitOps 배선 (제어면 — "무엇을·어디에·누가")
│   ├── projects/           apps.yaml · infra.yaml  (AppProject = 울타리)
│   ├── applicationsets/    apps.yaml · observability.yaml  (App 자동 생성기)
│   └── applications/       redis · kafka · sealed-secrets  (손 나열)
├── workloads/          ③ 배포 대상 (payload — 헬름 모델 그대로: 틀/값/비-helm)
│   ├── charts/             cgv-app(제네릭 앱 틀) · cgv-redis(bitnami 래퍼)
│   ├── values/             apps/ · observability/ · envs/(dev 실물, stg·prd 골격)
│   └── manifests/          kafka/(CR) · secrets/(SealedSecret 봉인)
└── docs/               시크릿-계약 · 코드-반영사항
```

**최상위 3폴더가 곧 배포 순서**: `bootstrap`(손) → `argocd`(배선) → `workloads`(대상).

---

## 배포 흐름

```
① cluster/ 스크립트 (SSH, 노드에서)   → k3s 3노드 조인 (CNI 없어 NotReady)
② bootstrap/install.sh (k3s-1에서)    → Calico(→Ready)→…→argocd 설치
③ install.sh 마지막: root-app 1개 apply → 여기서 손 끝, argo 자동 인계
④ root-app → argocd/ recurse           → AppProject·ApplicationSet·Application 생성
⑤ ApplicationSet → 앱/관측 Application 자동 생성 · Application이 workloads/ 가리킴
⑥ argocd가 렌더·배포 (sync-wave: 시크릿(-2)→미들웨어(-1)→MinIO(0)→LGTM/수집기(1)→앱(3))
     → CGV 서비스 기동
```

SSH에서 직접 실행하는 건 `cluster/` 스크립트와 `install.sh` 둘이다. 나머지는 argocd가 GitOps로 처리한다.

---

## 플랫폼 구성요소

| 계층 | 구성요소 | 채널 | 역할 |
|---|---|---|---|
| CNI | **Calico** | install.sh | 파드 네트워크 + NetworkPolicy (flannel 대체) |
| LB | **MetalLB** | install.sh | 온프렘 LoadBalancer IP 할당 |
| Ingress | **Traefik** | install.sh | L7 라우팅 (번들 traefik 대체) |
| TLS | **cert-manager** | install.sh | 인증서 (DNS-01) |
| 시크릿 | **sealed-secrets** | install.sh + GitOps | 암호를 Git에 안전하게(암호문만) |
| 관측 CRD | **prometheus-operator-crds** | install.sh | ServiceMonitor/PodMonitor(Alloy가 소비, 오퍼레이터 없음) |
| 미들웨어 오퍼레이터 | **Strimzi** | install.sh | Kafka CR 감시 |
| DB | **MySQL** | install.sh | booking durable 저장(데이터 안전상 argocd 밖) |
| GitOps | **ArgoCD** | 손 설치 → self-manage | 나머지 전부 선언·reconcile |

**경계 기준**: set-once(닭-달걀·플랫폼) = install.sh / 자주 튜닝(워크로드) = GitOps → 관리 포인트 최소.

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

- **Prometheus 오퍼레이터 없이** Alloy가 ServiceMonitor/PodMonitor를 직접 소비(§Path B). 3파드 clustering으로 중복 수집 방지.
- 메트릭=Mimir, 로그=Loki, 트레이스=Tempo, 시각화=Grafana. 전부 **monolithic/최소 replica** + **MinIO S3** 백엔드.

---

## 미들웨어

- **Redis** ([cgv-redis](workloads/charts/cgv-redis)) — 큐 상태·좌석락·입장인증. **dev=standalone+auth off**(단일-host 클라와 정합). Sentinel HA는 앱 코드 sentinel化 후 prd 업그레이드([docs/코드-반영사항](docs/코드-반영사항.md) #3).
- **Kafka** ([Strimzi CR](workloads/manifests/kafka)) — queue↔booking 이벤트(admissions·bookings-completed). 3브로커 RF3, 오퍼레이터가 CR을 실브로커로.
- **MySQL** — booking 확정 예매. 스키마 마이그레이션(Flyway)은 앱 코드 과제(#2), dev는 ddl-auto=update.

---

## 보안

- **PodSecurity restricted**(app/data): 비루트·읽기전용 루트FS·권한상승 금지·seccomp. (observability만 privileged — node-exporter 호스트 접근)
- **SealedSecret**: 암호는 kubeseal로 봉인, 암호문만 Git. 7종([docs/시크릿-계약](docs/시크릿-계약.md)) — 배포 전 봉인 필수.
- **이미지 nonroot**: queue distroless(65532)·booking(1001)·frontend nginx-unprivileged(101). digest 고정.

---

## 배포 순서 (요약)

1. **Proxmox** 설치(외장 SSD) + VM 3개 + 용도별 LV + 네트워크(vmbr) — 수작업.
2. 각 노드 OS prep(정적 IP·SSH키·**LV를 local-path 경로에 마운트**·[cluster/README](bootstrap/cluster/README.md)).
3. `cluster/01-server-init.sh`(k3s-1) → `02-server-join.sh`(k3s-2·3).
4. **SealedSecret 7종 봉인**([workloads/manifests/secrets/README](workloads/manifests/secrets/README.md)).
5. `bootstrap/install.sh` (k3s-1) → root-app → GitOps 폭포.
6. `kubectl -n argocd get applications -w` 로 sync 확인.

---

## 관련

- 앱 코드: [cgv-onprem](https://github.com/sss654654/cgv-onprem) (queue-go·booking·frontend)
- 설계 문서: `로드맵/단계2-dev-k3s구축배포/` (노드배치·헬름/gitops설계·플랫폼구축)
- 상태: 헬름 렌더·정합검증 통과. **실배포는 Proxmox 구축 후**(SealedSecret 봉인·실측 값·서비스명 정합 확정).
