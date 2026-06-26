#!/bin/bash
# Teste end-to-end de checkpoint+restore com 4 clientes batendo no kv-test.
# - Roda por DURATION segundos (default 1000)
# - Snapshots periódicos vêm do interceptor (CHECKPOINT_INTERVAL no yaml; precisa de CHECKPOINT_ENABLED=true)
# - Restores são disparados via kubectl rollout restart nos offsets de RESTORE_OFFSETS
# - Cada cliente roda em CP via ssh, escreve log linha-a-linha em /tmp/kv-restore-test/<run>/cN.log
# - No fim, agrega contagens, valida sample de keys antigas, e copia logs pra experiments-logs/
#
# Vars (todas opcionais, defaults entre parênteses):
#   DURATION         (1000)         segundos totais de teste
#   N_CLIENTS        (4)            número de clientes
#   RESTORE_OFFSETS  (200,400,600,800)  segundos do início pra cada rollout restart
#   KV_URL           (http://10.10.1.2:31385)
#   CP               (cp)    alias ssh do control plane
#   VERIFY_SAMPLE    (50)           keys aleatórias por cliente verificadas no fim
set -euo pipefail

DURATION=${DURATION:-1000}
N_CLIENTS=${N_CLIENTS:-4}
RESTORE_OFFSETS=${RESTORE_OFFSETS:-200,400,600,800}
KV_URL=${KV_URL:-http://10.10.1.2:31385}
CP=${CP:-cp}
VERIFY_SAMPLE=${VERIFY_SAMPLE:-50}

source "$(dirname "$0")/lib.sh"

echo "==> Pre-flight"
preflight_ssh "$CP"
ssh "$CP" "kubectl get pod -l app=kv-test --field-selector=status.phase=Running -o name 2>/dev/null | grep -q kv-test" \
  || { echo "ERRO: nenhum pod kv-test Running"; exit 1; }

INT_CHECKPOINT=$(ssh "$CP" "kubectl get pod -l app=interceptor -o jsonpath='{.items[0].spec.containers[0].env[?(@.name==\"CHECKPOINT_ENABLED\")].value}'" 2>/dev/null || true)
if [ "$INT_CHECKPOINT" != "true" ]; then
  echo "ERRO: interceptor sem CHECKPOINT_ENABLED=true (atual: '$INT_CHECKPOINT'). Edite ~/k8s-yamls/interceptor.yml e rode ./run-interceptor.sh."
  exit 1
fi

RUN_ID=$(date +%Y%m%d-%H%M%S)
TEST_DIR="/tmp/kv-restore-test/$RUN_ID"
ssh "$CP" "mkdir -p $TEST_DIR"
scp -q "$(dirname "$0")/scripts/restore-test-client.sh" "$CP:$TEST_DIR/"

echo "==> Iniciando $N_CLIENTS clientes ($KV_URL) — run=$RUN_ID"
# Marca offsets do log do daemon ANTES do teste pra contar snapshots por delta
# (kubectl logs --since gira o buffer e perde linhas durante runs longos).
WORKER_HOST=${WORKER_HOST:-worker}
DAEMON_LOG=/var/log/k8s-cr-daemon.err
SNAP_OK_BEFORE=$(ssh "$WORKER_HOST" "sudo grep -c '\"status\":\"completed\"' $DAEMON_LOG 2>/dev/null" || echo 0)
SNAP_FAIL_BEFORE=$(ssh "$WORKER_HOST" "sudo grep -c '\"status\":\"failed\"' $DAEMON_LOG 2>/dev/null" || echo 0)
START_EPOCH=$(date +%s)
for c in $(seq 1 "$N_CLIENTS"); do
  ssh "$CP" "nohup bash $TEST_DIR/restore-test-client.sh $c '$KV_URL' '$TEST_DIR/stop' '$TEST_DIR/c$c.log' </dev/null >$TEST_DIR/c$c.nohup 2>&1 &"
done

echo "==> Schedulando restores nos offsets: $RESTORE_OFFSETS"
RESTORE_LOG="$TEST_DIR/restores.log"
ssh "$CP" "echo '# offset epoch_at_trigger duration_s exit_code' > $RESTORE_LOG"
for offset in $(echo "$RESTORE_OFFSETS" | tr , ' '); do
  (
    sleep "$offset"
    t0=$(date +%s)
    ec=0
    ssh "$CP" "kubectl rollout restart deploy/kv-test-deployment >/dev/null && kubectl rollout status deploy/kv-test-deployment --timeout=120s >/dev/null" 2>&1 || ec=$?
    t1=$(date +%s)
    ssh "$CP" "echo '$offset $t0 $((t1 - t0)) $ec' >> $RESTORE_LOG"
    echo "[t+${offset}s] restore done in $((t1 - t0))s (exit=$ec)"
  ) &
done

echo "==> Aguardando $DURATION s..."
sleep "$DURATION"

echo "==> Parando clientes"
ssh "$CP" "touch $TEST_DIR/stop"
sleep 5
wait

echo "==> Verificação final (sample de $VERIFY_SAMPLE keys/cliente)"
ssh "$CP" "bash -s -- '$TEST_DIR' '$KV_URL' '$VERIFY_SAMPLE'" <<'VERIFY' || true
set -u
TEST_DIR="$1"; KV_URL="$2"; SAMPLE="$3"
DETAIL="$TEST_DIR/verify-detail.log"
: > "$DETAIL"
for log in "$TEST_DIR"/c*.log; do
  [ -f "$log" ] || continue
  cid=$(basename "$log" .log)
  shuf -n "$SAMPLE" <(grep " OK$" "$log") 2>/dev/null | while read -r ts key expected pc gc post_t get_t status; do
    body=$(curl -sS --max-time 3 "${KV_URL}/?key=$key" 2>/dev/null || echo "")
    expected_json="\"$expected\""
    if [ "$body" = "$expected_json" ]; then
      echo "$cid OK $key" >> "$DETAIL"
    elif [ "$body" = "\"Key not found\"" ] || [ -z "$body" ]; then
      echo "$cid NOT_FOUND $key expected=$expected_json" >> "$DETAIL"
    else
      echo "$cid MISMATCH $key expected=$expected_json got=$body" >> "$DETAIL"
    fi
  done
done
awk '{counts[$2]++; total++} END{print "verify_total=" total; for(k in counts) print "verify_" tolower(k) "=" counts[k]}' \
  "$DETAIL" > "$TEST_DIR/verify.log"
VERIFY

LOCAL_RESULTS="$(dirname "$0")/experiments-logs/restore-test-$RUN_ID"
mkdir -p "$LOCAL_RESULTS"
scp -q "$CP:$TEST_DIR/c*.log" "$CP:$TEST_DIR/restores.log" "$CP:$TEST_DIR/verify.log" "$CP:$TEST_DIR/verify-detail.log" "$LOCAL_RESULTS/" 2>/dev/null || true

echo
echo "===================== SUMMARY (run=$RUN_ID) ====================="
echo "duration=${DURATION}s clients=$N_CLIENTS restore_offsets=$RESTORE_OFFSETS"
echo
echo "--- Per-client (lines: ok/post_fail/get_fail/mismatch/total) ---"
for c in $(seq 1 "$N_CLIENTS"); do
  log="$LOCAL_RESULTS/c$c.log"
  [ -f "$log" ] || { echo "  c$c: log missing"; continue; }
  ok=$(awk '$NF=="OK"{n++} END{print n+0}' "$log")
  pf=$(awk '$NF=="POST_FAIL"{n++} END{print n+0}' "$log")
  gf=$(awk '$NF=="GET_FAIL"{n++} END{print n+0}' "$log")
  mm=$(awk '$NF=="MISMATCH"{n++} END{print n+0}' "$log")
  total=$((ok + pf + gf + mm))
  echo "  c$c: ok=$ok post_fail=$pf get_fail=$gf mismatch=$mm total=$total"
done

echo
echo "--- Restores ---"
cat "$LOCAL_RESULTS/restores.log" 2>/dev/null || echo "  (sem log de restores)"

echo
echo "--- Snapshots na janela do teste (delta no daemon log do worker) ---"
SNAP_OK_AFTER=$(ssh "$WORKER_HOST" "sudo grep -c '\"status\":\"completed\"' $DAEMON_LOG 2>/dev/null" || echo 0)
SNAP_FAIL_AFTER=$(ssh "$WORKER_HOST" "sudo grep -c '\"status\":\"failed\"' $DAEMON_LOG 2>/dev/null" || echo 0)
echo "  completed=$((SNAP_OK_AFTER - SNAP_OK_BEFORE)) failed=$((SNAP_FAIL_AFTER - SNAP_FAIL_BEFORE))"

echo
echo "--- Verificação final (cross-restore state preservation) ---"
cat "$LOCAL_RESULTS/verify.log" 2>/dev/null | grep "^verify_" || echo "  (sem dados de verify)"

echo
echo "Logs locais: $LOCAL_RESULTS/"
