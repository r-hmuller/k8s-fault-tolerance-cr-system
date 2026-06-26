#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

EXP_DIR=$(ls -dt experiments-logs/kv-sweep-* | head -1)
REMOTE_FW="/tmp/kv-sweep-n12-8t-$(date +%H%M%S)"
MASTER=node1.example.net
THREADS=8; SECS=90; THINK=0
SERVER_URL=http://10.10.1.2:30869
CTRL="$HOME/.ssh/cm-youruser@${MASTER}:22"

export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

# Garante ControlMaster ativo e cria dir remoto
ssh -o ControlMaster=auto -o "ControlPath=$CTRL" -o ControlPersist=3600 \
    "youruser@$MASTER" "mkdir -p $REMOTE_FW"

# Envia script de merge (versão que suporta /dev/stdout)
scp -o ControlPath="$CTRL" /tmp/kv_merge_local.py "youruser@$MASTER:/tmp/kv_merge4.py" 2>/dev/null || true

echo "==> Re-run N=1 e N=2 com ulimit fix | $EXP_DIR"

for N in 1 2; do
  OD="$EXP_DIR/${N}-clients"
  mkdir -p "$OD"
  RFILE="$REMOTE_FW/${N}_clients_${THREADS}_threads_${THINK}_thinking.txt"
  echo ""
  echo "==> N=$N  $(date +%H:%M:%S)"

  NUM_CLIENT=$N NUM_THREAD=$THREADS SECONDS_TO_RUN=$SECS \
    SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME=$THINK \
    ansible-playbook -f 12 -i "ansible-tests/sweep-inv-${N}.yaml" ansible-tests/run-tests.yaml \
    >"$OD/ansible.log" 2>&1; echo "    ansible rc=$?"

  # Stream via ControlMaster — merge2 suporta /dev/stdout
  ssh -o ControlMaster=no -o "ControlPath=$CTRL" "youruser@$MASTER" \
    "python3 /tmp/kv_merge2.py '${RFILE}.pid*' /dev/stdout $SECS; \
     rm -f ${RFILE}.pid* 2>/dev/null; true" \
    > "$OD/latency.txt"

  python3 - "$OD/latency.txt" "$SECS" "$N" "$EXP_DIR/summary.txt" <<'PY'
import sys
f, secs, N, summ = open(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ok, lat, sec = 0, [], None
for ln in f:
    ln = ln.strip()
    if ln == "--- Status Counts ---": sec="s"; continue
    if ln == "--- Latencies ---":     sec="l"; continue
    if ln.startswith("---"):          sec=None; continue
    if sec=="s" and ln.startswith("204,"): ok += int(ln.split(",")[1])
    elif sec=="l" and "," in ln:
        try: lat.append(float(ln.split(",")[1])*1000)
        except: pass
lat.sort()
p = lambda q: lat[min(len(lat)-1, int(len(lat)*q))] if lat else float("nan")
row = f"{N:<8} {ok/secs:<10.1f} {p(.50):<8.1f} {p(.95):<8.1f} {p(.99):<8.1f}"
print(row)
lines = [l for l in open(summ) if not (l.split() and l.split()[0] == str(N))]
lines.append(row + "\n")
lines.sort(key=lambda l: int(l.split()[0]) if l.split() and l.split()[0].isdigit() else 0)
open(summ, "w").writelines(lines)
PY
done

echo ""
echo "==> Resumo final:"
cat "$EXP_DIR/summary.txt"
echo ""
echo "==> Plot..."
python3 plot_client_sweep.py "$EXP_DIR"
