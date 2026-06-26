#!/bin/bash
# Continua o sweep a partir de N=5, reaproveitando experimento existente.
set -euo pipefail
cd "$(dirname "$0")"

EXP_DIR=$(ls -dt experiments-logs/kv-sweep-* | head -1)
REMOTE_FW="/tmp/kv-sweep-cont-$(date +%H%M%S)"
MASTER=node1.example.net
THREADS=16; SECS=90; THINK=0
SERVER_URL=http://10.10.1.2:30869
CTRL="$HOME/.ssh/cm-youruser@${MASTER}:22"

export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

# Script de merge (debug -> stderr, dados -> stdout/outfile)
MERGE_PY='
import sys, glob
pattern, outfile, secs_str = sys.argv[1], sys.argv[2], sys.argv[3]
secs = int(secs_str)
files = sorted(glob.glob(pattern))
if not files:
    print(f"WARN: sem arquivos em {pattern}", file=sys.stderr)
    sys.stdout.write("--- Status Counts ---\n204,0\n--- Latencies ---\n")
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
import io, os
out = sys.stdout if outfile == "/dev/stdout" else open(outfile, "w")
out.write("--- Status Counts ---\n204,"+str(ok)+"\n--- Latencies ---\n")
out.write("\n".join(lats)+"\n")
if outfile != "/dev/stdout": out.close()
lat_v = sorted([float(l.split(",")[1])*1000 for l in lats])
pct = lambda q: lat_v[min(len(lat_v)-1,int(len(lat_v)*q))] if lat_v else float("nan")
print(f"{len(files)} files | {len(lats)} pts | ok={ok} | rps={ok/secs:.1f} | p50={pct(.5):.0f}ms p95={pct(.95):.0f}ms p99={pct(.99):.0f}ms", file=sys.stderr)
'

kv_restart_count() {
  ssh worker \
    "sudo crictl inspect \$(sudo crictl ps --name kv-test-container -q 2>/dev/null | head -1) 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"status\"][\"restartCount\"])' 2>/dev/null || echo 0"
}

# Garante ControlMaster ativo e copia merge script
ssh -o ControlMaster=auto -o "ControlPath=$CTRL" -o ControlPersist=3600 \
    "youruser@$MASTER" "mkdir -p $REMOTE_FW"
ssh -o ControlMaster=auto -o "ControlPath=$CTRL" -o ControlPersist=3600 \
    "youruser@$MASTER" "python3 -c '$MERGE_PY' --help 2>/dev/null; cat > /tmp/kv_merge2.py" <<< "$MERGE_PY"

RESTART_BASELINE=$(kv_restart_count)
echo "==> Continuando sweep N=5-9 | $EXP_DIR | $(date +%H:%M:%S)"

for N in 5 6 7 8 9; do
  OD="$EXP_DIR/${N}-clients"
  mkdir -p "$OD"
  RFILE="$REMOTE_FW/${N}_clients_${THREADS}_threads_${THINK}_thinking.txt"
  echo ""
  echo "==> N=$N  $(date +%H:%M:%S)"

  set +e
  NUM_CLIENT=$N NUM_THREAD=$THREADS SECONDS_TO_RUN=$SECS \
    SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME=$THINK \
    ansible-playbook -f 12 -i "ansible-tests/sweep-inv-${N}.yaml" ansible-tests/run-tests.yaml \
    >"$OD/ansible.log" 2>&1; rc=$?
  set -e

  # Stream merge via ControlMaster numa única conexão (sem scp)
  ssh -o ControlMaster=no -o "ControlPath=$CTRL" "youruser@$MASTER" \
    "python3 /tmp/kv_merge2.py '${RFILE}.pid*' /dev/stdout $SECS; \
     rm -f ${RFILE}.pid* 2>/dev/null || true" \
    > "$OD/latency.txt"

  # Verifica restart
  RESTART_NOW=$(kv_restart_count)
  [[ "$RESTART_NOW" -gt "$RESTART_BASELINE" ]] && \
    echo "    *** AVISO: container reiniciou! ($RESTART_BASELINE -> $RESTART_NOW) ***" && \
    RESTART_BASELINE=$RESTART_NOW || true

  # Métricas locais
  python3 - "$OD/latency.txt" "$SECS" "$N" "$EXP_DIR/summary.txt" <<'PY'
import sys
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
echo "==> RESUMO FINAL"
cat "$EXP_DIR/summary.txt"
echo ""
python3 plot_client_sweep.py "$EXP_DIR"
