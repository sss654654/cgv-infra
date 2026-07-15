# SealedSecret 봉인 (배포 전 필수)

sealed-secrets 컨트롤러 up(install.sh [6]) 후, `docs/시크릿-계약.md` 표대로 각 Secret을 kubeseal로 봉인해
이 폴더에 `<name>.yaml`로 저장. `argocd/applications/sealed-secrets.yaml`이 sync-wave -2로 배달(앱보다 먼저).

예 (mysql-secret):
```
kubectl create secret generic mysql-secret -n data \
  --from-literal=mysql-root-password='<PW>' --dry-run=client -o yaml \
  | kubeseal --format yaml > mysql-secret.yaml
```
★ **booking-secrets의 MYSQL_PASSWORD = mysql-secret의 mysql-root-password** (같은 값이어야 booking이 붙음).

필요 목록: `mysql-secret`(data) · `booking-secrets`(app) · `minio-root-secret`·`loki-s3-credentials`·`mimir-minio-credentials`·`tempo-s3-credentials`·`grafana-admin`(observability).
※ dev redis는 auth off(standalone)라 redis-secret 불필요.
