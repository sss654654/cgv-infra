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

필요 목록(dev HA, 9종): `mysql-secret`·`redis-secret`(data) · `booking-secrets`·`queue-secrets`(app) · `minio-root-secret`·`loki-s3-credentials`·`mimir-minio-credentials`·`tempo-s3-credentials`·`grafana-admin`(observability).

★ **dev = Redis Sentinel HA(auth on)**: `redis-secret`(서버, data ns, 키 `redis-password`) + 클라 비번은 app ns에 `queue-secrets`·`booking-secrets`로 복제(둘 다 키 `REDIS_PASSWORD` — cgv-app은 envFrom만 지원해 키명=env명, cross-ns 불가). 세 시크릿 **같은 값**.
★ **mysql-secret은 install.sh [9] 전에 수동 apply** 필요(argocd 배달은 [10] 이후) — install.sh `[MySQL 시크릿 선행]` 스텝이 처리하나, **그 전에 여기 봉인·커밋 선행 필수**(컨트롤러[6] up 후 kubeseal).
