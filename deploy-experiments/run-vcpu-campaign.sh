#!/bin/bash
# Campanha de comparação vCPU: sweep 1-9 clientes (8 procs/host, 90s, think=0.03)
# batendo em 4 sistemas:
#   1. kv-test direto         (cpu=1,  mem=3Gi)            -> :30869
#   2. interceptor 1 vCPU     (mem máx 6Gi)                -> :30847
#   3. interceptor 4 vCPU     (mem máx 6Gi)                -> :30847
#   4. interceptor 6 vCPU     (mem máx 6Gi)                -> :30847
#
# Reusa run-kv-client-sweep.sh (mecânica atual: master node1, sweep-inv-N,
# merge no master). Resources são ajustados via kubectl set resources + rollout
# entre sistemas. Manifesto lista o run_dir gerado por cada sistema.
set -euo pipefail
cd "$(dirname "$0")"

export THREADS=8        # "8 processos" = NUM_THREAD por host (benchmark.py forks)
export THINK=0.01
KV_URL=http://10.10.1.2:30869
INT_URL=http://10.10.1.2:30847

CAMPAIGN_ID=$(date +%Y%m%d-%H%M%S)
CAMPAIGN_DIR="experiments-logs/vcpu-campaign-$CAMPAIGN_ID"
mkdir -p "$CAMPAIGN_DIR"
MANIFEST="$CAMPAIGN_DIR/manifest.tsv"
printf "system\trun_dir\n" > "$MANIFEST"
echo "campaign_id=$CAMPAIGN_ID threads=$THREADS think=$THINK secs=90 clients=1..9" \
  | tee "$CAMPAIGN_DIR/params.txt"

run_one() {
  local LABEL=$1 URL=$2
  echo ""; echo "########## $LABEL ##########  $(date +%H:%M:%S)"
  if SERVER_URL="$URL" TARGET="$LABEL" ./run-kv-client-sweep.sh \
        2>&1 | tee "$CAMPAIGN_DIR/${LABEL}.log"; then
    :
  else
    echo "    WARN: $LABEL retornou erro (ver $CAMPAIGN_DIR/${LABEL}.log)"
  fi
  local RUN_DIR
  RUN_DIR=$(ls -td experiments-logs/"${LABEL}"-sweep-* 2>/dev/null | head -1)
  printf "%s\t%s\n" "$LABEL" "$RUN_DIR" >> "$MANIFEST"
  echo "    salvo: $RUN_DIR"
  sleep 10
}

set_interceptor() {
  local C=$1
  # O LIMIT de cpu (throttle CFS) é o que realiza "N vCPU". O request fica baixo
  # (500m) — alto (=C) estoura o nó de 8 CPU durante o surge do RollingUpdate
  # (kv-test 1 + sistema ~1 + 2x interceptor) → pod Pending por Insufficient cpu.
  # 500m também é <= limit no caso C=1 (request nunca pode exceder o limit).
  echo ""; echo "=== set interceptor limit cpu=$C, mem máx 6Gi (request cpu=500m) ==="
  ssh cp "kubectl set resources deploy/interceptor --containers=kv-interceptor \
      --requests=cpu=500m,memory=1Gi --limits=cpu=$C,memory=6Gi >/dev/null \
    && kubectl rollout status deploy/interceptor --timeout=180s >/dev/null"
  sleep 10
}

# Garante kv-test cpu=1 / mem=3Gi (idempotente; só rola pod se mudar algo).
echo ""; echo "=== garantindo kv-test cpu=1, mem=3Gi ==="
ssh cp 'kubectl set resources deploy/kv-test-deployment --containers=kv-test-container \
    --requests=cpu=1,memory=3Gi --limits=cpu=1,memory=3Gi >/dev/null \
  && kubectl rollout status deploy/kv-test-deployment --timeout=180s >/dev/null'
sleep 8

run_one "kv-direct" "$KV_URL"

set_interceptor 1; run_one "interceptor-1cpu" "$INT_URL"
set_interceptor 4; run_one "interceptor-4cpu" "$INT_URL"
set_interceptor 6; run_one "interceptor-6cpu" "$INT_URL"

echo ""; echo "=== FIM. Manifesto: $MANIFEST ==="
cat "$MANIFEST"
