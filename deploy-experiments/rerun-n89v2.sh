#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

EXP_DIR="experiments-logs/kv-sweep-20260604-115139"
REMOTE_FW="/tmp/kv-sweep-n89-$(date +%H%M%S)"
MASTER="node1.example.net"
THREADS=22; SECS=90; THINK=0
SERVER_URL="http://10.10.1.2:30869"

export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

# Cria diretório remoto
ssh "youruser@$MASTER" "mkdir -p $REMOTE_FW"

# Copia script de merge pro master
cat > /tmp/remote_merge.py << 'PYEOF'
#!/usr/bin/env python3
import sys, os, glob, json

pattern = sys.argv[1]
outfile = sys.argv[2]

files = sorted(glob.glob(pattern))
if not files:
    print(f"WARN: sem arquivos em {pattern}", file=sys.stderr)
    # Escreve arquivo vazio mas válido
    with open(outfile, "w") as f:
        f.write("--- Status Counts ---\n204,0\n--- Latencies ---\n")
    sys.exit(0)

ok, lats, sec = 0, [], None
for path in files:
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln: continue
            if ln == "--- Status Counts ---": sec="s"; continue
            if ln == "--- Latencies ---":     sec="l"; continue
            if ln.startswith("---"):          sec=None; continue
            if sec=="s" and ln.startswith("204,"):
                try: ok += int(ln.split(",")[1])
                except: pass
            elif sec=="l" and "," in ln:
                parts = ln.split(",")
                if len(parts)==2:
                    try: float(parts[0]); float(parts[1]); lats.append(ln)
                    except: pass

with open(outfile, "w") as f:
    f.write("--- Status Counts ---\n204," + str(ok) + "\n--- Latencies ---\n")
    f.write("\n".join(lats) + "\n")

lat_vals = sorted([float(l.split(",")[1])*1000 for l in lats])
p = lambda q: lat_vals[min(len(lat_vals)-1,int(len(lat_vals)*q))] if lat_vals else float("nan")
print(f"merged {len(files)} files: {len(lats)} pts ok={ok} rps={ok/90:.1f} p50={p(.5):.0f}ms p95={p(.95):.0f}ms p99={p(.99):.0f}ms")
PYEOF

scp -q /tmp/remote_merge.py "youruser@$MASTER:/tmp/remote_merge.py"

for N in 8 9; do
  OD="$EXP_DIR/${N}-clients"
  mkdir -p "$OD"
  RFILE="$REMOTE_FW/${N}_clients_${THREADS}_threads_${THINK}_thinking.txt"
  MERGED_REMOTE="$REMOTE_FW/merged_${N}.txt"
  echo "==> N=$N  $(date +%H:%M:%S)"

  NUM_CLIENT=$N NUM_THREAD=$THREADS SECONDS_TO_RUN=$SECS \
    SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" \
    THINKING_TIME=$THINK \
    ansible-playbook -f 12 -i "ansible-tests/sweep-inv-${N}.yaml" ansible-tests/run-tests.yaml \
    >"$OD/ansible.log" 2>&1; echo "    ansible rc=$?"

  # Executa merge no próprio master (sem pipe SSH)
  ssh "youruser@$MASTER" \
    "python3 /tmp/remote_merge.py '${RFILE}.pid*' $MERGED_REMOTE"

  # Copia resultado
  scp -q "youruser@$MASTER:$MERGED_REMOTE" "$OD/latency.txt"

  # Extrai métricas rápidas
  python3 - "$OD/latency.txt" 90 <<'PY'
import sys
f, secs = open(sys.argv[1]), int(sys.argv[2])
ok, lat, sec = 0, [], None
for ln in f:
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
print(f"    {len(lat)} pts  rps={ok/secs:.1f}  p50={p(.5):.0f}ms p95={p(.95):.0f}ms p99={p(.99):.0f}ms")
PY

  # Verifica restart
  RESTARTS=$(ssh worker \
    "sudo crictl inspect \$(sudo crictl ps --name kv-test-container -q 2>/dev/null | head -1) 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"status\"][\"restartCount\"])' 2>/dev/null || echo 0")
  [[ "$RESTARTS" -gt 0 ]] && echo "    *** AVISO: container reiniciou ($RESTARTS) ***" || true

  # Limpa pid files
  ssh "youruser@$MASTER" "rm -f ${RFILE}.pid* $MERGED_REMOTE 2>/dev/null || true"
done

echo "==> Plot final..."
python3 plot_client_sweep.py "$EXP_DIR"
