#!/bin/bash
# Fixa N clientes e VARIA o thinking_time, pra demonstrar open-loop flooding vs capacidade sustentável.
# Mesma mecânica de merge do run-kv-client-sweep.sh (merge no master, sem scp).
set -euo pipefail
cd "$(dirname "$0")"

NCLIENTS=${NCLIENTS:-6}
THREADS=${THREADS:-8}
SECS=90
WARMUP_SECS=20
THINK_LIST=${THINK_LIST:-"0 0.0005 0.001 0.002 0.005 0.01 0.02 0.05"}
SERVER_URL=${SERVER_URL:-http://10.10.1.2:30869}
TARGET=${TARGET:-think-kv-N${NCLIENTS}}
MASTER=node1.example.net
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT="experiments-logs/${TARGET}-sweep-$RUN_ID"
mkdir -p "$OUT"
REMOTE_FW="/tmp/think-sweep-$RUN_ID"
export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=minimal

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
ok, err, lats, sec = 0, 0, [], None
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
        elif sec=="s" and "," in ln and not ln.startswith("204,"):
            try: err += int(ln.split(",")[1])
            except: pass
        elif sec=="l" and "," in ln:
            p = ln.split(",")
            if len(p)>=2:
                try: float(p[0]); float(p[1]); lats.append(ln)
                except: pass
with open(outfile,"w") as f:
    f.write("--- Status Counts ---\n204,"+str(ok)+"\nnon204,"+str(err)+"\n--- Latencies ---\n")
    f.write("\n".join(lats)+"\n")
lat_v = sorted([float(l.split(",")[1])*1000 for l in lats])
p = lambda q: lat_v[min(len(lat_v)-1,int(len(lat_v)*q))] if lat_v else float("nan")
print(f"{len(files)} files | ok={ok} err={err} | rps={ok/secs:.1f} | p50={p(.5):.0f}ms p95={p(.95):.0f}ms p99={p(.99):.0f}ms", file=sys.stderr)
PYEOF
)

echo "==> Warm SSH"
for h in "$MASTER" node2.example.net node3.example.net node4.example.net \
          node5.example.net node6.example.net node7.example.net node8.example.net node9.example.net; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "youruser@$h" true 2>/dev/null || true
done

ssh "youruser@$MASTER" "mkdir -p $REMOTE_FW"
echo "$MERGE_SCRIPT" | ssh "youruser@$MASTER" "cat > /tmp/think_merge.py"

echo "N=$NCLIENTS  THREADS=$THREADS  SECS=$SECS  SERVER_URL=$SERVER_URL" | tee "$OUT/params.txt"
echo "THINK_LIST=$THINK_LIST" | tee -a "$OUT/params.txt"

# Warmup (popula a base, 1 cliente)
echo ""; echo "==> WARMUP ${WARMUP_SECS}s  $(date +%H:%M:%S)"
mkdir -p "$OUT/warmup"
NUM_CLIENT=1 NUM_THREAD=$THREADS SECONDS_TO_RUN=$WARMUP_SECS \
  SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME=0 \
  ansible-playbook -f 12 -i ansible-tests/sweep-inv-1.yaml ansible-tests/run-tests.yaml \
    -e "should_populate_database=True" >"$OUT/warmup/ansible.log" 2>&1
ssh "youruser@$MASTER" "rm -f $REMOTE_FW/*.pid* 2>/dev/null || true"
echo "    Warmup concluído."

echo ""
printf "%-8s %-10s %-8s %-8s %-8s %-8s\n" "think" "rps" "p50ms" "p95ms" "p99ms" "non204" | tee "$OUT/summary.txt"

for THINK in $THINK_LIST; do
  OD="$OUT/think-${THINK}"
  mkdir -p "$OD"
  RFILE="$REMOTE_FW/${NCLIENTS}_clients_${THREADS}_threads_${THINK}_thinking.txt"

  echo ""; echo "==> think=$THINK  $(date +%H:%M:%S)"
  set +e
  NUM_CLIENT=$NCLIENTS NUM_THREAD=$THREADS SECONDS_TO_RUN=$SECS \
    SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" THINKING_TIME=$THINK \
    ansible-playbook -f 12 -i "ansible-tests/sweep-inv-${NCLIENTS}.yaml" ansible-tests/run-tests.yaml \
    >"$OD/ansible.log" 2>&1; rc=$?
  set -e

  ssh -o ControlPath="$HOME/.ssh/cm-youruser@${MASTER}:22" -o ControlMaster=no \
    "youruser@$MASTER" \
    "python3 /tmp/think_merge.py '${RFILE}.pid*' /dev/stdout $SECS 2>/dev/null; \
     rm -f ${RFILE}.pid* 2>/dev/null || true" \
    > "$OD/latency.txt" \
    || echo "    WARN: merge/stream falhou (rc=$rc)"

  python3 - "$OD/latency.txt" "$SECS" "$THINK" "$OUT/summary.txt" <<'PY'
import sys
f_path, secs, think, summ = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
ok, err, lat, sec = 0, 0, [], None
for ln in open(f_path):
    ln=ln.strip()
    if ln=="--- Status Counts ---": sec="s"; continue
    if ln=="--- Latencies ---":     sec="l"; continue
    if ln.startswith("---"):        sec=None; continue
    if sec=="s" and ln.startswith("204,"): ok+=int(ln.split(",")[1])
    elif sec=="s" and ln.startswith("non204,"): err+=int(ln.split(",")[1])
    elif sec=="l" and "," in ln:
        try: lat.append(float(ln.split(",")[1])*1000)
        except: pass
lat.sort()
p=lambda q: lat[min(len(lat)-1,int(len(lat)*q))] if lat else float("nan")
row=f"{think:<8} {ok/secs:<10.1f} {p(.50):<8.1f} {p(.95):<8.1f} {p(.99):<8.1f} {err:<8}"
print(row); open(summ,"a").write(row+"\n")
PY
done

echo ""; echo "==> RESUMO"; cat "$OUT/summary.txt"
echo "==> Resultados: $OUT"
