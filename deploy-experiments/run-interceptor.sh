#!/bin/bash
set -euo pipefail

CP=cp
WORKER=worker
HOST_DIR=/tmp/logs/interceptor
YAML='~/k8s-yamls/interceptor.yml'
DEPLOYMENT=interceptor
SVC=interceptor
PORT=3000
ANSIBLE_DIR="$(dirname "$0")/ansible-tests"

source "$(dirname "$0")/lib.sh"

prep_host_dir "$WORKER" "$HOST_DIR"
apply_and_wait "$CP" "$YAML" "$DEPLOYMENT"

# Idempotente: só expõe + faz patch se a porta name=http ainda não existir.
# Pular reapply mantém o NodePort estável entre reruns (re-patch poderia reatribuir porta).
ssh "$CP" 'bash -s' <<EOF
set -e
if ! kubectl get svc $SVC -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null | grep -q .; then
  kubectl get svc $SVC >/dev/null 2>&1 || kubectl expose deployment/$DEPLOYMENT --type=NodePort --port=$PORT
  kubectl patch svc $SVC -p '{"spec":{"type":"NodePort","ports":[{"name":"grpc","port":51100,"targetPort":51100},{"name":"http","port":3000,"targetPort":3000}]}}'
fi
EOF

INT_HTTP_NP=$(get_nodeport "$CP" "$SVC" http)
[ -n "$INT_HTTP_NP" ] || { echo "Falhou ao ler NodePort http de $SVC"; exit 1; }
echo "interceptor http NodePort: $INT_HTTP_NP"

INT_GRPC_NP=$(get_nodeport "$CP" "$SVC" grpc)
[ -n "$INT_GRPC_NP" ] || { echo "Falhou ao ler NodePort grpc de $SVC"; exit 1; }
echo "interceptor grpc NodePort: $INT_GRPC_NP"

# Atualiza o default do server_url nos playbooks ansible (10.10.1.2 = CP).
perl -i -pe "s|(default='http://10\\.10\\.1\\.2:)[0-9]+(')|\${1}${INT_HTTP_NP}\${2}|" \
  "$ANSIBLE_DIR/run-tests.yaml" "$ANSIBLE_DIR/run-tests-with-pod-kill.yaml"
echo "ansible-tests server_url default -> http://10.10.1.2:$INT_HTTP_NP"

# CR_DAEMON_REPLY_TARGET aponta o daemon do worker pro gRPC do interceptor no CP.
# Só dá pra setar agora, depois que o NodePort grpc existe — por isso fica fora do setup-worker.sh.
# sed é idempotente: remove ocorrência anterior e re-anexa com o NodePort atual.
REPLY_TARGET="10.10.1.2:${INT_GRPC_NP}"
ssh "$WORKER" "bash -s" <<EOF
set -e
sudo sed -i -E '/^environment=/{s/,?CR_DAEMON_REPLY_TARGET=[^,]*//; s|\$|,CR_DAEMON_REPLY_TARGET=${REPLY_TARGET}|}' \
  /etc/supervisor/conf.d/k8s-cr-daemon.conf
sudo supervisorctl stop all
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start all || true
sudo supervisorctl status || true
EOF
