#!/usr/bin/env bash
# SealedSecret 10종 일괄 봉인 — docs/시크릿-계약.md 표의 실행본. 클러스터를 처음 세울 때 한 번 돈다.
# 뒤에 하나씩 더할 때는 seal-one.sh(낱개 추가) — 이 스크립트는 값 5개를 다시 물어 10종을 새로 만든다.
# 값은 전부 프롬프트로 받는다(-s: 화면·히스토리에 안 남음). 원문 Secret은 파일로 만들지 않고
# 표준입력으로 kubeseal에 흘린다. 결과 암호문만 workloads/manifests/secrets/에 남는다.
#
# 값이 물린 곳(계약 표):
#   MySQL 비번  = mysql-secret(root/password 두 키) = booking-secrets.MYSQL_PASSWORD
#   Redis 비번  = redis-secret = queue-secrets = booking-secrets.REDIS_PASSWORD
#   lgtm 비번   = minio-lgtm-user = loki/mimir/tempo S3 SECRET (ACCESS_KEY는 고정 "lgtm-user")
set -euo pipefail
cd "$(dirname "$0")"
OUT="../workloads/manifests/secrets"

command -v kubeseal >/dev/null || { echo "kubeseal 없음" >&2; exit 1; }
[ -d "$OUT" ] || { echo "$OUT 폴더 없음" >&2; exit 1; }

# 공개키는 컨트롤러에서 한 번만 받아 재사용(호출마다 fetch하면 느리고, 컨트롤러 다운 시 중간 실패).
CERT="$(mktemp)"; trap 'rm -f "$CERT"' EXIT
kubeseal --fetch-cert --controller-name sealed-secrets --controller-namespace kube-system > "$CERT" \
  || { echo "공개키 fetch 실패 — 컨트롤러가 떠 있나?" >&2; exit 1; }

ask() { # ask 변수명 프롬프트 [minlen]
  local var=$1 prompt=$2 min=${3:-1} v1 v2
  while :; do
    read -rsp "$prompt: " v1; echo >&2
    [ "${#v1}" -ge "$min" ] || { echo "  ${min}자 이상이어야 한다" >&2; continue; }
    read -rsp "$prompt (확인): " v2; echo >&2
    [ "$v1" = "$v2" ] && break || echo "  불일치 — 다시" >&2
  done
  printf -v "$var" '%s' "$v1"
}

echo "== 값 입력 (5개 비번 + 이름 2개로 10종이 만들어진다) =="
read -rp  "MinIO root 사용자명(예: minio-root): " MINIO_ROOT_USER
ask MINIO_ROOT_PW  "MinIO root 비밀번호" 8
ask LGTM_PW        "MinIO lgtm-user 비밀번호" 8
read -rp  "Grafana admin 사용자명(예: admin): " GRAFANA_USER
ask GRAFANA_PW     "Grafana admin 비밀번호"
ask MYSQL_PW       "MySQL 비밀번호"
ask REDIS_PW       "Redis 비밀번호"

seal() { # seal 이름 네임스페이스 --from-literal=... ...
  local name=$1 ns=$2; shift 2
  kubectl create secret generic "$name" -n "$ns" "$@" --dry-run=client -o yaml \
    | kubeseal --format yaml --cert "$CERT" \
        --controller-name sealed-secrets --controller-namespace kube-system \
    > "$OUT/$name.yaml"
  echo "  ok $name ($ns)"
}

echo "== 봉인 =="
seal minio-root-secret       observability --from-literal=rootUser="$MINIO_ROOT_USER" --from-literal=rootPassword="$MINIO_ROOT_PW"
seal minio-lgtm-user         observability --from-literal=password="$LGTM_PW"
seal loki-s3-credentials     observability --from-literal=AWS_ACCESS_KEY_ID=lgtm-user --from-literal=AWS_SECRET_ACCESS_KEY="$LGTM_PW"
seal mimir-minio-credentials observability --from-literal=MIMIR_S3_ACCESS_KEY_ID=lgtm-user --from-literal=MIMIR_S3_SECRET_ACCESS_KEY="$LGTM_PW"
seal tempo-s3-credentials    observability --from-literal=S3_ACCESS_KEY=lgtm-user --from-literal=S3_SECRET_KEY="$LGTM_PW"
seal grafana-admin           observability --from-literal=admin-user="$GRAFANA_USER" --from-literal=admin-password="$GRAFANA_PW"
seal mysql-secret            data          --from-literal=mysql-root-password="$MYSQL_PW" --from-literal=mysql-password="$MYSQL_PW"
seal redis-secret            data          --from-literal=redis-password="$REDIS_PW"
seal booking-secrets         app           --from-literal=MYSQL_PASSWORD="$MYSQL_PW" --from-literal=REDIS_PASSWORD="$REDIS_PW"
seal queue-secrets           app           --from-literal=REDIS_PASSWORD="$REDIS_PW"

echo
echo "봉인본 $(find "$OUT" -maxdepth 1 -name '*.yaml' | wc -l)개 — $OUT"
echo "다음: git add → commit → push (ArgoCD는 git에서 읽는다. push 전엔 없는 것과 같다)"
echo "그다음: ./root-app.sh"
