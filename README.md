# cgv-infra — CGV 온프렘 k3s 인프라 (GitOps)

CGV 티켓팅 폴리글랏 MSA([cgv-onprem](https://github.com/sss654654/cgv-onprem): queue·booking·frontend)를 온프레미스 k3s 클러스터에 GitOps로 배포·운영하는 인프라 코드. 물리 노드부터 CNI·LB·Ingress·스토리지·관측·미들웨어·시크릿까지 직접 구성한다.

이 repo로 노드 프로비저닝부터 CGV 서비스 기동까지 재현한다: 노드 프로비저닝 스크립트(`bootstrap/cluster/`) → 플랫폼 부트스트랩(`bootstrap/install.sh`) → GitOps 선언(`argocd/` + `workloads/`).

> 노트북 한 대를 열어 여기까지 오는 과정은 편별로 기록했다 — 각 편에서 무엇을 했고 무슨 개념을 짚었는지는 [만든 과정](#만든-과정--편별-기록)에.

---

## 목적

티켓팅(생중계 좌석 예매) 대기열 처리 MSA를 온프렘 환경에서 운영한다. 클라우드 매니지드(EKS·RDS·ELB·S3)가 대신 제공하는 CNI, 로드밸런서, Ingress 컨트롤러, 스토리지 프로비저닝, etcd 쿼럼, 시크릿 관리를 직접 구성하고 GitOps로 선언·자동화한다.

---

## 실행 스택 — 물리 → 가상 → 클러스터

```
┌─────────────────────────────────────────────────────────────┐
│  노트북 (31.3GB RAM) — 전원·호스트                     [구축됨]│
│  └─ 외장 USB SSD                                             │
│     └─ Proxmox VE (하이퍼바이저, 부팅 디스크)          [구축됨]│
│        ├─ VM: k3s-1  (4 vCPU / 8GB)   ┐                      │
│        ├─ VM: k3s-2  (4 vCPU / 8GB)   ├ k3s 클러스터   [구축됨]│
│        ├─ VM: k3s-3  (4 vCPU / 8GB)   ┘                      │
│        └─ VM: OPNsense (라우터·방화벽·VPN)             [미구축]│
└─────────────────────────────────────────────────────────────┘
      데스크탑(별도, 192.168.0.167)
        ├─ GitLab CE — ArgoCD가 읽는 GitOps 원본            [구축됨]
        └─ CI 러너 · 레지스트리 · 부하생성기                 [미구축]
```

- **하이퍼바이저 = Proxmox VE**, 외장 SSD에 설치(노트북 부팅 디스크와 분리).
- **k3s 노드 3 = VM**, 각 4 vCPU / 8GB / 40GB 부팅 + 용도별 LV(아래 스토리지).
- **OPNsense = 별도 VM**(k3s 노드 아님) — 외부노출 단계의 라우터·방화벽·VPN. 아직 만들지 않았다.
- **GitLab = 데스크탑**(클러스터 밖, Docker). ArgoCD가 읽는 저장소가 여기다 — 아래 [GitOps 원본](#gitops-원본--gitlab). GitHub에는 push 미러로 공개 사본만 나간다.
- **레지스트리·부하생성기 = 데스크탑**(예산 0). **아직 없다** — 앱 차트가 가리키는 `registry.cgv.local`은 실재하지 않는 호스트라, 앱을 올리려면 이미지 공급 경로를 먼저 정해야 한다(노드 반입 vs 레지스트리 구축).

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
   │   ├ MySQL             ├ Loki · Tempo      ├ MinIO(S3 백엔드)    │
   │   └ Kafka broker      └ Kafka broker      └ Kafka broker        │
   │                                                                 │
   │   노드당 1씩 강제(hard anti-affinity):                          │
   │     Kafka 브로커 3 · Mimir ingester 3 · Redis 3 · Traefik 2      │
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

  현재 경계는 **PodSecurity 라벨뿐**이다 — NetworkPolicy·ResourceQuota는 아직 없다(아래 [보안](#보안) 참조).

---

## 노드별 구성

| 노드 | 스펙 | 라벨 | 용도별 LV | 핀된 stateful | 비고 |
|---|---|---|---|---|---|
| **k3s-1** | 4vCPU/8GB | `cgv.io/data=db` | mysqldata 20G · kafkadata 30G · ingesterwal 5G | **MySQL** · Mimir ingester(1/3) | etcd·CP · Kafka broker |
| **k3s-2** | 4vCPU/8GB | `cgv.io/data=obs` | kafkadata 30G · ingesterwal 5G · lokiwal 5G · tempowal 5G | **Loki · Tempo** · Mimir ingester(1/3) | etcd·CP · Kafka broker |
| **k3s-3** | 4vCPU/8GB | `cgv.io/data=obj` | miniodata 100G · kafkadata 30G · ingesterwal 5G | **MinIO** · Mimir ingester(1/3) | etcd·CP · Kafka broker |

- **stateful 싱글턴은 nodeSelector로 핀** — 전용 LV가 그 노드에 있어서: MySQL→`db`, Loki/Tempo→`obs`, MinIO→`obj`. (miniodata가 100G인 건 MinIO가 LGTM의 S3 데이터 몸통이기 때문.)
- **Kafka 3브로커·Mimir ingester 3 = hard podAntiAffinity로 노드당 1개**(각 노드 kafkadata·ingesterwal LV 사용, 각각 RF3 성립).
- **Redis 3파드·Traefik 2파드도 노드당 1개로 강제**(hard podAntiAffinity). 근거는 워크로드마다 다르다:
  - **Traefik**(파드 2 < 노드 3) — 몰린 노드가 죽으면 MetalLB LB IP는 살아 있는데 백엔드가 0이 되어 전 Ingress가 502다. 여유 노드가 한 대 있어 장애 시에도 재배치되므로 Pending이 안 생긴다.
  - **Redis**(파드 3 = 노드 3) — sentinel이 각 파드 안의 사이드카라 파드가 몰리면 투표권도 몰린다. 2파드가 한 노드에 있으면 그 노드 정지 시 sentinel 3 중 2가 동시에 사라져 quorum 2를 못 채우고 failover가 아예 일어나지 않는다. 노드 한 대가 빠지면 파드 하나는 Pending이 되지만, **quorum이 2라 남은 2파드로 정족수가 채워져 failover는 동작한다**(quorum을 3으로 올리면 이 근거가 무너진다).
- **Mimir stateless(distributor/querier/…)·store_gateway·compactor·grafana·앱·ArgoCD = float**(스케줄러가 배치). store_gateway·compactor는 emptyDir이라 노드 죽어도 재스케줄.
- **alloy·node-exporter는 DaemonSet** — float이 아니라 전 노드에 1개씩.
- ⚠️ Redis에 hard를 걸면서 감수하는 것: 노드 한 대가 내려간 상태에서 Redis 차트를 업데이트하면 롤아웃이 Pending 파드에서 멈춘다(StatefulSet `podManagementPolicy` 기본값이 `OrderedReady`).

---

## 네트워크

```
현재 = 내부망 직결                   외부노출 후 (미구축)
 vmbr0 직결                          WAN=vmbr0 ─ OPNsense ─ LAN=vmbr1
 노드 192.168.0.201-203              노드 10.0.0.11-13
 MetalLB LB 192.168.0.240-250        (OPNsense가 라우팅·방화벽·WireGuard VPN)
```

- **두 구성 사이는 재구축이다**(라이브 마이그레이션 X). `config.yaml`의 `tls-san`에 양쪽 IP를 미리 넣어둬 재형성 시 API 인증서가 안 깨진다.
- ⚠️ MetalLB 풀 `192.168.0.240-250`이 공유기 DHCP 임대 대역과 겹치면 IP 충돌이 난다. 배포 전 공유기 설정에서 확인이 필요하다.
- **Ingress**: Traefik(LoadBalancer) ← MetalLB가 IP 할당. 브라우저는 한 IP만 보고 `/api/admission`→queue, `/api`→booking, `/`→frontend로 경로 라우팅([frontend/values.yaml](workloads/charts/apps/frontend/values.yaml)).
- **외부노출(미구축)**: Cloudflare 프록시 + DDNS + WireGuard VPN(운영 접근) 예정. OPNsense가 vmbr1로 클러스터를 격리하는 구성.

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
│   ├── projects/           bootstrap · argocd · apps · infra · secrets  (AppProject = 울타리)
│   ├── applicationsets/    apps(directory) · observability(list) · platform(list)  (App 자동 생성기)
│   └── applications/       argocd · dashboards · mysql · redis · kafka · sealed-secrets · metallb-pool  (손 나열)
├── workloads/          ③ 배포 대상 (charts=정체성 / environments=환경값 / manifests=비-helm)
│   ├── charts/             apps/(cgv-app 틀 + queue·booking·frontend) · data/(cgv-mysql·cgv-redis 래퍼)
│   │                       · observability/(loki·mimir·tempo·grafana·alloy·minio·ksm·node-exporter) · platform/(metallb·traefik)
│   ├── environments/       dev(실물)·stg·prd(골격)
│   └── manifests/          kafka/(CR) · metallb/(pool CR) · secrets/(SealedSecret 봉인 11종)
│                           · dashboards/(Grafana 대시보드 ConfigMap)
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
| `secrets` | SealedSecret 배달 | GitLab | `data`·`app`·`observability`·`argocd` | **`SealedSecret`만** |

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

## 배포 흐름

```
① cluster/ 스크립트 (SSH, 노드에서)   → k3s 3노드 조인 (CNI 없어 NotReady)
② bootstrap/install.sh (9단계)        → Calico(→Ready)→namespaces→storage→cert-manager→sealed-secrets
                                          →CRD→control-plane 수집→Strimzi→argocd
③ SealedSecret 11종 봉인·커밋·push     → 컨트롤러가 뜬 뒤에만 가능. 여기서 손이 한 번 더 들어간다
                                          그중 ArgoCD 저장소 자격 한 장은 apply까지 (없으면 ⑤ 이후가 안 돈다)
④ bootstrap/root-app.sh               → 봉인본 개수 확인 후 root-app apply. 여기서 손 끝
⑤ root-app → argocd/ recurse          → AppProject·ApplicationSet·Application 생성
⑥ ApplicationSet → 플랫폼/앱/관측 Application 자동 생성 · Application이 workloads/ 가리킴
⑦ argocd가 렌더·배포 → CGV 서비스 기동
     ※ argocd는 traefik(GitOps) 뜨기 전엔 ingress 없음 → 초기 접근 port-forward
```

직접 실행하는 건 `cluster/` 스크립트 · `install.sh` · `root-app.sh` 셋이고, 그 사이에 봉인 작업이 낀다. 나머지는 argocd가 GitOps로 처리한다.

> ⚠️ **sync-wave는 App 간 실행 순서를 강제하지 않는다.** wave가 만드는 것은 root sync 안에서의
> *리소스 생성 순서*(약 2초 간격)뿐이고, ApplicationSet이 만드는 App(metallb·traefik·MinIO·LGTM·앱)은
> 그 sync에 속하지 않아 wave 값이 실효가 없다. 실제 동작은 **전 App이 거의 동시에 생성되어 병렬 sync**이고,
> 의존이 안 뜬 사이의 crashloop는 selfHeal로 수렴한다(초기 red는 정상).
> 그래서 "관측 먼저 → 확인 → 앱"을 sync-wave로 강제할 수는 없다. 다만 앱 3종은 `registry.cgv.local`이
> 실재하지 않아 이미지를 못 받는다 — 이미지 공급 경로가 생기기 전까지는 관측·미들웨어만 수렴하고
> 앱은 `ImagePullBackOff`로 남는다. 앱 투입 시점은 그 경로를 만드는 시점이 결정한다.

---

## 플랫폼 구성요소

| 계층 | 구성요소 | 채널 | 역할 |
|---|---|---|---|
| CNI | **Calico** | install.sh (순환) | 파드 네트워크 (flannel 대체). NetworkPolicy 집행 주체이나 정책 리소스는 아직 없음 |
| LB | **MetalLB** | **GitOps** (wave -4) | 온프렘 LoadBalancer IP 할당 |
| Ingress | **Traefik** | **GitOps** (wave -2) | L7 라우팅 (번들 traefik 대체) — OTel 튜닝을 수동 upgrade 없이 |
| TLS | **cert-manager** | install.sh | 인증서 발급(DNS-01). **현재 소비자가 없다** — 외부노출 단계에 대비해 설치만 해두고, 파드 3개가 자원을 점유한다 |
| 시크릿 | **sealed-secrets** | install.sh(컨트롤러, 순환) + GitOps(봉인본 배달) | 암호를 Git에 안전하게(암호문만) |
| 관측 CRD | **prometheus-operator-crds** | install.sh (CRD 예외) | ServiceMonitor/PodMonitor(Alloy가 소비, 오퍼레이터 없음) |
| 미들웨어 오퍼레이터 | **Strimzi** | install.sh (operator 예외) | Kafka CR 감시 |
| DB | **MySQL** | **GitOps** (wave -1, prune=false) | booking durable 저장 — 데이터 안전은 Retain PV가 커버(옛 "argocd 밖" 근거 폐기) |
| GitOps | **ArgoCD** | install.sh(helm) → **GitOps 자기관리** | 나머지 전부 선언·reconcile. 인수인계 완료 — 값 변경은 커밋으로만 |

**경계 기준**: **순환(CNI·시크릿·argocd)·CRD·operator만 손(install.sh 8유닛)**, 나머지(metallb·traefik·mysql 포함)는 GitOps. Traefik을 install.sh로 손 설치하면 수동 helm upgrade 시 순단 위험이 있어 GitOps로 관리한다.

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
- 메트릭=**Mimir(distributed 11파드**, ingester 3·RF3 노드당 1), 로그=**Loki monolithic**, 트레이스=**Tempo monolithic**, 시각화=Grafana. 백엔드는 전부 **MinIO S3**.

**Alloy가 긁는 대상 — 두 갈래다.**

| 갈래 | 대상 | 방식 |
|---|---|---|
| CRD 경유 | 앱(queue·booking) · kube-state-metrics · node-exporter · LGTM 각 컴포넌트 · Redis exporter | ServiceMonitor / PodMonitor 소비 |
| 직접 scrape | **k3s server**(`:10250/metrics`) · **cAdvisor**(`:10250/metrics/cadvisor`) · **MinIO 버킷 사용량** | `role=node` 발견 + 노드 주소 직접 지목 |

노드 프로세스는 대상을 가리킬 Service가 없다 — CRD 경로로는 원리적으로 못 잡는다. etcd(`:2381`)만 예외로, 셀렉터 없는 Service + 수동 Endpoints를 만들어 ServiceMonitor로 붙였다(`bootstrap/control-plane/`).

**노드 주소를 직접 지목하는 이유**는 기본 `kubernetes` Service가 살아 있는 apiserver만 엔드포인트로 유지하기 때문이다. 노드가 죽으면 대상 자체가 목록에서 빠져 `up=0`이 아니라 아예 없어진다 — "죽었다"를 표현하지 못한다. 고정 주소면 대상이 남아 `up=0`으로 나온다.

같은 이유로 **`up{job="k3s-server"}`가 노드 생존의 기준 신호**다. kube-state-metrics 기반 노드 상태는 apiserver·etcd를 통과하므로 쿼럼이 깨지면 값이 갱신을 멈춘 채 마지막 상태로 굳는다.

**`:6443`(apiserver)은 따로 긁지 않는다.** k3s는 apiserver·etcd·scheduler·controller-manager·kubelet을 한 프로세스로 돌려 메트릭 레지스트리가 하나다. `:6443/metrics`와 `:10250/metrics`가 같은 내용을 낸다(실측: 같은 노드에서 메트릭 이름 536개 전부 일치, 줄 수 동일). 둘 다 긁으면 `job` 라벨만 다른 사본이 두 벌 저장돼 시리즈 상한을 두 배로 먹는다. `:10250`을 남긴 이유는 apiserver 인증·flowcontrol 경로를 지나지 않아 apiserver가 밀릴 때도 응답하고, cAdvisor가 같은 포트의 다른 경로여서다.

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
정착값       보유 182,397(61%) · 거절 0/s · ingester RSS 약 470-490MiB
```

- **상한은 천장이지 메모리 소비가 아니다.** ingester RAM은 상한값이 아니라 실제로 든 시리즈 수(`cortex_ingester_memory_series`)로 정해진다.
- RF3에 ingester도 3대라 **전역 상한이 곧 ingester 한 대가 지는 양**이다. 실측 시리즈당 약 4.2KiB이므로 30만이면 약 1.2GiB — `ingester` limit 2Gi가 그 짝이다.
- 30만은 실험 천장이다. 앱 3종 투입 후 재측정해 관측 최댓값 + 버퍼로 다시 잡는다.

### 대시보드 as-code

```
workloads/manifests/dashboards/  ─ ConfigMap(label: grafana_dashboard=1)
   └ argocd/applications/dashboards.yaml 이 배달 (prune·selfHeal on)
      └ grafana sidecar 가 파일로 떨어뜨림 → Grafana 가 읽음
```

- Grafana는 `persistence: false`다. 영속 저장소가 없으므로 **이 경로가 유일한 대시보드 공급원**이고, UI에서 손으로 만든 것은 재시작하면 사라진다. as-code를 강제하는 장치다.
- `prune: true`라 파일을 지우면 대시보드도 사라지고, `selfHeal: true`라 UI에서 손댄 것은 다음 sync에 되돌아간다. **정본이 git이라는 뜻이다.**
- `sidecar.searchNamespace`를 릴리스 네임스페이스로 한정한다. `ALL`로 두면 전역 ConfigMap을 감시하느라 RBAC이 전 네임스페이스로 넓어진다.
- 현재 1장 — **관측 파이프라인 상세**(`obs-pipeline-detail`). Mimir 공식 관측 3축(쓰기=받아지는가 / 읽기=답하는가 / 저장 여정=내려가는가)을 행으로 두고 12패널. 패널 제목이 담당 컴포넌트를 명시한다(Alloy·distributor·ingester·query-frontend·shipper·compactor·ring).

---

## 미들웨어

- **Redis** ([cgv-redis](workloads/charts/data/cgv-redis)) — 큐 상태·좌석락·입장인증. **dev=Sentinel HA(auth on)**. sentinel 모드는 master/replica가 별도 StatefulSet이 아니라 **동일 스펙 파드 3개인 단일 StatefulSet**이고, 각 파드 안에 redis·sentinel·metrics 컨테이너가 함께 뜬다. 누가 master인지는 매니페스트가 아니라 sentinel 3개의 투표(quorum 2)로 정해진다. 앱은 sentinel-aware라 master 승격이 앱까지 반영된다(queue `NewFailoverClient` · booking `redis-sentinel` 프로파일). 접속=sentinel `redis.data.svc:26379`.
- **Kafka** ([Strimzi CR](workloads/manifests/kafka)) — queue↔booking 이벤트. 3브로커 RF3, 오퍼레이터가 CR을 실브로커로. 토픽 4종을 선언으로 소유한다(선언이 없으면 앱이 붙을 때 브로커가 파티션 1로 만들고, 파티션은 줄일 수 없어 그 값이 굳는다): `admissions`(입장) · `admissions-revoked`(회수) · `bookings-completed`(자리 반환) · `admissions.DLT`(소비 실패 격리). 보존 3일 — kafkadata 30G 산정의 전제값이라 토픽에 명시한다.
  - DLT는 쿠버네티스 객체 이름에 대문자를 못 써서(RFC 1123) `metadata.name: admissions-dlt` · `spec.topicName: admissions.DLT`로 나눠 적는다. 앱이 쓰는 이름은 `topicName` 쪽이다.
  - **브로커 `resources`는 `KafkaNodePool` 소관**이다. `Kafka.spec.kafka.resources`는 v1 스키마에 없어 서버가 거부한다.
- **MySQL** — booking 확정 예매. 스키마 마이그레이션(Flyway)은 앱 코드 과제(#2), dev는 ddl-auto=update.
  - `auth.username`은 적지 않는다. 그 칸은 "추가로 만들 일반 유저"라 `root`를 넣으면 컨테이너가 `root user is already created`로 기동을 거부한다. booking은 기본 root 계정으로 접속한다(dev 판단).
  - `podManagementPolicy: OrderedReady`를 명시한다. 차트 기본값이 빈 문자열로 렌더되는데 서버는 기본값으로 채워 저장해서, 명시하지 않으면 git과 live가 영원히 달라 `OutOfSync`로 남는다.
  - `ServerSideApply`는 쓰지 않는다. 이 차트는 `affinity: null`·`supplementalGroups: []` 같은 필드를 렌더에 남기는데 서버는 그런 필드를 저장하지 않아 SSA 비교에서 영구 `OutOfSync`가 된다. 일반 apply 비교는 null과 부재를 같게 본다.

---

## 보안

**되어 있는 것**

- **PodSecurity** — 위 [k3s 클러스터 아키텍처](#k3s-클러스터-아키텍처)의 ns별 표대로 집행한다. 호스트 접근이 필요한 node-exporter만 별도 ns로 격리해 나머지를 baseline 이상으로 유지한다.
- **SealedSecret**: 암호는 kubeseal로 봉인, 암호문만 Git. 초기 10종([docs/시크릿-계약](docs/시크릿-계약.md), dev HA — redis auth·minio-lgtm-user 포함) + ArgoCD 저장소 자격 `argocd-repo-cgv-infra` = **현재 11개**. `root-app.sh`가 봉인본 개수를 세어 부족하면 GitOps 인계를 막는다.
- **저장소 자격도 평문으로 두지 않는다** — GitLab deploy token은 ArgoCD가 저장소를 읽는 데 필요한데, 그 값을 Git에 넣으면 저장소를 읽을 자격이 저장소 안에 있게 된다. 다른 암호와 같은 경로(SealedSecret)로 배달한다.
- **etcd 저장 암호화**: `secrets-encryption: true` — 컨트롤러가 푼 Secret이 etcd에 평문으로 앉지 않게(외장 SSD 반출 대비).
- **RBAC 축소**: loki·alloy는 차트 기본값이 SA에 전 네임스페이스 `secrets` 읽기 권한을 붙인다. loki는 룰 사이드카를 끄고, alloy는 기본 rules에서 `configmaps`·`secrets`를 뺀 목록을 명시해 그 경로를 닫았다.
- **앱 SA 토큰 미마운트**: `automountServiceAccountToken: false`. queue·booking·frontend는 쿠버네티스 API를 쓰지 않아, 쓰지 않는 자격증명을 파드에 얹지 않는다.
- **kubelet 자원 예약**: `system-reserved`·`kube-reserved`·`eviction-hard`를 노드 실측값 기준으로 설정. k3s는 apiserver·etcd를 파드가 아니라 systemd 프로세스로 돌려 kubelet이 그 사용량을 allocatable에서 빼지 않는다 — 예약이 없으면 워크로드가 제어면 메모리를 잠식한다. 같은 이유로 PriorityClass로는 제어면을 보호할 수 없다(파드가 아니라서 evict 대상이 아님).
  - `kube-reserved`는 **1Gi → 2Gi**다. 파드 0개일 때 645Mi였는데 App 18개를 배포한 뒤 재측정하니 `k3s.service` anon이 노드별 1549–1783Mi였다. 초기 1Gi 추정은 실제의 절반이라 그만큼 파드 몫에서 빼 쓰이고 있었다. 결과 allocatable memory ≈ 5081Mi. **⚠️ 이 값은 아직 노드에 반영되지 않았다** — 반영에 재시작(drain 동반)이 필요해 앱 투입 시 함께 한다.
  - `eviction-hard`는 **기본 목록을 통째로 교체한다**. k3s 기본은 `nodefs 5%`·`imagefs 5%` 둘뿐이라 메모리·inode 신호가 아예 없다 — 그 상태에서는 메모리가 말라도 kubelet이 개입하지 않고 곧장 커널 OOM으로 간다. `memory.available<300Mi`(약 7941Mi의 3.8%)를 신설한 근거는 kubelet 확인 주기가 10초라, 선이 낮으면 JVM 같은 큰 할당이 그 사이를 뚫고 지나가서다.
- **이미지 nonroot**: queue distroless(65532)·booking(1001)·frontend nginx-unprivileged(101).

**아직 없는 것** (선언과 실물을 구분해 적는다)

- **NetworkPolicy 0건** — 네임스페이스 간 통신이 전면 허용이다. app ns 컨테이너 하나가 침해되면 Kafka(무인증)·MySQL(root)·Redis·Loki·Mimir·MinIO·ArgoCD에 그대로 도달한다. dev에서는 감수하고, prd 경로는 "기본 차단 + 필요한 경로만 허용"이다.
- **ResourceQuota·LimitRange 0건** — 한 파드가 노드 메모리를 다 먹어도 ns 차원에서 막는 장치가 없다. 지금은 kubelet 예약과 파드별 limit이 방어선이다.
- **Kafka 무인증 평문** — `type: internal`은 클러스터 밖 노출만 막는다. 클러스터 안에서는 누구나 토픽을 읽고 쓴다. queue→booking 입장 이벤트가 곧 예매 권한이라, 이 노출은 NetworkPolicy가 생기기 전까지 열려 있다. userOperator는 켜져 있어 SCRAM+ACL로 갈 재료는 준비돼 있다.
- **booking이 MySQL에 root로 접속** — 앱 컨테이너가 DB 전권을 들고 있다. prd 경로는 스키마 한정 전용 계정이다.
- **JDBC 평문** — `useSSL=false`가 앱의 URL에 리터럴로 있어 인프라에서 끌 수 없다. 바꾸려면 앱 이미지를 다시 구워야 한다.
- **etcd 메트릭 포트(:2381) 무인증** — 같은 LAN에서 인증 없이 읽힌다. 방화벽(ufw)이 꺼져 있어 사설망 전체에 열려 있다.
- **이미지 태그가 가변** — `dev`/`stg`/`prd` 문자열 + `pullPolicy: IfNotPresent`. 같은 태그로 재push하면 캐시한 노드가 옛 이미지를 계속 쓴다.
- **sealed-secrets 개인키 백업 미구현** — 분실하면 Git의 봉인본 전체가 복호화 불가다.

---

## 배포 순서 — 현재 위치

| | 단계 | 상태 |
|---|---|---|
| 1 | **Proxmox** 설치(외장 SSD) + VM 3개 + 용도별 LV + 네트워크(vmbr) | ✅ 완료 |
| 2 | 각 노드 OS prep(정적 IP·SSH키·**데이터 디스크 10장 mkfs + `/mnt/disks/<용도>` 마운트·fstab**·[cluster/README](bootstrap/cluster/README.md)) | ✅ 완료 (재부팅 검증 통과) |
| 3 | `cluster/01-server-init.sh`(k3s-1) → `02-server-join.sh`(k3s-2·3) | ✅ 완료 (v1.36.2, etcd 3-member, CNI 전이라 NotReady) |
| 4 | `bootstrap/install.sh` — Calico부터 argocd까지. 여기까지는 몇 번을 다시 돌려도 안전하다(전부 멱등) | ✅ 완료 |
| 5 | **SealedSecret 봉인·커밋·push**([secrets/README](workloads/manifests/secrets/README.md)) — sealed-secrets 컨트롤러가 뜬 뒤에만 가능. 초기 10종 + 나중에 더한 ArgoCD 저장소 자격 = 11종 | ✅ 완료 |
| 6 | `bootstrap/root-app.sh` → GitOps 인계. 봉인본이 부족하면 여기서 멈춘다 | ✅ 완료 |
| 7 | `kubectl -n argocd get applications -w` 로 sync 확인 | ✅ 완료 (플랫폼·관측·미들웨어 수렴. 자원값은 실측으로 재조정) |
| 8 | **GitOps 원본을 GitLab으로** — 저장소 이전 · deploy token 봉인 · `repoURL` 전환 · AppProject 울타리 | ✅ 완료 |
| 9 | **ArgoCD self-managed 인수인계** — `argocd` Application이 helm이 만든 리소스를 이어받음 | ✅ 완료 |
| 10 | **이미지 공급 경로**(CI 러너 + 레지스트리) → 앱 3종 기동 | ⬜ 미착수 |

**실행 위치는 노드로 한정되지 않는다.** `kubectl`·`helm`이 있고 클러스터에 닿으면 어디서든 된다 — 두 도구는 API 서버로 HTTPS 요청을 보낼 뿐이다. kubeconfig는 `$KUBECONFIG` → k3s 기본 경로(`/etc/rancher/k3s/k3s.yaml`) → `~/.kube/config` 순으로 찾고, 셋 다 없으면 무엇이 필요한지 알리고 멈춘다. 시작 전에 `kubectl`·`helm`·kubeconfig 접근·클러스터 응답을 검사해, 중간에 죽어 부분 적용 상태가 남는 것을 막는다.

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

## 상태 (2026-08-06)

플랫폼·관측·미들웨어가 GitOps로 수렴했고, 그 GitOps 원본은 GitLab이다. ArgoCD는 자기 자신도 Application으로 관리한다.

```
Application 21 개    플랫폼 · 관측 · 미들웨어 · 시크릿 = Synced · Healthy
                    앱 3 종(queue · booking · frontend) = ImagePullBackOff
```

앱만 못 뜨는 이유는 하나다 — **이미지가 없다.** 차트가 가리키는 `registry.cgv.local`이 실재하지 않아, CI 러너와 레지스트리를 세우는 것이 다음 단계다.

---

## 만든 과정 — 편별 기록

노트북 한 대를 열어 이 클러스터를 세우기까지를 편별로 남겼다. 각 편은 **그 단계에서 실제로 한 작업**과 **그때 짚은 개념**을 함께 적는다 — 아래 표에서 필요한 편으로 바로 들어갈 수 있다.

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
| [번외](https://zed6740.tistory.com/216)<br>e1000e NIC hang | 반씩 좁히기로 업링크 구간 특정<br>`dmesg` — `Hardware Unit Hang` 34회<br>오프로드 off로 복구<br>udev 불발 규명 → `post-up`으로 교체 | carrier(링크) ≠ 데이터 흐름<br>ARP `FAILED`가 뜻하는 것<br>TSO/GSO/GRO와 Intel e1000e 결함<br>장치 개명이 udev 발화를 가름<br>검증의 층위 셋 |
| [번외](https://zed6740.tistory.com/219)<br>WSL2와 커밋 한도 | 죽는 순간 기록 — `exit 137` · `0xc00000fd`<br>물리 여유 6.6GB → 물리 부족 가설 폐기<br>페이지파일 재설정 — 한도 17.9 → 28.0GB<br>`PeakUsage 1MB` → 램 증설 취소 | Windows 커밋 한도 vs 리눅스 오버커밋<br>`Vmmem`이 대표하는 것<br>`free -h`에서 봐야 할 칸<br>`exit 137`이 알려주지 않는 것<br>페이지파일의 역할 둘 |
