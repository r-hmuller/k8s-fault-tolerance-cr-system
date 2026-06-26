#!/bin/bash
# Loop de cliente pro teste de snapshot/restore.
# Cada iteração: POST {key,value} -> GET ?key= e compara. Mantém arrays
# para verificação cross-restore quando o orquestrador chamar a etapa final.
#
# Args (posicionais):
#   $1 CLIENT_ID    inteiro, define o range de keys (id*1_000_000 + seq)
#   $2 KV_URL       ex: http://10.10.1.2:31385
#   $3 STOP_FLAG    arquivo cuja existência interrompe o loop
#   $4 LOG_FILE     log linha-a-linha (ts key expected post_code get_code status)
set -u

CLIENT_ID="$1"
KV_URL="$2"
STOP_FLAG="$3"
LOG="$4"

BASE_KEY=$((CLIENT_ID * 1000000))
seq=0
ok=0
post_fail=0
get_fail=0
mismatch=0

echo "# client=$CLIENT_ID base_key=$BASE_KEY url=$KV_URL started=$(date +%s)" >> "$LOG"

while [ ! -f "$STOP_FLAG" ]; do
  key=$((BASE_KEY + seq))
  expected="c${CLIENT_ID}-s${seq}-$(date +%s%N)"

  # POST: captura code e tempo total (s, com decimais) numa linha só
  post_resp=$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" --max-time 3 \
    -X POST -H "Content-Type: application/json" \
    -d "{\"key\":$key,\"value\":\"$expected\"}" \
    "${KV_URL}/" 2>/dev/null || echo "000 0.000")
  pc="${post_resp%% *}"
  post_t="${post_resp##* }"

  gc=000
  get_t=0.000
  body=""
  if [ "$pc" = "204" ]; then
    # GET: response body + code + tempo separados por delimitador raro
    get_resp=$(curl -sS --max-time 3 -w "|%{http_code} %{time_total}" "${KV_URL}/?key=$key" 2>/dev/null || echo "|000 0.000")
    body="${get_resp%|*}"
    tail="${get_resp##*|}"
    gc="${tail%% *}"
    get_t="${tail##* }"
    expected_json="\"$expected\""
    if [ "$gc" = "200" ] && [ "$body" = "$expected_json" ]; then
      ok=$((ok + 1))
      status=OK
    elif [ "$gc" = "200" ]; then
      mismatch=$((mismatch + 1))
      status=MISMATCH
    else
      get_fail=$((get_fail + 1))
      status=GET_FAIL
    fi
  else
    post_fail=$((post_fail + 1))
    status=POST_FAIL
  fi

  echo "$(date +%s) $key $expected $pc $gc $post_t $get_t $status" >> "$LOG"
  seq=$((seq + 1))
done

echo "# client=$CLIENT_ID stopped=$(date +%s) seq=$seq ok=$ok post_fail=$post_fail get_fail=$get_fail mismatch=$mismatch" >> "$LOG"
