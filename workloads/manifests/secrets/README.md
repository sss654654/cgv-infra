# SealedSecret 봉인 (배포 전 필수)

sealed-secrets 컨트롤러 up(install.sh [5/9]) 후, `docs/시크릿-계약.md` 표대로 각 Secret을 kubeseal로 봉인해
이 폴더에 `<name>.yaml`로 저장. `argocd/applications/sealed-secrets.yaml`이 sync-wave -2로 배달(앱보다 먼저).

예 (mysql-secret):
```
kubectl create secret generic mysql-secret -n data \
  --from-literal=mysql-root-password='<PW>' --from-literal=mysql-password='<같은 PW>' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets --controller-namespace kube-system \
  > mysql-secret.yaml
```
**`--controller-name`·`--controller-namespace`를 반드시 붙인다.** kubeseal 기본 기대값은 `kube-system/sealed-secrets-controller`인데,
이 저장소는 helm 릴리스명 `sealed-secrets`로 설치하므로 서비스명이 `sealed-secrets`다. 안 붙이면 공개키를 못 받아 봉인이 실패한다.

**봉인은 `-n <대상 네임스페이스>`가 정확해야 한다.** kubeseal 기본 스코프는 strict(이름+네임스페이스 결속)라,
네임스페이스가 틀리면 CR은 정상 apply되고 ArgoCD도 Synced로 보이는데 컨트롤러가 복호화에 실패해 Secret이 생기지 않는다.
app ns 2종·observability ns 6종·data ns 2종이므로 `-n` 값을 표(`docs/시크릿-계약.md`)와 대조하며 만든다.
**booking-secrets의 MYSQL_PASSWORD = mysql-secret의 mysql-root-password** (같은 값이어야 booking이 붙음).

필요 목록(dev HA, 10종): `mysql-secret`·`redis-secret`(data) · `booking-secrets`·`queue-secrets`(app) · `minio-root-secret`·`minio-lgtm-user`·`loki-s3-credentials`·`mimir-minio-credentials`·`tempo-s3-credentials`·`grafana-admin`(observability).

여기에 네 장이 더 있어 총 14종이다. 위 10종은 `seal-secrets.sh`가 일괄로 만들고, 아래 넷은 나중에 더해진 것이라 낱개로 만든다.

- **`argocd-repo-cgv-infra`** — ArgoCD가 저장소를 읽는 자격. **이 한 장만 `root-app.sh` 전에 손으로 `kubectl apply`한다.** 이게 없으면 sealed-secrets App 자체가 sync되지 않아 순환에 걸린다.
- **`argocd-secret`** — GitLab webhook의 발신자 확인용 키 하나를 **기존 Secret에 얹는다.** argo-cd 차트가 만들고 argocd-server가 `admin.password`·`server.secretkey`를 채워 쓰는 Secret이라, `template.metadata.annotations`의 `patch`가 그 키들을 보존한다. **⚠️ 컨트롤러는 이 애노테이션을 봉인본이 아니라 클러스터의 Secret에서 읽으므로, 배달 전에 손으로 한 번 붙여야 한다.** 안 붙이면 `already exists and is not managed by SealedSecret`으로 거부한다.

```bash
kubectl -n argocd annotate secret argocd-secret sealedsecrets.bitnami.com/patch=true   # 선행
./seal-one.sh -a sealedsecrets.bitnami.com/patch=true argocd-secret argocd
```

- **`gitlab-registry`** — 노드가 GitLab 레지스트리에서 이미지를 받아오는 자격(app ns). 프로젝트가 private이라 pull에도 자격이 필요하다. **타입이 `kubernetes.io/dockerconfigjson`이라 `seal-one.sh`(generic 전용)로는 못 만든다.** 자격은 cgv-onprem 프로젝트의 deploy token이고 `read_registry`만 준다 — 노드는 받아오기만 한다. `--docker-server`는 차트의 `image.repository` 앞부분과 **글자까지 같아야** kubelet이 이 Secret을 그 레지스트리에 매칭한다.

```bash
kubectl create secret docker-registry gitlab-registry -n app \
  --docker-server=192.168.0.167:5050 \
  --docker-username='<deploy token 사용자명>' \
  --docker-password='<토큰>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system \
> gitlab-registry.yaml
```

- **`image-updater-registry`** — argocd-image-updater가 레지스트리 태그를 폴링하는 자격(argocd ns). updater 설정의 `credentials: pullsecret:argocd/image-updater-registry`가 이 이름을 가리킨다. gitlab-registry와 같은 `dockerconfigjson` 타입이라 만드는 방법도 같다(`kubectl create secret docker-registry ... -n argocd | kubeseal`). 자격은 `read_registry`만 있는 deploy token.

**dev = Redis Sentinel HA(auth on)**: `redis-secret`(서버, data ns, 키 `redis-password`) + 클라 비번은 app ns에 `queue-secrets`·`booking-secrets`로 복제(둘 다 키 `REDIS_PASSWORD` — cgv-app은 envFrom만 지원해 키명=env명, cross-ns 불가). 세 시크릿 **같은 값**.
**mysql-secret도 GitOps 배달**: sealed-secrets App(wave -2)이 배달 → mysql App(wave -1)이 그 뒤 sync. 수동 apply 게이트 없음. 단 root-app 전에 여기 봉인·커밋 선행 필수(컨트롤러[7] up 후 kubeseal).
**minio-lgtm-user**: MinIO IAM 격리용 lgtm 전용 유저 비번(키 `password`). 이후 loki/mimir/tempo S3 크레덴셜 3종을 이 유저 키로 발급.
