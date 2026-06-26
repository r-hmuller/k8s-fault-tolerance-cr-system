#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

EXP_DIR="experiments-logs/kv-sweep-20260604-115139"
REMOTE_FW="/tmp/kv-sweep-rerun2-$(date +%H%M%S)"
MASTER="node1.example.net"
THREADS=22; SECS=90; THINK=0
SERVER_URL="http://10.10.1.2:30869"

export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

CTRL="$HOME/.ssh/cm-youruser@node1.example.net:22"
ssh -o ControlMaster=auto -o "ControlPath=$CTRL" -o ControlPersist=3600 \
    "youruser@$MASTER" "mkdir -p $REMOTE_FW"

merge_n() {
  local N="$1" RFILE="$2" OD="$3"
  local ok=0 sec="" ln lats_file
  lats_file=$(mktemp)
  # Catena todos .pid* com newline entre eles via ControlMaster existente
  ssh -o "ControlPath=$CTRL" "youruser@$MASTER" \
    "for f in ${RFILE}.pid*; do cat \"\$f\"; echo; done 2>/dev/null || true" | \
  python3 - "$OD/latency.txt" <<'PY'
import sys
out = sys.argv[1]
ok, lats, sec = 0, [], None
for ln in sys.stdin:
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
with open(out, "w") as f:
    f.write("--- Status Counts ---\n204," + str(ok) + "\n--- Latencies ---\n")
    f.write("\n".join(lats) + "\n")
lat_vals = sorted([float(l.split(",")[1])*1000 for l in lats])
p = lambda q: lat_vals[min(len(lat_vals)-1,int(len(lat_vals)*q))] if lat_vals else float("nan")
print(f"    {len(lats)} pts  ok={ok}  rps={ok/90:.1f}  p50={p(.5):.0f}ms p95={p(.95):.0f}ms p99={p(.99):.0f}ms")
PY
  ssh -o "ControlPath=$CTRL" "youruser@$MASTER" \
    "rm -f ${RFILE}.pid* 2>/dev/null || true"
}

for N in 8 9; do
  OD="$EXP_DIR/${N}-clients"
  mkdir -p "$OD"
  RFILE="$REMOTE_FW/${N}_clients_${THREADS}_threads_${THINK}_thinking.txt"
  echo "==> N=$N  $(date +%H:%M:%S)"

  NUM_CLIENT=$N NUM_THREAD=$THREADS SECONDS_TO_RUN=$SECS \
    SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" \
    THINKING_TIME=$THINK \
    ansible-playbook -f 12 -i "ansible-tests/sweep-inv-${N}.yaml" ansible-tests/run-tests.yaml \
    >"$OD/ansible.log" 2>&1

  merge_n "$N" "$RFILE" "$OD"

  # Verifica restart do container
  RESTARTS=$(ssh worker \
    "sudo crictl inspect \$(sudo crictl ps --name kv-test-container -q 2>/dev/null | head -1) 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"status\"][\"restartCount\"])' 2>/dev/null || echo 0")
  [[ "$RESTARTS" -gt 0 ]] && echo "    *** AVISO: container reiniciou ($RESTARTS) ***" || true
done

echo "==> Plot final..."
python3 plot_client_sweep.py "$EXP_DIR"
