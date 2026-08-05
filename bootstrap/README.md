# bootstrap — 손으로 하는 구간

빈 노드에서 시작해 **ArgoCD가 나머지를 인계받을 수 있는 상태**까지 만드는 폴더다.

이 저장소의 배포는 두 방식이 섞여 있다.

```
방법 A) 사람이 명령을 쳐서 설치한다     ← bootstrap/ 이 폴더
방법 B) ArgoCD가 git을 보고 배포한다    ← argocd/ + workloads/
```

목표는 B다. 그런데 **B를 시작하려면 ArgoCD가 먼저 있어야 하고, ArgoCD를 설치할 주체는 ArgoCD가 될 수 없다.** 그래서 A로 최소한만 깔고 넘긴다. 이 폴더의 크기가 곧 "GitOps 밖에 남은 수작업의 양"이라, 여기 뭘 넣을지가 설계 판단이다.

---

## 파일 셋의 역할

| 파일 | 정체 | 하는 일 |
|---|---|---|
| `install.sh` | 셸 스크립트 | 9단계를 순서대로 설치. ArgoCD까지 세우고 멈춘다 |
| `root-app.yaml` | 쿠버네티스 매니페스트 | ArgoCD에게 "이 저장소의 `argocd/` 폴더를 봐라"고 알려주는 선언 한 장 |
| `root-app.sh` | 셸 스크립트 | 위 선언을 클러스터에 넣는다. 넣기 전에 봉인본이 갖춰졌는지 검사한다 |

`root-app.yaml`은 실행 파일이 아니라 **"git 주소가 적힌 쪽지"**다. 이걸 클러스터에 넣는 순간 ArgoCD가 쪽지를 읽고 그 폴더의 모든 선언을 배포하기 시작한다 — 손이 끝나는 지점이다.

---

## 실행 순서 (사람이 개입하는 지점이 셋)

```
① cluster/ 스크립트 (SSH, 각 노드에서)
      k3s 설치·조인 → 3노드 클러스터. CNI가 없어 NotReady 상태
                ↓
② install.sh                                    ← 이 폴더
      [1/9] Calico ... [9/9] argocd
      끝나면 멈춘다. GitOps는 아직 시작 안 함
                ↓
③ ★ SealedSecret 11종 봉인 → 커밋 → push        ← 사람만 할 수 있는 구간
      install.sh [5/9]가 세운 컨트롤러의 공개키로 암호화한다
      초기 10종(seal-secrets.sh) + ArgoCD 저장소 자격 1종(seal-one.sh)
      ★ 저장소 자격 한 장은 여기서 kubectl apply 까지 해둔다 —
         그게 없으면 ArgoCD가 저장소를 못 읽어 ④ 다음이 안 돈다
                ↓
④ root-app.sh
      봉인본 개수 확인 → root-app.yaml apply
                ↓
⑤ ArgoCD가 나머지 전부 배포 (손 끝)
```

②와 ④가 나뉜 이유가 이 폴더 설계의 핵심이다 — 아래 [왜 두 스크립트로 나뉘나](#왜-두-스크립트로-나뉘나)에서 다룬다.

---

## install.sh — 9단계

| # | 무엇 | 왜 GitOps가 아니라 손인가 |
|---|---|---|
| 1 | **Calico** (CNI) | 닭-달걀. 파드 네트워크가 없으면 ArgoCD 파드 자체가 못 뜬다. 이 단계 전까지 3노드는 NotReady다 |
| 2 | **네임스페이스 + PodSecurity 라벨** | 뒤 단계들이 이 ns에 설치된다. 라벨을 나중에 붙이면 이미 뜬 파드는 재검사되지 않는다 |
| 3 | **StorageClass 6종 + 정적 PV 10개** | 워크로드보다 먼저 있어야 PVC가 바인딩된다. 노드에 이미 마운트된 디스크를 쿠버네티스에 "등록"하는 단계 |
| 4 | **cert-manager** | 현재 소비자가 없다. 외부노출 단계 대비로 설치만 해둔 상태 |
| 5 | **sealed-secrets 컨트롤러** | 순환. 시크릿을 푸는 주체가 GitOps로 배달되는 시크릿에 의존하면 순환이 된다. **★ 이 단계 뒤부터 봉인이 가능하다** |
| 6 | **prometheus-operator CRD** + **control-plane 수집** | CRD는 타입 정의라 그 타입을 쓰는 매니페스트보다 먼저 있어야 한다. etcd 메트릭용 Service/Endpoints/ServiceMonitor도 여기서 apply(ServiceMonitor CRD가 방금 생겼으므로) |
| 7 | **Strimzi 오퍼레이터** | CR을 해석할 주체가 먼저 있어야 KafkaCluster CR이 의미를 갖는다 |
| 8 | **argocd** | 자기 자신은 스스로 설치할 수 없다. 설치 후 self-manage로 넘어간다 |
| 9 | **argocd 준비 대기** | rollout 완료까지 대기 |

**이 아홉의 공통점** — 셋 중 하나다: 닭-달걀(Calico·sealed-secrets·argocd) / CRD(prometheus) / 오퍼레이터(Strimzi). 나머지(네임스페이스·스토리지·cert-manager)는 뒤 단계의 전제라 순서상 여기 있다.

**여기 없는 것들** — MetalLB · Traefik · MySQL · Redis · Kafka CR · LGTM 8종 · 앱 3종. 전부 ArgoCD가 배포한다. 손으로 깔면 값을 바꿀 때마다 `helm upgrade`를 사람이 쳐야 하고, 그 순간 git과 클러스터가 어긋난다.

### 실행 전 검사

스크립트는 시작하자마자 네 가지를 확인하고 하나라도 없으면 아무것도 하지 않는다.

```bash
kubectl 있나 · helm 있나 · kubeconfig 읽히나 · 클러스터가 응답하나
```

중간에 죽어 **부분만 적용된 상태**가 남는 것을 막기 위해서다.

### 어디서 실행하나 — 노드가 아니어도 된다

`install.sh`가 하는 일은 결국 `kubectl apply`와 `helm upgrade`이고, 둘 다 **API 서버(노드의 6443)에 HTTPS 요청을 보내는 것**이다. 노드 안에서 실행해도 자기 자신의 6443으로 붙으므로 결과가 같다. 필요한 것은 셋뿐이다.

| 필요 | 이유 |
|---|---|
| `kubectl` · `helm` | 요청을 보낼 도구 |
| kubeconfig | 어디로 보낼지(주소) + 누구인지(클라이언트 인증서) |
| `bootstrap/` 트리 전체 | 스크립트가 하위 폴더를 상대경로로 읽는다 |

`helm`은 `kubectl`과 달리 k3s의 kubeconfig를 스스로 찾지 않는다 — `--kubeconfig` 플래그, `$KUBECONFIG`, `~/.kube/config` 셋만 본다. 그래서 스크립트가 시작할 때 직접 정한다.

```
$KUBECONFIG 가 이미 있으면        → 그대로 존중
없고 /etc/rancher/k3s/k3s.yaml    → 노드에서 실행 중인 경우
없고 ~/.kube/config               → 클러스터 밖에서 실행 중인 경우
둘 다 없으면                      → 중단
```

클러스터 밖에서 돌리면 실행 자리가 노드 장애와 분리된다는 이점이 있다. 노드에서 돌리면 그 노드가 죽을 때 실행 지점도 함께 사라진다.

### 재실행

**몇 번을 다시 돌려도 안전하다.** 모든 단계가 `kubectl apply` 또는 `helm upgrade --install`이라 이미 있으면 갱신만 한다. 실패하면 원인을 고치고 그냥 다시 돌리면 된다.

이 성질은 ④(root-app)를 떼어냈기에 성립한다. 붙어 있으면 재실행할 때마다 GitOps 폭포가 다시 시작된다.

---

## SealedSecret — 왜 별도 구간인가

### 문제: 시크릿은 git에 넣을 수도, 안 넣을 수도 없다

이 저장소의 목표는 "clone하면 재현된다"이다. 그런데 시크릿에서 막힌다.

**클러스터에만 만들면** — `kubectl create secret`으로 손수 만들면 그 값은 git에 없다. 클러스터를 다시 세우면 사라지고, 누가 무슨 값을 넣었는지 기록도 없다. ArgoCD 입장에서는 선언의 일부가 비어 있는 셈이라 GitOps가 완성되지 않는다.

**git에 넣으면** — 쿠버네티스 Secret 매니페스트는 값을 base64로 담는다. 이건 암호화가 아니라 **인코딩**이다.

```
data:
  mysql-root-password: bXlwYXNzd29yZA==     ← base64 -d 하면 mypassword
```

public 저장소에 올리면 평문을 올린 것과 같다.

### 해결: 비대칭 키

sealed-secrets는 클러스터 안에 컨트롤러를 두고 **키 쌍**을 만든다.

```
   클러스터 안                              작업자 노트북
┌────────────────────┐
│ sealed-secrets     │   공개키 ─────────▶  kubeseal이 이 키로 암호화
│ 컨트롤러           │                              │
│                    │                              ▼
│  (개인키 보관)     │                    SealedSecret 매니페스트
│                    │                    (암호문 — git에 올려도 안전)
│                    │ ◀───── ArgoCD가 배달 ────────┘
│                    │
│  개인키로 복호화   │
│        ↓           │
│  진짜 Secret 생성  │  ← 워크로드는 평범한 Secret으로 읽는다
└────────────────────┘
```

공개키로 잠근 것은 **그 클러스터의 개인키로만** 열린다. 그래서 암호문을 public 저장소에 두어도 남이 못 푼다. 결과적으로 **시크릿까지 git에 들어가 GitOps가 완성된다.**

### 그래서 순서가 강제된다

봉인하려면 공개키가 필요하고, 공개키는 컨트롤러가 떠야 생긴다. 컨트롤러는 `install.sh [5/9]`가 세운다.

```
install.sh [5/9] 실행  →  공개키 생김  →  봉인 가능
```

**봉인을 건너뛰고 GitOps를 시작하면** MySQL·Redis·MinIO·Grafana·Loki·Mimir·Tempo·queue·booking이 전부 시크릿을 못 찾아 기동하지 못한다. 파드는 `CreateContainerConfigError` 또는 `ContainerCreating`에서 멈추는데, ArgoCD 화면에는 Synced로 보여 원인이 잘 드러나지 않는다.

### 만들 것 — 10종

이름·네임스페이스·**정확한 키명**은 [`docs/시크릿-계약.md`](../docs/시크릿-계약.md)가 정본이다. 차트마다 요구하는 키명이 달라 통일할 수 없어, 표대로 만들어야 붙는다.

| ns | 시크릿 |
|---|---|
| `data` | `mysql-secret` · `redis-secret` |
| `app` | `booking-secrets` · `queue-secrets` |
| `observability` | `minio-root-secret` · `minio-lgtm-user` · `loki-s3-credentials` · `mimir-minio-credentials` · `tempo-s3-credentials` · `grafana-admin` |

값이 서로 묶인 것들이 있다. 예를 들어 `mysql-secret`의 두 키는 같은 값이어야 하고, 그 값이 `booking-secrets`의 `MYSQL_PASSWORD`와도 같아야 booking이 DB에 붙는다. 표의 "값 규칙" 열에 정리돼 있다.

### 봉인 명령의 형태

```bash
kubectl create secret generic mysql-secret -n data \
  --from-literal=mysql-root-password='<값>' \
  --from-literal=mysql-password='<같은 값>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system \
> ../workloads/manifests/secrets/mysql-secret.yaml
```

앞부분은 평범한 Secret 생성이되 `--dry-run=client -o yaml`이 붙어 **클러스터에 만들지 않고 YAML만 출력**한다. 평문이 클러스터에 남지 않고 파이프로 넘어간다. 뒷부분이 그것을 공개키로 잠가 `kind: SealedSecret` 매니페스트로 바꾼다.

### 봉인 스크립트 둘 — 쓰임이 다르다

| | 언제 | 무엇을 |
|---|---|---|
| `seal-secrets.sh` | 클러스터를 처음 세울 때 한 번 | 값 5개를 물어 **10종을 일괄** 생성. 값이 서로 묶여 있어 한꺼번에 만들어야 계약이 맞는다 |
| `seal-one.sh` | 그 뒤에 하나가 더 필요할 때 | 이름·네임스페이스·라벨을 받아 **낱개 하나**만 봉인. 기존 10종은 건드리지 않는다 |

기존 봉인본에 하나를 더하려고 `seal-secrets.sh`를 다시 돌리면 값 5개를 전부 다시 입력해야 하고, 그 값이 지금 클러스터에 떠 있는 것과 하나라도 다르면 해당 워크로드가 붙지 못한다. 그래서 추가는 `seal-one.sh`로 한다.

```bash
./seal-one.sh <이름> <네임스페이스> [라벨 key=value ...]
```

라벨을 받는 이유는 ArgoCD 저장소 자격처럼 **라벨이 있어야 인식되는 Secret**이 있어서다.

### 틀리기 쉬운 세 지점

**① 네임스페이스** — kubeseal 기본 봉인 범위는 `strict`로, **이름과 네임스페이스에 묶인다.** `-n data`로 봉인한 것을 `app`에 두면 CR은 정상 apply되고 ArgoCD도 Synced로 보이지만, 컨트롤러가 `no key could decrypt secret`으로 실패해 Secret이 생기지 않는다. 10종이 세 네임스페이스에 흩어져 있어 실수 확률이 낮지 않다.

**② `--controller-name`** — kubeseal은 기본적으로 `kube-system`의 `sealed-secrets-controller`를 찾는다. 이 저장소는 helm 릴리스명을 `sealed-secrets`로 설치하므로 서비스명이 다르다. 플래그를 빠뜨리면 공개키를 못 받아 `cannot fetch certificate` 오류가 난다.

**③ 개인키 백업 — 유일하게 비가역** — 봉인본은 그 클러스터의 개인키로만 풀린다. 클러스터를 다시 세우면 새 키가 생기고, git에 있는 암호문 10개가 전부 못 푸는 파일이 된다. 복구 방법은 값을 다시 정해 전부 재봉인하는 것뿐이다.

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-key.yaml
```

이 파일은 **클러스터의 모든 시크릿을 열 수 있는 열쇠**다. git에 넣지 말고 클러스터 밖 다른 매체에 암호화해 보관한다.

### 커밋·push까지 해야 한다

ArgoCD는 로컬 파일이 아니라 **원격 저장소**를 읽는다. 봉인 파일을 만들어두고 push하지 않으면 ArgoCD 입장에서는 여전히 0개다. `root-app.sh`가 커밋되지 않은 변경이 있으면 경고를 띄운다.

---

## 왜 두 스크립트로 나뉘나

원래는 root-app apply가 `install.sh`의 마지막 단계였다. 그 구조에서는 이렇게 흐른다.

```
install.sh 실행
  [5] sealed-secrets 컨트롤러 뜸    ← 이제야 봉인이 가능해진 시점
  [6][7][8][9] ...                  ← 멈추지 않고 계속 진행
  [10] root-app apply               ← 봉인본 0개인 채로 GitOps 시작
        ↓
  시크릿을 요구하는 워크로드가 일제히 실패
```

문서에는 "봉인은 root-app보다 먼저"라고 적혀 있었지만, **그것을 지킬 수 있는 실행 경로가 없었다.** 봉인이 들어갈 틈에서 스크립트가 멈추지 않기 때문이다.

떼어내면 순서가 코드로 강제된다.

- `install.sh`는 argocd까지만 하고 자연히 멈춘다 → 봉인할 시간이 생긴다
- `root-app.sh`가 봉인본 개수를 세어 부족하면 인계를 거부한다
- `install.sh`를 몇 번 다시 돌려도 GitOps가 시작되지 않는다

의도적으로 건너뛰려면 탈출구가 있다.

```bash
SKIP_SECRET_CHECK=1 ./root-app.sh
```

관측 스택만 먼저 확인하는 것처럼, 시크릿 소비 워크로드가 실패할 것을 알고 진행할 때 쓴다.

---

## 하위 폴더

| 폴더 | 내용 |
|---|---|
| `cluster/` | k3s 설치·조인 스크립트와 노드 설정. **install.sh보다 앞 단계**다([cluster/README](cluster/README.md)) |
| `calico/` | Calico Installation CR |
| `namespaces/` | 네임스페이스 + PodSecurity 라벨 |
| `storage/` | StorageClass 6종 + 정적 PV 10개 |
| `control-plane/` | etcd 메트릭 수집 경로(Service + 수동 Endpoints + ServiceMonitor) |
| `cert-manager/` `sealed-secrets/` `strimzi/` `argocd/` | 각 helm values |

---

## 파일을 노드에 가져가는 법

`git clone`으로 받는다. Windows 작업트리는 `core.autocrlf` 때문에 CRLF를 갖고 있어, 거기서 scp로 직접 복사하면 셸이 `$'do\r'` 같은 문법 오류로 죽는다. 저장소의 `.gitattributes`가 내용을 LF로 고정하므로 clone/pull로 받으면 그 문제가 없다.

`install.sh`는 `bootstrap/` 트리 전체를 상대경로로 읽는다 — 스크립트 한 파일만 옮기면 `calico/custom-resources.yaml`을 못 찾고 즉시 실패한다.
