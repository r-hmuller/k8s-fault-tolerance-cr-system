#!/bin/bash
# Sweep de saturação do kv-test: roda o benchmark ansible com 1,2,...,MAX clientes
# (sem pod-kill, sem checkpoint) batendo no NodePort do kv-test, e coleta os logs
# no layout que o plot_all.py espera (experiments-logs/<run>/<N>-clients/).
#
# SSH: usa ControlMaster (~/.ssh/config Host node*.example.net) — cada host autentica
# UMA vez e ssh/scp/ansible reusam o socket. Sem isso, o burst de conexões estoura
# o agente 1Password ("Too many authentication failures").
#
# Vars (opcionais, defaults entre parênteses):
#   MAX            (10)   nº máximo de clientes do sweep (1..MAX)
#   START          (1)    primeiro N do sweep (pra resumir um sweep parcial)
#   SECONDS_TO_RUN (300)  duração de cada round
#   NUM_THREAD     (4)    processos por host (benchmark.py forks com multiprocessing)
#   SERVER_URL     (http://10.10.1.2:30923)  NodePort do kv-test
#   RUN_ID         ($(date))  identificador do sweep (sobrescreva pra reusar dir)
set -euo pipefail

cd "$(dirname "$0")"
source ./lib.sh

MAX=${MAX:-10}
START=${START:-1}
SECONDS_TO_RUN=${SECONDS_TO_RUN:-300}
NUM_THREAD=${NUM_THREAD:-4}
SERVER_URL=${SERVER_URL:-http://10.10.1.2:30923}
THINKING_TIME=${THINKING_TIME:-0.01}
THINK="$THINKING_TIME"   # tem que casar com o nome de arquivo que o playbook gera
PLAYBOOK=run-tests.yaml
MASTER=node1.example.net
NODES=(node1 node2 node3 node4 node5 node6 node7 node8 node9)

RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
RESULTS="experiments-logs/kv-test-$RUN_ID"
REMOTE_FW="/tmp/sat-$RUN_ID"   # host-local: /users/youruser é NFS com quota de 1G

# ssh/scp resilientes: retry com backoff, nunca abortam o sweep (só logam WARN).
rssh() { local i; for i in 1 2 3; do ssh -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; sleep $((i*3)); done; return 1; }
rscp() { local i; for i in 1 2 3; do scp -q -o BatchMode=yes -o ConnectTimeout=15 "$@" && return 0; sleep $((i*3)); done; return 1; }

# Ansible TEM que reusar os MESMOS control sockets que aquecemos abaixo. Por
# default ansible usa ControlPath próprio (~/.ansible/cp) e, com -f, autentica
# vários hosts em paralelo via agente 1Password → "Too many authentication
# failures" / "communication with agent failed" (host vira UNREACHABLE). Forçando
# o mesmo ControlPath do ~/.ssh/config + persist cobrindo o sweep inteiro, o
# único auth por host é o do aquecimento (sequencial, 1/s) — zero storm.
export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False

echo "==> Pre-flight"
preflight_ssh cp
rm -f "$HOME"/.ssh/cm-*.example.net:* 2>/dev/null || true   # sockets limpos

echo "==> Aquecendo ControlMaster (auth calma, 1x por host)"
ALL_HOSTS=("$MASTER" $(printf '%node2.example.net ' "${NODES[@]}"))
for h in "${ALL_HOSTS[@]}"; do
  rssh "youruser@$h" true && echo "    $h ok" || echo "    $h WARN (segue)"
  sleep 1
done

# Cada PROCESSO do benchmark grava seu próprio arquivo .pid<PID> em FILE_TO_WRITE
# (ver benchmark.py). Antes era só master que precisava do dir; agora todos os
# hosts onde algum processo roda precisam.
echo "==> Preparando dir remoto em todos os hosts"
for h in "${ALL_HOSTS[@]}"; do
  rssh "youruser@$h" "mkdir -p $REMOTE_FW" || { echo "ERRO: mkdir remoto falhou em $h"; exit 1; }
done
mkdir -p "$RESULTS"
echo "run_id=$RUN_ID server=$SERVER_URL secs=$SECONDS_TO_RUN threads=$NUM_THREAD think=$THINKING_TIME max=$MAX" | tee "$RESULTS/params.txt"

SWEEP_NS="${SWEEP_NS:-$(seq "$START" "$MAX")}"   # override com lista esparsa: SWEEP_NS="1 3 5 7 9"
for N in $SWEEP_NS; do
  if [ "$N" -eq 1 ]; then INV="ansible-tests/inventory-1client.yaml"; else INV="ansible-tests/inventory-${N}clients.yaml"; fi
  OUT="$RESULTS/${N}-clients"; mkdir -p "$OUT/per-host"
  REMOTE_FILE="$REMOTE_FW/${N}_clients_${NUM_THREAD}_threads_${THINK}_thinking.txt"

  # RESTART_DEPLOY=<deploy_name> reinicia a deployment indicada antes de cada
  # round (rollout restart no CP + wait for rollout). Útil pra zerar estado
  # em memória do interceptor entre rounds.
  if [ -n "${RESTART_DEPLOY:-}" ]; then
    echo "    Restart deploy/$RESTART_DEPLOY antes do round"
    ssh cp "kubectl rollout restart deploy/$RESTART_DEPLOY && kubectl rollout status deploy/$RESTART_DEPLOY --timeout=120s" >/dev/null 2>&1 \
      || echo "    WARN: restart de $RESTART_DEPLOY falhou"
    # Grace period: rollout status returns assim que o pod está Ready, mas
    # kube-proxy precisa de mais alguns segundos pra atualizar o endpoint do
    # Service. Sem essa pausa, o POST /testing/start do master ainda atinge o
    # pod antigo (morrendo) ou o novo (sem backend gRPC pronto) — em ambos os
    # casos o main_thread proc trava/morre, levando junto os outros procs do
    # mesmo host (multiprocessing parent espera children).
    sleep 15
  fi

  echo "==> Round N=$N  ($INV)  $(date +%H:%M:%S)"
  # -f >= N: run-tests.yaml é síncrono; sem forks suficientes os clientes não
  # batem concorrentemente e a curva de saturação fica inválida.
  set +e
  NUM_CLIENT=$N NUM_THREAD=$NUM_THREAD SECONDS_TO_RUN=$SECONDS_TO_RUN \
  SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME="$THINKING_TIME" \
    ansible-playbook -f 12 -i "$INV" "ansible-tests/$PLAYBOOK" >"$OUT/ansible.log" 2>&1
  rc=$?
  set -e
  [ $rc -eq 0 ] && echo "    round N=$N OK" || echo "    round N=$N ansible rc=$rc (segue; ver $OUT/ansible.log)"

  # /tmp é host-local. Cada host (master + N client_nodes) escreveu seus 4 .pid*
  # apenas localmente. Como cada host tem PID space próprio, vou pra subdirs
  # por host pra evitar colisão de nomes durante o scp (mesmo PID poderia
  # aparecer em dois hosts).
  ROUND_HOSTS=("$MASTER")
  for i in $(seq 0 $((N-1))); do
    ROUND_HOSTS+=("${NODES[$i]}.example.net")
  done
  collected_files=0
  for h in "${ROUND_HOSTS[@]}"; do
    shortname="${h%%.*}"
    hdir="$OUT/per-host/$shortname"
    mkdir -p "$hdir"
    if rscp "youruser@$h:${REMOTE_FILE}.pid*" "$hdir/" 2>/dev/null; then
      n=$(ls "$hdir"/*.pid* 2>/dev/null | wc -l)
      collected_files=$((collected_files + n))
    else
      echo "    WARN: scp falhou p/ $h (sem .pid* em $REMOTE_FILE)"
    fi
  done

  if [ "$collected_files" -gt 0 ]; then
    cat "$OUT/per-host/"*/*.pid* > "$OUT/latency.txt"
    awk '
      /^--- Latencies ---/{f=1; next}
      /^---/{f=0}
      f && /,/ { split($0,a,","); s=int(a[1]); if (s>0) c[s]++ }
      END { for (k in c) print k","c[k] }
    ' "$OUT/latency.txt" | sort -t, -k1,1n > "$OUT/throughput.log"
    # Conta só linhas de latência (ts,latency_em_segundos), não cabeçalhos nem status.
    lat=$(awk '/^--- Latencies ---/{f=1; next} /^---/{f=0} f && /,/ {c++} END{print c+0}' "$OUT/latency.txt")
    echo "    coletado: ${collected_files} arquivos .pid de ${#ROUND_HOSTS[@]} hosts em /tmp (${lat} amostras totais)"
  else
    echo "    WARN: nada coletado p/ N=$N (procurar em ${ROUND_HOSTS[*]}:${REMOTE_FILE}.pid*)"
  fi
done

echo "==> Gerando gráficos (plot_all.py)"
python3 plot_all.py "$RESULTS" >"$RESULTS/plot.log" 2>&1 \
  && echo "    plots em $RESULTS/plots/" \
  || echo "    plot_all.py falhou — ver $RESULTS/plot.log"

echo "==> FIM. Resultados: $RESULTS"
