# SealedSecret 봉인 (배포 전 필수)

sealed-secrets 컨트롤러 up(install.sh [7]) 후, `docs/시크릿-계약.md` 표대로 각 Secret을 kubeseal로 봉인해
이 폴더에 `<name>.yaml`로 저장. `argocd/applications/sealed-secrets.yaml`이 sync-wave -2로 배달(앱보다 먼저).

예 (mysql-secret):
```
kubectl create secret generic mysql-secret -n data \
  --from-literal=mysql-root-password='<PW>' --dry-run=client -o yaml \
  | kubeseal --format yaml > mysql-secret.yaml
```
**booking-secrets의 MYSQL_PASSWORD = mysql-secret의 mysql-root-password** (같은 값이어야 booking이 붙음).

필요 목록(dev HA, 10종): `mysql-secret`·`redis-secret`(data) · `booking-secrets`·`queue-secrets`(app) · `minio-root-secret`·`minio-lgtm-user`·`loki-s3-credentials`·`mimir-minio-credentials`·`tempo-s3-credentials`·`grafana-admin`(observability).

**dev = Redis Sentinel HA(auth on)**: `redis-secret`(서버, data ns, 키 `redis-password`) + 클라 비번은 app ns에 `queue-secrets`·`booking-secrets`로 복제(둘 다 키 `REDIS_PASSWORD` — cgv-app은 envFrom만 지원해 키명=env명, cross-ns 불가). 세 시크릿 **같은 값**.
**mysql-secret도 GitOps 배달**: sealed-secrets App(wave -2)이 배달 → mysql App(wave -1)이 그 뒤 sync. 수동 apply 게이트 없음. 단 root-app 전에 여기 봉인·커밋 선행 필수(컨트롤러[7] up 후 kubeseal).
**minio-lgtm-user**: MinIO IAM 격리용 lgtm 전용 유저 비번(키 `password`). 이후 loki/mimir/tempo S3 크레덴셜 3종을 이 유저 키로 발급.
