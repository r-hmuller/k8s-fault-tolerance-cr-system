#!/bin/bash
# Testes de snapshot periódico e de restore (kill do pod) sob carga.
#
# Mecânica: 4 máquinas-cliente (sweep-inv-4) rodam kv-python-benchmark/main.py
# batendo no INTERCEPTOR (10.10.1.2:30847). O interceptor faz checkpoint do
# kv-test a cada CHECKPOINT_INTERVAL s (via cr-daemon). Tráfego passa pelo
# interceptor pra que o drain de in-flight do snapshot apareça na latência servida.
#
# Parâmetros deste experimento (fixos): 4 clientes, 8 threads, think=0.03,
# 600s, snapshot a cada 240s, seed de 100.000 registros, max key = 100.000.
#
# Fases (subcomando):
#   prep      edita benchmark.py p/ randint(0, 100_000) nos 4 nós + liga checkpoint (240s)
#   snapshot  seed -> roll interceptor -> carga 600s (sem kill)        -> experiments-logs/snapshot-<id>
#   restore   seed -> roll interceptor -> carga 600s + kill pod @310   -> experiments-logs/restore-<id>
#   revert    volta benchmark.py p/ randint(0, 1_000_000) nos 4 nós
#   all       prep ; snapshot ; restore ; revert
set -euo pipefail
cd "$(dirname "$0")"

# ---- Config (override por env) ----
NCLIENTS=4
THREADS=${THREADS:-8}
DURATION=${DURATION:-600}
THINK=${THINK:-0.03}
SNAP_INTERVAL=${SNAP_INTERVAL:-240}
SEED_QTY=${SEED_QTY:-100000}
SEED_SIZE=${SEED_SIZE:-1024}
MAXKEY=${MAXKEY:-100000}
KILL_AT=${KILL_AT:-310}

INTERCEPTOR_URL=${INTERCEPTOR_URL:-http://10.10.1.2:30847}
KV_URL=${KV_URL:-http://10.10.1.2:30869}
CP=${CP:-cp}
WORKER=${WORKER:-worker}
DAEMON_LOG=/var/log/k8s-cr-daemon.err

INV=ansible-tests/sweep-inv-4.yaml
PLAY=ansible-tests/run-tests.yaml
# Hosts em sweep-inv-4.yaml (client_master + client_nodes)
CLIENT_HOSTS=(node1 node2 node3 node4)
SSH_USER=youruser

export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

log() { echo "[$(date +%H:%M:%S)] $*"; }

warm_ssh() {
  for h in "${CLIENT_HOSTS[@]}"; do
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$node1.example.net" true 2>/dev/null || true
  done
}

# ---- tuning TCP dos clientes ----
# Bloqueios longos do interceptor seguram 1 conexão por request em vôo
# (~15K/máquina num bloqueio de 60s); o range default (32768-60999 = 28K) +
# TIME_WAIT de 60s esgota portas efêmeras e gera exceções de conexão no
# cliente que contaminam a taxa de erro. tw_reuse reaproveita sockets em
# TIME_WAIT pra novas conexões de saída (seguro, RFC 6191 via timestamps).
# Sysctl é runtime: re-aplicar a cada experimento Emulab (nó é re-imageado).
tune_clients() {
  log "Tuning TCP nos clientes (port range 1024-65535 + tcp_tw_reuse)"
  for h in "${CLIENT_HOSTS[@]}"; do
    ssh -o BatchMode=yes "$SSH_USER@$node1.example.net" \
      'sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535" -w net.ipv4.tcp_tw_reuse=1 >/dev/null' \
      && echo "  $h ok"
  done
}

# ---- benchmark.py max key ----
set_maxkey() {
  local val="$1"
  log "Ajustando max key -> randint(0, $val) nos ${#CLIENT_HOSTS[@]} nós"
  for h in "${CLIENT_HOSTS[@]}"; do
    ssh -o BatchMode=yes "$SSH_USER@$node1.example.net" \
      "sed -i 's/randint(0, [0-9_]*)/randint(0, $val)/' ~/kv-python-benchmark/benchmark.py && \
       grep -n 'randint(0, ' ~/kv-python-benchmark/benchmark.py | head -1" \
      | sed "s/^/  $h: /"
  done
}

# ---- seed ----
seed_kv() {
  log "Seed: $SEED_QTY registros (size=$SEED_SIZE) em kv-test ($KV_URL/seed)"
  local code
  code=$(ssh -o BatchMode=yes "$CP" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 180 -X POST $KV_URL/seed -d 'quantity=$SEED_QTY&size=$SEED_SIZE'")
  log "  seed http=$code"
  [ "$code" = "204" ] || { echo "ERRO: seed falhou (http=$code)"; exit 1; }
}

# ---- interceptor ----
config_interceptor() {
  log "Interceptor: CHECKPOINT_ENABLED=true CHECKPOINT_INTERVAL=$SNAP_INTERVAL"
  ssh -o BatchMode=yes "$CP" \
    "kubectl set env deploy/interceptor CHECKPOINT_ENABLED=true CHECKPOINT_INTERVAL=$SNAP_INTERVAL && \
     kubectl rollout status deploy/interceptor --timeout=120s >/dev/null"
}

roll_interceptor() {
  log "Reiniciando interceptor (zera o timer de $SNAP_INTERVAL s)"
  ssh -o BatchMode=yes "$CP" \
    "kubectl rollout restart deploy/interceptor && kubectl rollout status deploy/interceptor --timeout=120s >/dev/null"
}

snap_count() { ssh -o BatchMode=yes "$WORKER" "sudo grep -c '\"status\":\"$1\"' $DAEMON_LOG 2>/dev/null" || echo 0; }

# ---- carga ----
# run_load <run_dir> <kill_at|0>
run_load() {
  local run_dir="$1" kill_at="$2"
  local base; base=$(basename "$run_dir")
  local fw="/tmp/$base"
  mkdir -p "$run_dir"

  log "Preparando dir remoto $fw nos clientes"
  for h in "${CLIENT_HOSTS[@]}"; do
    ssh -o BatchMode=yes "$SSH_USER@$node1.example.net" "rm -rf $fw && mkdir -p $fw"
  done

  local ok_before fail_before
  ok_before=$(snap_count completed); fail_before=$(snap_count failed)

  local killer_pid=""
  if [ "$kill_at" != "0" ]; then
    ( sleep "$kill_at"
      local t0; t0=$(date +%s)
      local pod; pod=$(ssh -o BatchMode=yes "$CP" "kubectl get pod -l app=kv-test -o jsonpath='{.items[0].metadata.name}'")
      ssh -o BatchMode=yes "$CP" "kubectl delete pod $pod" >/dev/null 2>&1 || true
      echo "kill_at_offset=$kill_at pod=$pod epoch=$t0" > "$run_dir/kill.log"
      log "[t+${kill_at}s] kv-test pod morto: $pod"
    ) &
    killer_pid=$!
  fi

  local start_epoch; start_epoch=$(date +%s)
  log "Carga: $NCLIENTS clientes x $THREADS threads x ${DURATION}s, think=$THINK, url=$INTERCEPTOR_URL"
  set +e
  NUM_CLIENT=$NCLIENTS NUM_THREAD=$THREADS SECONDS_TO_RUN=$DURATION \
    SERVER_URL="$INTERCEPTOR_URL" FILE_TO_WRITE="$fw" THINKING_TIME="$THINK" \
    ansible-playbook -f 12 -i "$INV" "$PLAY" -e "should_populate_database=False" \
    >"$run_dir/ansible.log" 2>&1
  local rc=$?
  set -e
  log "Ansible rc=$rc (ver $run_dir/ansible.log)"
  [ -n "$killer_pid" ] && wait "$killer_pid" || true

  log "Coletando .pid* dos clientes -> $run_dir/<host>/"
  for h in "${CLIENT_HOSTS[@]}"; do
    mkdir -p "$run_dir/$h"
    scp -q "$SSH_USER@$node1.example.net:$fw/"*.pid* "$run_dir/$h/" 2>/dev/null || echo "  WARN: sem .pid em $h"
  done

  local ok_after fail_after
  ok_after=$(snap_count completed); fail_after=$(snap_count failed)
  {
    echo "clients=$NCLIENTS threads=$THREADS duration=${DURATION}s think=$THINK"
    echo "snap_interval=${SNAP_INTERVAL}s seed_qty=$SEED_QTY seed_size=$SEED_SIZE max_key=$MAXKEY"
    echo "server_url=$INTERCEPTOR_URL start_epoch=$start_epoch"
    echo "snapshots_completed=$((ok_after - ok_before)) snapshots_failed=$((fail_after - fail_before))"
    if [ "$kill_at" != "0" ]; then echo "kill_at=${kill_at}s"; fi
  } | tee "$run_dir/params.txt"

  summarize "$run_dir" || true
}

# Agrega rps/erros/percentis dos .pid* coletados.
summarize() {
  python3 - "$1" "$DURATION" <<'PY'
import sys, glob, os
base, secs = sys.argv[1], int(sys.argv[2])
ok=err=0; lat=[]
for f in glob.glob(os.path.join(base,"*","*.pid*")):
    sec=None
    for ln in open(f, errors="ignore"):
        ln=ln.strip()
        if ln=="--- Status Counts ---": sec="s"; continue
        if ln=="--- Latencies ---":     sec="l"; continue
        if ln.startswith("---"):        sec=None; continue
        if sec=="s" and "," in ln:
            k,v=ln.split(",",1)
            try: n=int(v)
            except: continue
            if k=="204": ok+=n
            else: err+=n
        elif sec=="l" and "," in ln:
            try: lat.append(float(ln.split(",")[1])*1000)
            except: pass
lat.sort()
p=lambda q: lat[min(len(lat)-1,int(len(lat)*q))] if lat else float("nan")
tot=ok+err
print(f"\n--- RESUMO {os.path.basename(base)} ---")
print(f"ok(204)={ok} err={err} total={tot} taxa_erro={100*err/tot if tot else 0:.1f}% rps_medio={ok/secs:.1f}")
print(f"p50={p(.5):.1f}ms p95={p(.95):.1f}ms p99={p(.99):.1f}ms p999={p(.999):.1f}ms max={max(lat) if lat else 0:.0f}ms")
PY
}

# Verifica amostra de chaves semeadas após restore.
verify_seed() {
  local run_dir="$1"
  log "Verificação pós-restore (amostra de chaves semeadas)"
  ssh -o BatchMode=yes "$CP" 'for k in 1 50 500 5000 50000 99999 0 100001; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "'"$KV_URL"'/?key=$k")
    echo "  key=$k http=$code"
  done' | tee "$run_dir/verify.log"
}

# ---- fases ----
phase_prep() {
  warm_ssh
  tune_clients
  set_maxkey "$MAXKEY"
  config_interceptor
}

phase_snapshot() {
  local id; id=$(date +%Y%m%d-%H%M%S)
  local run_dir="experiments-logs/snapshot-$id"
  log "===== SNAPSHOT-ONLY (run=$run_dir) ====="
  seed_kv
  roll_interceptor
  run_load "$run_dir" 0
  log "Snapshot run pronto: $run_dir"
}

phase_restore() {
  local id; id=$(date +%Y%m%d-%H%M%S)
  local run_dir="experiments-logs/restore-$id"
  log "===== RESTORE (kill @${KILL_AT}s) (run=$run_dir) ====="
  seed_kv
  roll_interceptor
  run_load "$run_dir" "$KILL_AT"
  sleep 10
  ssh -o BatchMode=yes "$CP" "kubectl get pod -l app=kv-test -o wide" | tee -a "$run_dir/params.txt" || true
  verify_seed "$run_dir"
  log "Restore run pronto: $run_dir"
}

phase_revert() { warm_ssh; set_maxkey 1_000_000; }

case "${1:-}" in
  prep)     phase_prep ;;
  snapshot) phase_snapshot ;;
  restore)  phase_restore ;;
  revert)   phase_revert ;;
  all)      phase_prep; phase_snapshot; phase_restore; phase_revert ;;
  *) echo "uso: $0 {prep|snapshot|restore|revert|all}"; exit 1 ;;
esac
