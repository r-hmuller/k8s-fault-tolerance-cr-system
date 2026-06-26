#!/bin/bash
# think=0.03, 90s — kv-test + interceptor 2vCPU + interceptor 6vCPU (4Gi)
set -euo pipefail
cd "$(dirname "$0")"

CAMPAIGN_ID=$(date +%Y%m%d-%H%M%S)
CAMPAIGN_DIR="experiments-logs/think03-2v6-$CAMPAIGN_ID"
mkdir -p "$CAMPAIGN_DIR"
MANIFEST="$CAMPAIGN_DIR/manifest.tsv"
printf "system\trun_dir\n" > "$MANIFEST"

run_sweep() {
  local LABEL=$1 SERVER_URL=$2 RESTART_DEPLOY=$3
  echo ""
  echo "########## $LABEL ##########"
  SWEEP_NS="1 2 3 4 5 6 7 8 9" \
  NUM_THREAD=12 \
  THINKING_TIME=0.03 \
  SECONDS_TO_RUN=90 \
  SERVER_URL="$SERVER_URL" \
  RESTART_DEPLOY="$RESTART_DEPLOY" \
    ./run-saturation-sweep.sh 2>&1 | tee "$CAMPAIGN_DIR/${LABEL}.log" | grep -E "==>|Round N=|round N=|coletado|WARN" || true
  local RUN_DIR=$(ls -td experiments-logs/kv-test-* | head -1)
  printf "%s\t%s\n" "$LABEL" "$RUN_DIR" >> "$MANIFEST"
  echo "    salvo: $RUN_DIR"
  sleep 10
}

echo "=== kv-test direto ==="
run_sweep "kv-test"           http://10.10.1.2:32541 kv-test-deployment

echo "=== set interceptor cpu=2, mem=4Gi ==="
ssh cp 'kubectl set resources deploy/interceptor --containers=kv-interceptor --requests=cpu=2,memory=4Gi --limits=cpu=2,memory=4Gi >/dev/null && kubectl rollout status deploy/interceptor --timeout=120s >/dev/null'
sleep 8
run_sweep "interceptor-2cpu"  http://10.10.1.2:32425 interceptor

echo "=== set interceptor cpu=6, mem=4Gi ==="
ssh cp 'kubectl set resources deploy/interceptor --containers=kv-interceptor --requests=cpu=6,memory=4Gi --limits=cpu=6,memory=4Gi >/dev/null && kubectl rollout status deploy/interceptor --timeout=120s >/dev/null'
sleep 8
run_sweep "interceptor-6cpu"  http://10.10.1.2:32425 interceptor

echo "=== FIM. Manifesto: $MANIFEST ==="
cat "$MANIFEST"
