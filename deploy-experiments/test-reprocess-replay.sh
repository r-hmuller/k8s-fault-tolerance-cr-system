#!/bin/bash
# Teste E2E do replay pós-restore (durabilidade de writes pós-snapshot).
#
# Cenário: um write aplicado DEPOIS do último checkpoint e ANTES do kill do pod
# é perdido quando o cri-o restaura o checkpoint. O interceptor deve detectar a
# recuperação (heartbeat/canário) e re-aplicar o buffer pós-snapshot.
#
# Passos:
#   1. Liga checkpoint (intervalo SNAP_INTERVAL) e reinicia o interceptor
#   2. Escreve PRE_KEY  (entra no checkpoint do passo 3)
#   3. Espera o 1º snapshot concluir
#   4. Escreve POST_KEY (pós-snapshot; confirma aplicado direto no kv-test)
#   5. Mata o pod kv-test  -> restore do checkpoint (estado SEM POST_KEY)
#   6. Espera o pod voltar e o tráfego normalizar
#   7. ASSERT: POST_KEY presente de novo (replay re-aplicou)  [pré-fix: 404]
#      ASSERT: PRE_KEY presente (veio do checkpoint)
#   8. Cleanup: checkpoint off
#
# Exit 0 = replay funcionou; exit 1 = write pós-snapshot perdido (bug).
set -uo pipefail
cd "$(dirname "$0")"

CP=${CP:-cp}
INT_URL=${INT_URL:-http://10.10.1.2:30847}   # via interceptor
KV_URL=${KV_URL:-http://10.10.1.2:30869}     # direto no kv-test
SNAP_INTERVAL=${SNAP_INTERVAL:-180}
RUN_ID=$(date +%s)
PRE_KEY=900001; PRE_VAL="pre-$RUN_ID"
POST_KEY=900002; POST_VAL="post-$RUN_ID"

log() { echo "[$(date +%H:%M:%S)] $*"; }
kv_get_direct() { ssh -o BatchMode=yes "$CP" "curl -s --max-time 5 -w '|%{http_code}' '$KV_URL/?key=$1'" 2>/dev/null; }
int_post() { ssh -o BatchMode=yes "$CP" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -d 'key=$1&value=$2' '$INT_URL/'" 2>/dev/null; }

cleanup() { ssh -o BatchMode=yes "$CP" "kubectl set env deploy/interceptor CHECKPOINT_ENABLED=false CHECKPOINT_INTERVAL=30 >/dev/null" 2>/dev/null || true; }
trap cleanup EXIT

log "1. Checkpoint ON (intervalo ${SNAP_INTERVAL}s) + restart do interceptor"
ssh -o BatchMode=yes "$CP" "kubectl set env deploy/interceptor CHECKPOINT_ENABLED=true CHECKPOINT_INTERVAL=$SNAP_INTERVAL >/dev/null && kubectl rollout restart deploy/interceptor >/dev/null && kubectl rollout status deploy/interceptor --timeout=120s >/dev/null"
sleep 3
INT_POD=$(ssh -o BatchMode=yes "$CP" "kubectl get pods -l app=interceptor --field-selector=status.phase=Running --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}'")
log "   interceptor pod: $INT_POD"

log "2. Write PRE: key=$PRE_KEY val=$PRE_VAL (via interceptor)"
code=$(int_post "$PRE_KEY" "$PRE_VAL")
[ "$code" = "204" ] || { echo "ERRO: POST PRE http=$code"; exit 2; }

log "3. Aguardando 1º snapshot concluir (~${SNAP_INTERVAL}s + bloqueio)..."
deadline=$(( $(date +%s) + SNAP_INTERVAL + 180 ))
while :; do
  n=$(ssh -o BatchMode=yes "$CP" "kubectl logs deploy/interceptor 2>/dev/null | grep -c 'Snapshot complete, requests unblocked' || true" | tr -d '[:space:]')
  [ "${n:-0}" -ge 1 ] && break
  [ "$(date +%s)" -gt "$deadline" ] && { echo "ERRO: snapshot 1 não concluiu no prazo"; exit 2; }
  sleep 10
done
log "   snapshot 1 concluído"

log "4. Write POST: key=$POST_KEY val=$POST_VAL (via interceptor; pós-snapshot)"
code=$(int_post "$POST_KEY" "$POST_VAL")
[ "$code" = "204" ] || { echo "ERRO: POST POST http=$code"; exit 2; }
resp=$(kv_get_direct "$POST_KEY")
echo "$resp" | grep -q "\"$POST_VAL\"|200" || { echo "ERRO: POST_KEY não aplicado no kv ($resp)"; exit 2; }
log "   confirmado no kv-test: $resp"

log "5. Matando o pod kv-test"
KV_POD=$(ssh -o BatchMode=yes "$CP" "kubectl get pod -l app=kv-test -o jsonpath='{.items[0].metadata.name}'")
ssh -o BatchMode=yes "$CP" "kubectl delete pod $KV_POD >/dev/null" &
log "   pod $KV_POD deletado (restore do checkpoint a caminho)"

log "6. Aguardando pod voltar Ready + tráfego normalizar"
ssh -o BatchMode=yes "$CP" "kubectl rollout status deploy/kv-test-deployment --timeout=180s >/dev/null" || true
OLD=$(ssh -o BatchMode=yes "$CP" "kubectl get pods -l app=kv-test --no-headers 2>/dev/null | awk '/Terminating/{print \$1}'")
[ -n "$OLD" ] && ssh -o BatchMode=yes "$CP" "kubectl delete pod $OLD --force --grace-period=0 >/dev/null 2>&1" || true
deadline=$(( $(date +%s) + 120 ))
while :; do
  resp=$(kv_get_direct "$PRE_KEY")
  echo "$resp" | grep -q "|200$" && break
  [ "$(date +%s)" -gt "$deadline" ] && { echo "ERRO: kv-test não voltou a servir"; exit 2; }
  sleep 5
done
log "   kv-test servindo de novo (PRE_KEY=$resp)"

log "7. Aguardando janela de replay (até 90s) e verificando POST_KEY..."
deadline=$(( $(date +%s) + 90 ))
found=0
while :; do
  resp=$(kv_get_direct "$POST_KEY")
  if echo "$resp" | grep -q "\"$POST_VAL\"|200"; then found=1; break; fi
  [ "$(date +%s)" -gt "$deadline" ] && break
  sleep 5
done

echo
echo "================== RESULTADO (run=$RUN_ID) =================="
echo "PRE_KEY  ($PRE_KEY): $(kv_get_direct "$PRE_KEY")   (esperado: \"$PRE_VAL\"|200 — vem do checkpoint)"
echo "POST_KEY ($POST_KEY): $(kv_get_direct "$POST_KEY")   (esperado: \"$POST_VAL\"|200 — via REPLAY)"
echo "--- logs de replay/canário no interceptor ---"
ssh -o BatchMode=yes "$CP" "kubectl logs deploy/interceptor 2>/dev/null | grep -iE 'replay|regression|Recovery detected' | tail -6" || true
if [ "$found" = "1" ]; then
  echo "PASS: write pós-snapshot sobreviveu ao restore (replay funcionou)"
  exit 0
else
  echo "FAIL: write pós-snapshot PERDIDO no restore (replay não aconteceu)"
  exit 1
fi
