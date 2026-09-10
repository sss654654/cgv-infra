# bootstrap/eks — 손으로 하는 구간 (EKS)

빈 EKS 를 허브(집 k3s 의 ArgoCD)에 붙이기까지다. 손으로 하는 것은 둘이다.

| 파일 | 하는 일 |
|---|---|
| `register.sh` | EKS 를 허브에 등록한다. EKS 에 신원을 만들고, 그 토큰을 허브에 클러스터 Secret 으로 넣는다 |
| `argocd-manager.yaml` | 그 신원 — ServiceAccount · cluster-admin 바인딩 · 토큰 Secret |
| `secrets.sh` | Secret 넷을 만든다 — `booking-secrets` · `queue-secrets` · `app-admin-token` · `grafana-admin` |

k3s 쪽이 9단계인데 여기가 둘인 이유는 [../README.md](../README.md) 에 있다 — 닭-달걀은 허브에만 있다.

---

## 그날 순서

```
1  terraform apply                               cgv-terraform/envs/stg
2  aws eks update-kubeconfig --region ap-northeast-2 --name cgv-stg --alias cgv-stg
3  HUB_CONTEXT=<허브 컨텍스트> ./register.sh        ← 이 폴더
4  허브가 stg 를 가리키는 Application 을 sync 한다
     네임스페이스(PSA 라벨) → CRD · 오퍼레이터 · StorageClass → 관측 · 앱    sync-wave 순
5  ./secrets.sh                                  ← 이 폴더.  네임스페이스가 생길 때까지 기다린다
```

`--alias` 를 주는 이유 — 안 주면 컨텍스트 이름이 클러스터 ARN 이 된다. 두 스크립트는 `cgv-stg` 를 기본으로 찾는다(`EKS_CONTEXT` 로 바꿀 수 있다).

5 가 앱 sync 보다 늦으면 앱 파드가 Secret 을 못 찾아 `CreateContainerConfigError` 로 멈춰 있다가, Secret 이 생기면 kubelet 이 다시 시도해 뜬다. 되돌릴 일은 없다.

---

## 실행 자리

`kubectl` · `aws` · `jq` 가 있고 kubeconfig 에 컨텍스트 둘(EKS · 허브)이 있는 곳이면 된다. Windows 면 Git Bash 에서 돈다 — 스크립트가 `aws.exe` · `jq.exe` 출력 끝의 `\r` 을 떼고, 임시 파일은 Windows 경로로 바꿔 넘긴다.

EKS API 는 apply 시점의 집 공인 IP 에만 열린다(`public_access_cidrs`). 허브도 같은 공인 IP 로 나가므로 따로 열 것이 없다. 공인 IP 는 DDNS 라 apply 뒤에 바뀌면 스크립트도 허브도 못 붙는다 — `terraform apply` 를 다시 치면 갱신된다.

---

## 허브가 EKS 를 부르는 방식 — IAM 이 아니라 토큰

ArgoCD 에는 EKS 전용 IAM 인증(`awsAuthConfig`)이 있지만, ArgoCD 파드가 AWS 자격을 가져야 쓸 수 있다. 허브는 k3s 라 파드에 IAM 역할을 줄 경로(IRSA)가 없고, 남는 방법은 장기 키를 파드에 넣는 것뿐이다. 그래서 EKS 안에 ServiceAccount 를 만들고 그 토큰을 허브에 준다.

```
EKS                                      허브 (argocd ns)
  kube-system/argocd-manager       ──▶    Secret cluster-cgv-stg
  cluster-admin 바인딩                       label  argocd.argoproj.io/secret-type=cluster
  토큰 Secret (만료 없음)                     name   cgv-stg
                                            server https://….eks.amazonaws.com
                                            config bearerToken + caData
```

- **토큰** — 만료가 없고 클러스터를 지우면 같이 사라진다. 허브 쪽 Secret 은 남으므로 지울 때 따로 지운다.
- **cluster-admin** — 허브가 이 클러스터에 CRD · ClusterRole · Namespace 를 만든다. 무엇을 어디에 만들 수 있는지는 이 RBAC 가 아니라 허브의 AppProject(`destinations` · `clusterResourceWhitelist`)가 가른다. dev 의 in-cluster 와 같은 구조다.
- **등록만으로는 아무것도 배포되지 않는다.** AppProject 가 이 클러스터를 허용하고 Application 이 가리켜야 시작된다. 허브는 가리키는 Application 이 없는 클러스터에는 연결을 시험하지도 않는다 — 그래서 `register.sh` 가 허브에 넣기 전에 같은 토큰으로 EKS API 를 직접 불러 본다.

---

## Secret — 값이 어디서 오나

| Secret | ns | 키 | 값 |
|---|---|---|---|
| `booking-secrets` | app | `MYSQL_PASSWORD` | RDS 가 만들어 Secrets Manager 에 넣은 마스터 비밀번호 |
| `queue-secrets` | app | 없음 | ElastiCache 가 AUTH 를 안 쓴다. 차트가 이름으로 참조하므로 객체만 둔다 |
| `app-admin-token` | app | `ADMIN_TOKEN` | 스크립트가 만드는 난수. booking · queue 의 초기화 API 인증 |
| `grafana-admin` | observability | `admin-user` · `admin-password` | `admin` · 스크립트가 만드는 난수 |

- **MYSQL_PASSWORD** — RDS 의 `manage_master_user_password` 로 AWS 가 만든다. Terraform 이 값을 받지 않으므로 state 에 평문이 없다. 스크립트는 RDS identifier(`cgv-stg`)로 시크릿 ARN 을 찾아 값을 읽고, 그 사용자가 `envs/stg/booking.yaml` 의 `MYSQL_USER` 와 같은지 맞춰 본 뒤 넣는다.
- **SealedSecret 을 쓰지 않는다** — 봉인은 그 클러스터 컨트롤러의 개인키에 묶여서 클러스터가 뜨기 전에는 만들 수 없다. dev(k3s)는 그대로 SealedSecret 이다([docs/시크릿-계약.md](../../docs/시크릿-계약.md)).
- **External Secrets Operator 도 쓰지 않는다** — 실제 값이 필요한 것이 `MYSQL_PASSWORD` 하나이고, 하루 쓰고 지우는 환경이라 주기 동기화 · 회전이 할 일이 없다. 시크릿이 여럿이고 오래 사는 환경이면 그때 들인다.
- **다시 돌려도 된다** — `booking-secrets` 는 매번 다시 읽는다. 난수 둘은 이미 있으면 그대로 둔다. 다시 만들면 떠 있는 파드가 받은 값과 어긋나고, Grafana 는 관리자 비밀번호를 첫 기동 때 한 번만 쓴다.

---

## 실패했을 때

두 스크립트는 켜는 날 처음 돈다. `terraform plan` 도 `helm template` 도 이 경로를 확인하지 못한다. 그래서 **단계마다 손으로 칠 대체 명령을 스크립트 주석에 적어 두었다** — 한 단계가 막혀도 그 자리에서 이어 갈 수 있다.

## 지울 때

```
1  stg Application 을 지운다                  ALB Controller 가 자기가 만든 ALB 를 먼저 정리한다
2  kubectl --context <허브> -n argocd delete secret cluster-cgv-stg
3  terraform destroy
```

1 을 건너뛰면 ALB 가 state 밖에 남아 서브넷 삭제가 막힐 수 있다. 2 를 1 보다 먼저 하면 stg Application 이 대상 클러스터를 잃어 지워지지 않고 남는다.
