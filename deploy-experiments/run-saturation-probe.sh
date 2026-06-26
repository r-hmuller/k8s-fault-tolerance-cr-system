#!/bin/bash
# Probe de saturação: roda 1 round N=10, 60s, thinking_time=0 batendo no kv-test
# NodePort, enquanto amostra a CPU real do container (cgroup v2 cpu.stat:
# usage_usec + throttling) no worker. Mostra empiricamente se o kv-test (limite
# 0.5 core) satura: cores -> ~0.5 e nr_throttled/throttled_usec crescendo.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

SECS=${SECS:-60}
NUM_THREAD=${NUM_THREAD:-22}
SERVER_URL=${SERVER_URL:-http://10.10.1.2:30923}
INV=ansible-tests/inventory-10clients.yaml
MASTER=node1.example.net
NODES=(node1 node2 node3 node4 node5 node6 node7 node8 node9)
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT="experiments-logs/probe-$RUN_ID"; mkdir -p "$OUT"
REMOTE_FW="/users/youruser/probe-$RUN_ID"
export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False

echo "==> Warm SSH"
for h in "$MASTER" $(printf '%node2.example.net ' "${NODES[@]}") worker; do
  ssh -o BatchMode=yes -o ConnectTimeout=12 "${h/worker/youruser@node3.example.net}" true 2>/dev/null \
    || ssh -o BatchMode=yes -o ConnectTimeout=12 "youruser@$h" true 2>/dev/null || true
  sleep 1
done
ssh -o BatchMode=yes "youruser@$MASTER" "mkdir -p $REMOTE_FW"

echo "==> Localizando container kv-test + cgroup no worker"
CID=$(ssh worker "sudo crictl ps --name kv-test-container -q 2>/dev/null | head -1")
[ -n "$CID" ] || { echo "ERRO: container kv-test não encontrado"; exit 1; }
CG=$(ssh worker "sudo find /sys/fs/cgroup -maxdepth 6 -name 'crio-${CID}*' -type d 2>/dev/null | head -1")
[ -n "$CG" ] || { echo "ERRO: cgroup do container não encontrado"; exit 1; }
echo "    cid=$CID"
echo "    cgroup=$CG"
echo "    cpu.max: $(ssh worker "cat $CG/cpu.max 2>/dev/null")  (quota period; 50000 100000 = 0.5 core)"

echo "==> Sampler de CPU no worker (cada 1s, ~$((SECS+25))s) -> $OUT/cpu.log"
SAMP="/tmp/kvcpu-$RUN_ID.log"
ssh worker "nohup bash -c '
  for i in \$(seq 1 $((SECS+25))); do
    echo \"\$(date +%s) \$(cat $CG/cpu.stat 2>/dev/null | tr \"\n\" \" \")\";
    sleep 1;
  done > $SAMP 2>&1 &
  echo \$!' " > "$OUT/sampler.pid"
sleep 2  # baseline antes da carga

echo "==> Round: N=10, ${SECS}s, NUM_THREAD=$NUM_THREAD, THINKING_TIME=0, $SERVER_URL"
set +e
NUM_CLIENT=10 NUM_THREAD=$NUM_THREAD SECONDS_TO_RUN=$SECS THINKING_TIME=0 \
SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" \
  ansible-playbook -f 12 -i "$INV" ansible-tests/run-tests.yaml >"$OUT/ansible.log" 2>&1
rc=$?
set -e
echo "    ansible rc=$rc"

sleep 3
ssh worker "sudo pkill -f 'cat $CG/cpu.stat' 2>/dev/null; true" || true
scp -q "youruser@$MASTER:$REMOTE_FW/10_clients_${NUM_THREAD}_threads_0_thinking.txt" "$OUT/latency.txt" 2>/dev/null \
  || echo "    WARN: latency.txt não coletado"
scp -q worker:"$SAMP" "$OUT/cpu.log" 2>/dev/null || echo "    WARN: cpu.log não coletado"

echo "==> Análise"
python3 - "$OUT" "$SECS" <<'PY'
import sys, os
out, secs = sys.argv[1], int(sys.argv[2])
# --- main-thread latência/throughput ---
f=os.path.join(out,"latency.txt"); ok=0; lat=[]; sec=None
if os.path.exists(f):
  for ln in open(f):
    ln=ln.strip()
    if ln=="--- Status Counts ---": sec="s"; continue
    if ln=="--- Latencies ---": sec="l"; continue
    if ln.startswith("---"): sec=None; continue
    if sec=="s" and ln.startswith("204,"): ok+=int(ln.split(",")[1])
    elif sec=="l" and "," in ln:
      try: lat.append(float(ln.split(",")[1])*1000)
      except: pass
lat.sort()
p=lambda q: lat[min(len(lat)-1,int(len(lat)*q))] if lat else float('nan')
print(f"[main thread] reqOK_204={ok}  rps_main={ok/secs:.2f}  n_lat={len(lat)}  "
      f"p50={p(.5):.1f}ms p90={p(.9):.1f}ms p99={p(.99):.1f}ms max={(lat[-1] if lat else float('nan')):.1f}ms")
# --- CPU do container (cgroup v2 cpu.stat) ---
c=os.path.join(out,"cpu.log")
def parse(line):
  d={}; t=line.split()
  if not t: return None,d
  ts=int(t[0])
  for i in range(1,len(t)-1,2):
    try: d[t[i]]=int(t[i+1])
    except: pass
  return ts,d
rows=[parse(l) for l in open(c)] if os.path.exists(c) else []
rows=[(t,d) for t,d in rows if t and 'usage_usec' in d]
if len(rows)>=2:
  (t0,a),(t1,b)=rows[0],rows[-1]
  wall=t1-t0
  cores=(b['usage_usec']-a['usage_usec'])/1e6/wall if wall else 0
  thr=b.get('nr_throttled',0)-a.get('nr_throttled',0)
  thrus=(b.get('throttled_usec',0)-a.get('throttled_usec',0))/1e6
  per=b.get('nr_periods',0)-a.get('nr_periods',0)
  # pico em janela de 1s
  peak=0
  for (ta,da),(tb,db) in zip(rows,rows[1:]):
    w=tb-ta
    if w>0: peak=max(peak,(db['usage_usec']-da['usage_usec'])/1e6/w)
  print(f"[kv-test CPU] janela={wall}s  cores_medio={cores:.3f}  cores_pico_1s={peak:.3f}  (limite=0.500)")
  print(f"[throttle]   periodos={per}  throttled={thr} ({(100*thr/per if per else 0):.1f}% dos periodos)  tempo_throttled={thrus:.2f}s")
  print("=> SATUROU: CPU no teto de 0.5 core e throttling significativo." if (peak>=0.45 and thr>0)
        else "=> NÃO saturou a CPU do kv-test (gargalo está no path/RTT, não no servidor).")
else:
  print("[kv-test CPU] amostras insuficientes")
PY
echo "==> Resultados: $OUT"
