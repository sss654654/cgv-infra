#!/usr/bin/env bash
# secrets.sh — EKS 에 Secret 넷을 만든다.
#
#   Secret            네임스페이스      값
#   booking-secrets   app              MYSQL_PASSWORD.  RDS 가 Secrets Manager 에 만든 마스터 비밀번호
#                                      REDIS_PASSWORD.  아래 queue-secrets 와 같은 값
#   queue-secrets     app              REDIS_PASSWORD.  Terraform 이 만들어 Secrets Manager 에 넣은
#                                      ElastiCache AUTH 토큰
#   app-admin-token   app              ADMIN_TOKEN.  여기서 만드는 난수.  booking · queue 의 초기화 API 인증
#   grafana-admin     observability    admin-user · admin-password.  비밀번호는 여기서 만드는 난수
#
# SealedSecret 을 쓰지 않는다. 봉인은 그 클러스터 컨트롤러의 개인키에 묶여서 클러스터가
#   뜨기 전에는 만들 수 없다. 그래서 값이 git 에 들어가지 않고 이 스크립트가 그날 넣는다.
#
# 네임스페이스는 여기서 만들지 않는다. PSA 라벨을 포함한 정의는 git 에 있고 허브가 배달한다 —
#   여기서도 만들면 주인이 둘이 된다. 그래서 생길 때까지 기다린다.
#
# 전제      kubectl · aws · jq.  aws 자격은 terraform apply 를 친 주체
#           (필요 권한: rds:DescribeDBInstances · secretsmanager:GetSecretValue)
# 실행      ./secrets.sh
# 다시 돌려도 된다. booking-secrets 는 매번 Secrets Manager 에서 다시 읽고,
#   난수로 만드는 둘은 이미 있으면 그대로 둔다.
set -euo pipefail
cd "$(dirname "$0")"

EKS_CONTEXT="${EKS_CONTEXT:-cgv-stg}"
REGION="${AWS_REGION:-ap-northeast-2}"
DB_INSTANCE="${DB_INSTANCE:-cgv-stg}"   # RDS identifier = terraform 의 prefix

eks() { kubectl --context "$EKS_CONTEXT" "$@"; }

# Windows 의 aws.exe · jq.exe 는 줄 끝에 \r 을 붙인다. $( ) 는 \n 만 떼므로 \r 이 값에 남는다.
nocr() { tr -d '\r'; }

# 난수 48자(16진). head -c 로 읽을 양을 먼저 정한다 — 읽는 쪽이 먼저 닫히면 pipefail 에 걸린다.
rand() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Secret 한 장을 apply 한다. apply_secret <ns> <이름> [KEY=VALUE ...]
#   값을 kubectl 인자로 넘기지 않는다 — 셸 함수 인자는 프로세스 목록에 안 보이고,
#   base64 는 값을 파이프로 받는다. 키가 없으면 data 없는 Secret 이 된다.
apply_secret() {
  local ns=$1 name=$2 kv
  shift 2
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\n' "$name" "$ns"
    if [ $# -gt 0 ]; then
      printf 'data:\n'
      for kv in "$@"; do
        printf '  %s: %s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | base64 | tr -d '\n')"
      done
    fi
  } | eks apply -f -
}

# ---------- 선행 검사 ----------
MISSING=0
for c in kubectl aws jq; do
  command -v "$c" >/dev/null || { echo "$c 없음." >&2; MISSING=1; }
done
# jq 가 필요한 이유 — Secrets Manager 가 돌려주는 값이 {"username":…,"password":…} 모양의 문자열이라
#   한 번 더 풀어야 한다. aws 의 --query 는 문자열 안의 JSON 을 풀지 못한다.
[ "$MISSING" = 0 ] || { echo "  jq: winget install jqlang.jq (Windows) · sudo apt install jq (Ubuntu)" >&2; exit 1; }

case "$(kubectl config view --context "$EKS_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" in
  https://*.eks.amazonaws.com) ;;
  *) echo "컨텍스트 ${EKS_CONTEXT} 가 EKS 가 아니다. register.sh 의 전제를 먼저 맞춘다." >&2; exit 1 ;;
esac

# ---------- 1. 네임스페이스 대기 ----------
echo "[1/5] 네임스페이스 app · observability 대기 (허브가 만든다)"
for ns in app observability; do
  for i in $(seq 1 120); do
    eks get namespace "$ns" >/dev/null 2>&1 && break
    [ "$i" = 120 ] && {
      echo "네임스페이스 ${ns} 가 10분 안에 생기지 않았다. 허브에서 stg 네임스페이스를 만드는 Application 의 sync 를 봐라." >&2
      exit 1; }
    sleep 5
  done
done

# ---------- 2. booking-secrets ----------
echo "[2/5] booking-secrets ← Secrets Manager (RDS 마스터 비밀번호)"
# 시크릿 ARN 을 RDS 에서 찾는다. terraform output handoff 의 mysql_secret_arn 과 같은 값이다.
# 대체 명령. 값을 kubectl 인자로 넘기지 않는다 — 인자는 ps 와 셸 이력에 남는다.
#   read 로 받아 변수에 두고(셸 안의 값이라 프로세스 목록에 안 보인다), base64 는 파이프로 준다.
#   aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id <mysql_secret_arn> \
#     --query SecretString --output text           → 나온 JSON 의 password 를 아래 read 에 붙여 넣는다
#   read -rs P && printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: booking-secrets, namespace: app}\ntype: Opaque\ndata: {MYSQL_PASSWORD: %s}\n' \
#     "$(printf '%s' "$P" | base64 | tr -d '\n')" | kubectl --context cgv-stg apply -f -
SECRET_ARN=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text | nocr)
SECRET_JSON=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" \
  --query SecretString --output text | nocr)
DB_USER=$(printf '%s' "$SECRET_JSON" | jq -r .username | nocr)
DB_PASS=$(printf '%s' "$SECRET_JSON" | jq -r .password | nocr)

# booking 은 envs/stg/booking.yaml 의 MYSQL_USER 로 붙는다. 이 비밀번호가 그 계정의 것인지 맞춰 본다.
WANT_USER=$(sed -n 's/^ *MYSQL_USER: *//p' ../../envs/stg/booking.yaml | nocr)
[ "$DB_USER" = "$WANT_USER" ] || {
  echo "시크릿의 사용자(${DB_USER})와 envs/stg/booking.yaml 의 MYSQL_USER(${WANT_USER})가 다르다." >&2; exit 1; }
[ -n "$DB_PASS" ] && [ "$DB_PASS" != "null" ] || { echo "시크릿에 password 가 없다." >&2; exit 1; }

# ---------- 2-2. Redis AUTH 토큰 ----------
# RDS 와 달리 AWS 가 만들어 주지 않아 Terraform 이 만들어 Secrets Manager 에 넣는다.
#   시크릿 이름은 <prefix>-redis-auth 규칙이라 판이 바뀌어도 같다.
#   terraform output handoff 의 redis_secret_arn 과 같은 값을 가리킨다.
# 돌아오는 것은 JSON 이 아니라 비밀번호 문자열 그대로다(MySQL 쪽과 다르다).
REDIS_PASS=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "${DB_INSTANCE}-redis-auth" \
  --query SecretString --output text | nocr)
[ -n "$REDIS_PASS" ] && [ "$REDIS_PASS" != "None" ] || {
  echo "Redis AUTH 토큰을 못 읽었다. envs/stg apply 가 끝났는지 본다." >&2; exit 1; }

apply_secret app booking-secrets "MYSQL_PASSWORD=${DB_PASS}" "REDIS_PASSWORD=${REDIS_PASS}"

# ---------- 3. queue-secrets ----------
echo "[3/5] queue-secrets ← Secrets Manager (ElastiCache AUTH 토큰)"
# 대체 명령: 위 booking-secrets 와 같은 방식(값을 인자로 넘기지 않는다).
apply_secret app queue-secrets "REDIS_PASSWORD=${REDIS_PASS}"

# ---------- 4. app-admin-token ----------
echo "[4/5] app-admin-token"
# 대체 명령(난수를 인자로 넘기지 않는다 — 명령 치환 결과가 kubectl 이 도는 동안 ps 에 보인다):
#   printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: app-admin-token, namespace: app}\ntype: Opaque\ndata: {ADMIN_TOKEN: %s}\n' \
#     "$(openssl rand -hex 24 | tr -d '\n' | base64 | tr -d '\n')" | kubectl --context cgv-stg apply -f -
if eks -n app get secret app-admin-token >/dev/null 2>&1; then
  echo "  이미 있다 — 그대로 둔다. 다시 만들면 떠 있는 파드가 받은 값과 어긋난다."
else
  apply_secret app app-admin-token "ADMIN_TOKEN=$(rand)"
fi

# ---------- 5. grafana-admin ----------
echo "[5/5] grafana-admin"
# 대체 명령(위와 같은 이유로 인자 대신 stdin):
#   printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: grafana-admin, namespace: observability}\ntype: Opaque\ndata: {admin-user: %s, admin-password: %s}\n' \
#     "$(printf '%s' admin | base64 | tr -d '\n')" "$(openssl rand -hex 24 | tr -d '\n' | base64 | tr -d '\n')" | kubectl --context cgv-stg apply -f -
if eks -n observability get secret grafana-admin >/dev/null 2>&1; then
  echo "  이미 있다 — 그대로 둔다. Grafana 는 관리자 비밀번호를 첫 기동 때 한 번만 쓴다."
else
  apply_secret observability grafana-admin "admin-user=admin" "admin-password=$(rand)"
fi

echo
echo "Grafana 로그인은 admin 과 아래 값이다."
echo "  kubectl --context ${EKS_CONTEXT} -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
