#!/usr/bin/env bash
# 장치(또는 사이트)별 API 키를 만들어 사용량 계획에 연결한다.
#   ./scripts/add-device-key.sh site-a-inv-001
# 키를 Terraform 밖에서 관리하므로 장치 수가 많아도 state가 커지지 않는다.
# 키 비활성화: aws apigateway update-api-key --api-key <id> --patch-operations op=replace,path=/enabled,value=false
set -euo pipefail

NAME="${1:?usage: $0 <key-name>}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

USAGE_PLAN_ID="$(terraform -chdir="$TF_DIR" output -raw usage_plan_id)"
PROJECT="$(terraform -chdir="$TF_DIR" output -raw delivery_stream_name)"
PROJECT="${PROJECT%-telemetry}"

KEY_JSON="$(aws apigateway create-api-key --name "${PROJECT}-${NAME}" --enabled \
  --tags "Project=${PROJECT},Device=${NAME}" --output json)"
KEY_ID="$(echo "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
KEY_VALUE="$(echo "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"

aws apigateway create-usage-plan-key --usage-plan-id "$USAGE_PLAN_ID" --key-id "$KEY_ID" --key-type API_KEY >/dev/null

echo "key name : ${PROJECT}-${NAME}"
echo "key id   : ${KEY_ID}"
echo "key value: ${KEY_VALUE}"
