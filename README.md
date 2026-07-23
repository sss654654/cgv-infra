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
| **k3s-1** | 4vCPU/8GB | `cgv.io/data=db` | mysqldata 20G · kafkadata 30G · ingesterwal 5G | **MySQL** · Mimir ingester(1/3) | etcd·CP · Kafka broker |
| **k3s-2** | 4vCPU/8GB | `cgv.io/data=obs` | kafkadata 30G · ingesterwal 5G · lokiwal 5G · tempowal 5G | **Loki · Tempo** · Mimir ingester(1/3) | etcd·CP · Kafka broker |
| **k3s-3** | 4vCPU/8GB | `cgv.io/data=obj` | miniodata 100G · kafkadata 30G · ingesterwal 5G | **MinIO** · Mimir ingester(1/3) | etcd·CP · Kafka broker · ArgoCD |

- **stateful 싱글턴은 nodeSelector로 핀** — 전용 LV가 그 노드에 있어서: MySQL→`db`, Loki/Tempo→`obs`, MinIO→`obj`. (miniodata가 100G인 건 MinIO가 LGTM의 S3 데이터 몸통이기 때문.)
- **Kafka 3브로커·Mimir ingester 3 = podAntiAffinity로 노드 분산**(각 노드 kafkadata·ingesterwal LV 사용, 각각 RF3 성립).
- **Mimir stateless(distributor/querier/…)·store_gateway·compactor·grafana·앱·Redis·수집기 = float**(스케줄러가 RAM 균형으로 배치). store_gateway·compactor는 emptyDir이라 노드 죽어도 재스케줄.

---

## 네트워크

```
Phase1 (walking-skeleton)          Phase2 (외부노출)
 vmbr0 직결                          WAN=vmbr0 ─ OPNsense ─ LAN=vmbr1
 노드 192.168.0.201-203              노드 10.0.0.11-13
 MetalLB LB 192.168.0.240-250        (OPNsense가 라우팅·방화벽·WireGuard VPN)
```

- **Phase1 → Phase2 = 재구축**(라이브 마이그레이션 X). `config.yaml`의 `tls-san`에 양쪽 IP를 미리 넣어 재형성 시 API 인증서가 안 깨짐.
- **Ingress**: Traefik(LoadBalancer) ← MetalLB가 IP 할당. 브라우저는 한 IP만 보고 `/api/admission`→queue, `/api`→booking, `/`→frontend로 경로 라우팅([frontend/values.yaml](workloads/charts/apps/frontend/values.yaml)).
- **외부노출**: Cloudflare 프록시 + DDNS + WireGuard VPN(운영 접근). OPNsense가 vmbr1로 클러스터를 격리.

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

## 저장소 구조 (실행 3계층)

폴더는 **① 누가·언제 적용하나 ② 제어 vs 대상**으로 가른다(Argo "config↔source 분리" + Flux/RedHat 공통 골격).

```
cgv-infra/
├── bootstrap/          ① 손으로 한 번 (argocd 뜰 때까지 — 순환·CRD·operator만, 10단계)
│   ├── cluster/            k3s 설치·조인(SSH): config.yaml · 01-server-init · 02-server-join
│   ├── install.sh          Calico→storage→cert-manager→sealed-secrets→CRD→Strimzi→argocd→root-app
│   ├── calico/ cert-manager/ sealed-secrets/ strimzi/ argocd/ storage/ namespaces/   매니페스트·values
│   └── root-app.yaml       app-of-apps 루트 → argocd/ 인계 (유일한 수동 apply)
├── argocd/             ② GitOps 배선 (제어면 — "무엇을·어디에·누가")
│   ├── projects/           apps · infra · secrets  (AppProject = 울타리)
│   ├── applicationsets/    apps(directory) · observability(list) · platform(list)  (App 자동 생성기)
│   └── applications/       mysql · redis · kafka · sealed-secrets · metallb-pool  (손 나열)
├── workloads/          ③ 배포 대상 (charts=정체성 / environments=환경값 / manifests=비-helm)
│   ├── charts/             apps/(cgv-app 틀 + queue·booking·frontend) · data/(cgv-mysql·cgv-redis 래퍼)
│   │                       · observability/(loki·mimir·tempo·grafana·alloy·minio·ksm·node-exporter) · platform/(metallb·traefik)
│   ├── environments/       dev(실물)·stg·prd(골격)
│   └── manifests/          kafka/(CR) · metallb/(pool CR) · secrets/(SealedSecret 봉인)
└── docs/               시크릿-계약 · 코드-반영사항
```

**최상위 3폴더가 곧 배포 순서**: `bootstrap`(손) → `argocd`(배선) → `workloads`(대상).

---

## 배포 흐름

```
① cluster/ 스크립트 (SSH, 노드에서)   → k3s 3노드 조인 (CNI 없어 NotReady)
② bootstrap/install.sh (k3s-1에서)    → Calico(→Ready)→storage→cert-manager→sealed-secrets→CRD→Strimzi→argocd (손 8개)
③ install.sh 마지막: root-app 1개 apply → 여기서 손 끝, argo 자동 인계
④ root-app → argocd/ recurse           → AppProject·ApplicationSet·Application 생성
⑤ ApplicationSet → 플랫폼/앱/관측 Application 자동 생성 · Application이 workloads/ 가리킴
⑥ argocd가 렌더·배포 (sync-wave: metallb(-4)→pool(-3)→traefik(-2)→미들웨어·시크릿(-1~-2)→MinIO(0)→LGTM/수집기(1)→앱(3))
     → CGV 서비스 기동
     ※ argocd는 traefik(GitOps) 뜨기 전엔 ingress 없음 → 초기 접근 port-forward
```

SSH에서 직접 실행하는 건 `cluster/` 스크립트와 `install.sh` 둘이다. 나머지는 argocd가 GitOps로 처리한다.

> ⚠️ sync-wave는 root가 직접 든 리소스(AppProject·SealedSecret·redis·kafka)까지만 순서를 강제한다. ApplicationSet이 생성하는 앱(MinIO·LGTM·앱)은 rollingSync가 없어 wave가 하드 게이트되지 않고, 초기엔 버킷·의존이 안 뜬 사이 crashloop→selfHeal로 수렴한다(초기 red는 정상).

---

## 플랫폼 구성요소

| 계층 | 구성요소 | 채널 | 역할 |
|---|---|---|---|
| CNI | **Calico** | install.sh (순환) | 파드 네트워크 + NetworkPolicy (flannel 대체) |
| LB | **MetalLB** | **GitOps** (wave -4) | 온프렘 LoadBalancer IP 할당 |
| Ingress | **Traefik** | **GitOps** (wave -2) | L7 라우팅 (번들 traefik 대체) — OTel 튜닝을 수동 upgrade 없이 |
| TLS | **cert-manager** | install.sh (현재 소비자 없어 Phase2까지 손 유지) | 인증서 (DNS-01) |
| 시크릿 | **sealed-secrets** | install.sh(컨트롤러, 순환) + GitOps(봉인본 배달) | 암호를 Git에 안전하게(암호문만) |
| 관측 CRD | **prometheus-operator-crds** | install.sh (CRD 예외) | ServiceMonitor/PodMonitor(Alloy가 소비, 오퍼레이터 없음) |
| 미들웨어 오퍼레이터 | **Strimzi** | install.sh (operator 예외) | Kafka CR 감시 |
| DB | **MySQL** | **GitOps** (wave -1, prune=false) | booking durable 저장 — 데이터 안전은 Retain PV가 커버(옛 "argocd 밖" 근거 폐기) |
| GitOps | **ArgoCD** | 손 설치 → self-manage | 나머지 전부 선언·reconcile |

**경계 기준**: **순환(CNI·시크릿·argocd)·CRD·operator만 손(install.sh 8개)**, 나머지(metallb·traefik·mysql 포함)는 GitOps + sync-wave. Traefik을 install.sh로 손 설치하면 수동 helm upgrade 시 순단 위험이 있어 GitOps로 관리한다.

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

- **Prometheus 오퍼레이터 없이** Alloy가 ServiceMonitor/PodMonitor를 직접 소비. 3파드 clustering으로 중복 수집 방지.
- 메트릭=Mimir, 로그=Loki, 트레이스=Tempo, 시각화=Grafana. 전부 **monolithic/최소 replica** + **MinIO S3** 백엔드.

---

## 미들웨어

- **Redis** ([cgv-redis](workloads/charts/data/cgv-redis)) — 큐 상태·좌석락·입장인증. **dev=Sentinel HA(master1+replica2+Sentinel3, auth on)** — 앱 코드 sentinel-aware 완료([docs/코드-반영사항](docs/코드-반영사항.md) #3/#5: queue NewFailoverClient·booking redis-sentinel 프로파일). master 승격이 앱까지 반영(failover 유효). 접속=sentinel `redis.data.svc:26379`.
- **Kafka** ([Strimzi CR](workloads/manifests/kafka)) — queue↔booking 이벤트(admissions·bookings-completed). 3브로커 RF3, 오퍼레이터가 CR을 실브로커로.
- **MySQL** — booking 확정 예매. 스키마 마이그레이션(Flyway)은 앱 코드 과제(#2), dev는 ddl-auto=update.

---

## 보안

- **PodSecurity restricted**(app/data): 비루트·읽기전용 루트FS·권한상승 금지·seccomp. (observability만 privileged — node-exporter 호스트 접근)
- **SealedSecret**: 암호는 kubeseal로 봉인, 암호문만 Git. 10종([docs/시크릿-계약](docs/시크릿-계약.md), dev HA — redis auth·minio-lgtm-user 포함) — 배포 전 봉인 필수. **mysql-secret 포함 전부 GitOps 배달**(sealed-secrets App wave -2 → mysql App wave -1).
- **이미지 nonroot**: queue distroless(65532)·booking(1001)·frontend nginx-unprivileged(101). 태그=dev/stg/prd 문자열 + pullPolicy IfNotPresent(digest 핀은 prd 강화 과제).

---

## 배포 순서 (요약)

1. **Proxmox** 설치(외장 SSD) + VM 3개 + 용도별 LV + 네트워크(vmbr) — 수작업.
2. 각 노드 OS prep(정적 IP·SSH키·**데이터 디스크 mkfs + `/mnt/disks/<용도>` 마운트·fstab**·[cluster/README](bootstrap/cluster/README.md)).
3. `cluster/01-server-init.sh`(k3s-1) → `02-server-join.sh`(k3s-2·3).
4. **SealedSecret 10종 봉인·커밋**([workloads/manifests/secrets/README](workloads/manifests/secrets/README.md)) — root-app 전 선행(전부 GitOps 배달).
5. `bootstrap/install.sh` (k3s-1) → root-app → GitOps 폭포.
6. `kubectl -n argocd get applications -w` 로 sync 확인.

---

## 관련

- 앱 코드: [cgv-onprem](https://github.com/sss654654/cgv-onprem) (queue-go·booking·frontend)
- 상태: 헬름 렌더·정합검증 통과. **실배포는 Proxmox 구축 후**(SealedSecret 봉인·실측 값·서비스명 정합 확정).
