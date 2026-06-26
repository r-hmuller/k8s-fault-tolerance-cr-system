#!/bin/bash
set -euo pipefail

CP=cp
WORKER=worker
HOST_DIR=/tmp/logs/kv-test
YAML='~/k8s-yamls/kv-test.yaml'
DEPLOYMENT=kv-test-deployment
SVC=kv-test-deployment
PORT=3000

source "$(dirname "$0")/lib.sh"

prep_host_dir "$WORKER" "$HOST_DIR"
apply_and_wait "$CP" "$YAML" "$DEPLOYMENT"
ensure_nodeport_svc "$CP" "$DEPLOYMENT" "$SVC" "$PORT"

KV_NP=$(get_nodeport "$CP" "$SVC")
[ -n "$KV_NP" ] || { echo "Falhou ao ler NodePort de $SVC"; exit 1; }
echo "kv-test NodePort: $KV_NP"

# Atualiza APPLICATION_URL e APPLICATION_PORT no interceptor.yml (no CP).
# sed N junta a linha "- name: APPLICATION_PORT" com a "value: ..." seguinte.
ssh "$CP" 'bash -s' <<EOF
set -e
sed -i -E 's|(value: "http://10\.10\.1\.2:)[0-9]+(")|\1$KV_NP\2|' ~/k8s-yamls/interceptor.yml
sed -i -E '/- name: APPLICATION_PORT/{N;s|(value: ")[0-9]+(")|\1$KV_NP\2|}' ~/k8s-yamls/interceptor.yml
EOF
echo "interceptor.yml atualizado: APPLICATION_URL/APPLICATION_PORT -> $KV_NP"
