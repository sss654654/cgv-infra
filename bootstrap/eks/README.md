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

칸이 왜 다섯으로 갈리는지(Terraform · 사람 명령 · 스크립트 · git 커밋 · GitOps)는 [cgv-terraform README 「켜는 날」](https://github.com/sss654654/cgv-terraform#켜는-날) 에 있다. 여기는 이 저장소의 무엇이 어느 wave 에 도는지까지 적는다.

```
1  terraform apply                               cgv-terraform/envs/stg
2  aws eks update-kubeconfig --region ap-northeast-2 --name cgv-stg --alias cgv-stg
3  HUB_CONTEXT=<허브 컨텍스트> ./register.sh        ← 이 폴더
4  stg 를 켜는 커밋 → main                        아래 「stg 를 켜는 커밋」
5  허브가 배달한다 (sync-wave 순)
     -5 AppProject
     -4 네임스페이스 · gp3 StorageClass · prometheus CRD      cluster-stg · prometheus-crds-stg
     -3 Strimzi · ALB Controller                              strimzi-stg · alb-controller-stg
     -1 Kafka                                                 kafka-stg
      0 NetworkPolicy                                         netpol-stg
      1 관측 (LGTM · Grafana · Alloy · exporter 둘 · CloudWatch exporter)
      2 대시보드 넷                                            dashboards-stg
      3 앱 셋                                                  queue-stg · booking-stg · frontend-stg
6  ./secrets.sh                                  ← 이 폴더.  네임스페이스가 생길 때까지 기다린다
```

### stg 를 켜는 커밋

stg 를 가리키는 선언(위 5의 Application 과 AppProject 의 stg 자리)은 대상 주소가 `https://STG_EKS_ENDPOINT` 로 적혀 있다. EKS API 주소는 클러스터를 만들어야 정해져서, 그날 이 자리를 바꾸고 main 에 넣는다. 주소가 없는 채로 main 에 있으면 허브에 대상 없는 Application 이 오류로 떠 있게 된다.

```bash
EKS=$(kubectl config view --context cgv-stg --minify -o jsonpath='{.clusters[0].cluster.server}')
grep -rl 'https://STG_EKS_ENDPOINT' argocd | xargs sed -i "s#https://STG_EKS_ENDPOINT#${EKS}#g"
grep -rn STG_EKS_ENDPOINT argocd       # 아무것도 안 나와야 한다
grep -rn PLACEHOLDER envs/stg          # 그날 값 — terraform output handoff · expected 로 채운다
```

wave 는 만드는 순서만 정한다. 허브에 Application 헬스 체크 설정이 없어서 앞 wave 의 sync 가 끝나기를 기다리지 않는다. 그래서 stg Application 에는 전부 `retry` 가 있다 — 앞의 것이 덜 선 채로 먼저 돌다 실패하면(ServiceMonitor 종류를 모른다 · 네임스페이스가 없다) 다시 시도한다. 자동 sync 는 실패한 커밋을 스스로 다시 시도하지 않는다.

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
  - 새면 EKS 안의 전부(Secret · 파드 · 새 워크로드)에 닿는다. 노드의 IAM 역할까지는 못 간다 — launch template 의 IMDS hop limit 1 이 파드에서 노드 자격을 못 받게 한다.
  - 지금 줄이는 것 셋: EKS API 가 집 공인 IP 에만 열려 있어 토큰만으로는 다른 곳에서 못 붙는다 · Secret 이 집 클러스터 안에 있다 · 하루 뒤 클러스터와 함께 사라진다.
  - 클러스터를 둔 채 갈아 끼우려면: EKS 에서 `kubectl -n kube-system delete secret argocd-manager-token` 뒤 `register.sh` 를 다시 돌린다. 토큰 컨트롤러가 새 토큰을 채우고 허브 Secret 이 덮어써진다. 오래 사는 환경이면 만료 있는 토큰(TokenRequest)을 주기로 재발급하거나 허브를 EKS 로 옮겨 IAM(`awsAuthConfig`)으로 붙인다.
- **cluster-admin** — 허브가 이 클러스터에 CRD · ClusterRole · Namespace 를 만든다. 무엇을 어디에 만들 수 있는지는 이 RBAC 가 아니라 허브의 AppProject(`destinations` · `clusterResourceWhitelist`)가 가른다. dev 의 in-cluster 와 같은 구조다. 오래 사는 환경이면 cluster-admin 대신 허브가 만드는 범위(네임스페이스 · CRD · ClusterRole)만 주는 ClusterRole 로 좁힌다.
- **허브 계정** — 작업자 혼자 쓰므로 `admin` 하나이고 RBAC 를 나누지 않는다. 사람이 늘면 계정(argocd-cm `accounts.<이름>`)과 AppProject 단위 정책(argocd-rbac-cm)을 같이 가른다 — 정책이 프로젝트에 걸리므로 stg 만 맡기려면 프로젝트도 갈라야 한다.
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

순서와 이유는 [cgv-terraform README 「지울 때」](https://github.com/sss654654/cgv-terraform#지울-때) 가 정본이다. 이 폴더에 걸린 것만 줄여 적는다.

```
1  관측 데이터를 S3 에 올리고 확인한다(Mimir ingester /ingester/flush · Loki · Tempo)
2  kubectl --context <허브> -n argocd delete secret cluster-cgv-stg      ← register.sh 가 넣은 것
3  kubectl --context cgv-stg delete namespace app data observability observability-host
     → 콘솔에서 ALB 와 EBS 볼륨이 없어진 것을 확인한다
4  terraform destroy                                                     cgv-terraform/envs/stg
5  stg 를 켠 커밋을 되돌린다(곧 다시 켤 거면 주소만 바꾼다)
```

stg Application 을 지우는 것으로는 정리가 안 된다. AppSet 이 `preserveResourcesOnDeletion` 이고 root 직속 Application 에는 finalizer 가 없어서, Application 이 지워져도 Ingress · PVC 가 남고 destroy 가 ALB 의 ENI 에 막힌다.
