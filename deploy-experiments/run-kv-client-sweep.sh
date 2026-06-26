#!/bin/bash
# Sweep de clientes direto no kv-test: warmup 20s (populate) + sweep 1-9 clientes x THREADS x 90s.
# Merge feito no próprio master (sem pipe SSH) para evitar falhas de autenticação.
set -euo pipefail
cd "$(dirname "$0")"

THREADS=${THREADS:-16}
SECS=90
WARMUP_SECS=20
THINK=${THINK:-0}
SERVER_URL=${SERVER_URL:-http://10.10.1.2:30869}
TARGET=${TARGET:-kv}
MASTER=node1.example.net
# Client nodes na MESMA ordem dos sweep-inv-N.yaml (round N usa os primeiros N-1).
NODES=(node1 node2 node3 node4 node5 node6 node7 node8)
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT="experiments-logs/${TARGET}-sweep-$RUN_ID"
mkdir -p "$OUT"
REMOTE_FW="/tmp/kv-sweep-$RUN_ID"
export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

# Script de merge que roda no próprio master
MERGE_SCRIPT=$(cat <<'PYEOF'
#!/usr/bin/env python3
import sys, glob
pattern, outfile, secs_str = sys.argv[1], sys.argv[2], sys.argv[3]
secs = int(secs_str)
files = sorted(glob.glob(pattern))
if not files:
    print(f"WARN: sem arquivos em {pattern}", file=sys.stderr)
    open(outfile, "w").write("--- Status Counts ---\n204,0\n--- Latencies ---\n")
    sys.exit(0)
ok, lats, sec = 0, [], None
for path in files:
    for ln in open(path):
        ln = ln.strip()
        if not ln: continue
        if ln == "--- Status Counts ---": sec="s"; continue
        if ln == "--- Latencies ---":     sec="l"; continue
        if ln.startswith("---"):          sec=None; continue
        if sec=="s" and ln.startswith("204,"):
            try: ok += int(ln.split(",")[1])
            except: pass
        elif sec=="l" and "," in ln:
            p = ln.split(",")
            if len(p)==2:
                try: float(p[0]); float(p[1]); lats.append(ln)
                except: pass
with open(outfile,"w") as f:
    f.write("--- Status Counts ---\n204,"+str(ok)+"\n--- Latencies ---\n")
    f.write("\n".join(lats)+"\n")
lat_v = sorted([float(l.split(",")[1])*1000 for l in lats])
p = lambda q: lat_v[min(len(lat_v)-1,int(len(lat_v)*q))] if lat_v else float("nan")
import sys
print(f"{len(files)} files | {len(lats)} pts | ok={ok} | rps={ok/secs:.1f} | p50={p(.5):.0f}ms p95={p(.95):.0f}ms p99={p(.99):.0f}ms", file=sys.stderr)
PYEOF
)

# restartCount do kv-test via kubectl no CP (ControlMaster) + timeout remoto.
# Antes era crictl-via-worker sem timeout — uma chamada pendurada travava o sweep
# inteiro (stall de ~40min observado entre rounds). timeout existe no remoto Linux.
kv_restart_count() {
  ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 cp \
    "timeout 20 kubectl get pod -l app=kv-test -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0"
}

echo "==> Warm SSH"
for h in "$MASTER" node2.example.net node3.example.net node4.example.net \
          node5.example.net node6.example.net node7.example.net node8.example.net node9.example.net; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "youruser@$h" true 2>/dev/null || true
done
ssh worker true 2>/dev/null || true

# /tmp é host-local: cada host (master + nodes) grava seus próprios .pid.
# Sem o dir em TODOS os nós, benchmark.py falha com FileNotFoundError e só o
# master gera dado medido → rps fica fixo (~1 cliente) independente de N.
echo "==> Preparando $REMOTE_FW no master + todos os client nodes"
for h in "$MASTER" "${NODES[@]/%/.example.net}"; do
  ssh -o BatchMode=yes -o ConnectTimeout=15 "youruser@$h" "mkdir -p $REMOTE_FW" \
    || { echo "ERRO: mkdir remoto falhou em $h"; exit 1; }
done
echo "$MERGE_SCRIPT" > "$OUT/kv_merge.py"   # merge roda local (coletando de todos)

RESTART_BASELINE=$(kv_restart_count)
echo "threads=$THREADS" > "$OUT/params.txt"
echo "==> Baseline restarts kv-test: $RESTART_BASELINE"
echo "==> SERVER_URL=$SERVER_URL  THREADS=$THREADS  SECS=$SECS"

# ─── Warmup ───────────────────────────────────────────────────────────────────
echo ""
echo "==> WARMUP ${WARMUP_SECS}s (populate=True, 1 cliente)  $(date +%H:%M:%S)"
mkdir -p "$OUT/warmup"
NUM_CLIENT=1 NUM_THREAD=$THREADS SECONDS_TO_RUN=$WARMUP_SECS \
  SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME=$THINK \
  ansible-playbook -f 12 -i ansible-tests/sweep-inv-1.yaml ansible-tests/run-tests.yaml \
    -e "should_populate_database=True" >"$OUT/warmup/ansible.log" 2>&1
ssh "youruser@$MASTER" "rm -f $REMOTE_FW/*.pid* 2>/dev/null || true"
echo "    Warmup concluído — descartando."

# ─── Sweep 1-9 ────────────────────────────────────────────────────────────────
echo ""
echo "==> Sweep 1-9 clientes (${THREADS} threads, ${SECS}s cada)"
printf "%-8s %-10s %-8s %-8s %-8s\n" "clients" "rps" "p50ms" "p95ms" "p99ms" | tee "$OUT/summary.txt"

for N in $(seq 1 9); do
  OD="$OUT/${N}-clients"
  mkdir -p "$OD"
  RFILE="$REMOTE_FW/${N}_clients_${THREADS}_threads_${THINK}_thinking.txt"

  echo ""
  echo "==> N=$N clientes  $(date +%H:%M:%S)"

  set +e
  NUM_CLIENT=$N NUM_THREAD=$THREADS SECONDS_TO_RUN=$SECS \
    SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME=$THINK \
    ansible-playbook -f 12 -i "ansible-tests/sweep-inv-${N}.yaml" ansible-tests/run-tests.yaml \
    >"$OD/ansible.log" 2>&1; rc=$?
  set -e

  # Coleta os .pid de TODOS os hosts da rodada (master + N-1 nodes). scp reusa os
  # sockets ControlMaster (Host node*.example.net no ~/.ssh/config) → sem auth storm.
  # bash 3.2 (macOS): slice em vez de indexar elemento a elemento (${arr[i]} sob
  # set -u dispara "bad array subscript"). N=1 = só master.
  ROUND_HOSTS=("$MASTER")
  if [ "$N" -gt 1 ]; then
    for nd in "${NODES[@]:0:$((N-1))}"; do ROUND_HOSTS+=("$node10.example.net"); done
  fi
  PH="$OD/per-host"; mkdir -p "$PH"
  # Sem rm remoto por round: nome do arquivo inclui N (e o RUN_ID é único por
  # sistema), então não há colisão entre rounds — evita conexões ssh extras que
  # saturavam o agente 1Password. scp reusa o socket ControlMaster (1 auth/host).
  for h in "${ROUND_HOSTS[@]}"; do
    sn="${h%%.*}"; mkdir -p "$PH/$sn"
    ok=0; for try in 1 2 3; do
      scp -q -o BatchMode=yes -o ConnectTimeout=20 "youruser@$h:${RFILE}.pid*" "$PH/$sn/" 2>/dev/null && { ok=1; break; }
      sleep $((try*2))
    done
    [ "$ok" -eq 1 ] || echo "    WARN: scp falhou p/ $h (sem .pid?)"
  done
  python3 "$OUT/kv_merge.py" "$PH/*/*.pid*" "$OD/latency.txt" "$SECS" 2>/dev/null \
    || echo "    WARN: merge local falhou (rc=$rc)"

  # Reaaplica sysctls no interceptor após cada round (sobrevive a OOM restarts).
  # timeout 25 remoto: kubectl exec sem bound já pendurou o sweep por ~40min.
  [[ "$SERVER_URL" == *":30847"* ]] && \
    ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 cp \
      'timeout 25 kubectl exec deployment/interceptor -- sh -c "sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1; sysctl -w net.ipv4.ip_local_port_range=1024\ 65535 >/dev/null 2>&1"' 2>/dev/null || true

  # Verifica restart
  RESTART_NOW=$(kv_restart_count)
  if [ "$RESTART_NOW" -gt "$RESTART_BASELINE" ]; then
    echo "    *** AVISO: container kv-test reiniciou! (baseline=$RESTART_BASELINE atual=$RESTART_NOW) ***"
    RESTART_BASELINE=$RESTART_NOW
  fi

  # Extrai e imprime métricas
  python3 - "$OD/latency.txt" "$SECS" "$N" "$OUT/summary.txt" <<'PY'
import sys, os
f_path, secs, N, summ = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ok, lat, sec = 0, [], None
for ln in open(f_path):
    ln=ln.strip()
    if ln=="--- Status Counts ---": sec="s"; continue
    if ln=="--- Latencies ---":     sec="l"; continue
    if ln.startswith("---"):        sec=None; continue
    if sec=="s" and ln.startswith("204,"): ok+=int(ln.split(",")[1])
    elif sec=="l" and "," in ln:
        try: lat.append(float(ln.split(",")[1])*1000)
        except: pass
lat.sort()
p=lambda q: lat[min(len(lat)-1,int(len(lat)*q))] if lat else float("nan")
row=f"{N:<8} {ok/secs:<10.1f} {p(.50):<8.1f} {p(.95):<8.1f} {p(.99):<8.1f}"
print(row); open(summ,"a").write(row+"\n")
PY
done

echo ""
echo "==> RESUMO"
cat "$OUT/summary.txt"
echo ""
echo "==> Resultados: $OUT"
echo "==> Gerando plot..."
python3 plot_client_sweep.py "$OUT"
