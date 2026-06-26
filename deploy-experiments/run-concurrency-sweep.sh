#!/bin/bash
# Sweep de CONCORRÊNCIA p/ achar o joelho de saturação do kv-test (que o sweep de
# clientes não acha — é RTT-bound). N=10 clientes fixos, varia NUM_THREAD, mede
# server-side a CPU real do container (cgroup v2 cpu.stat: usage + throttling) +
# latência/throughput da sonda main-thread. Rounds curtos, time-bounded.
#
# Vars (opcionais): THREADS ("22 50 100 200 400"), SECS (90),
#   THINKING_TIME (0.001), SERVER_URL (http://10.10.1.2:30923)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

THREADS=${THREADS:-"22 50 100 200 400"}
SECS=${SECS:-90}
THINK=${THINKING_TIME:-0.001}
SERVER_URL=${SERVER_URL:-http://10.10.1.2:30923}
INV=ansible-tests/inventory-10clients.yaml
MASTER=node1.example.net
NODES=(node1 node2 node3 node4 node5 node6 node7 node8 node9)
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT="experiments-logs/conc-$RUN_ID"; mkdir -p "$OUT"
REMOTE_FW="/users/youruser/conc-$RUN_ID"
export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=3600s -o ControlPath=$HOME/.ssh/cm-%r@%h:%p"
export ANSIBLE_HOST_KEY_CHECKING=False

echo "==> Warm SSH"
for h in "$MASTER" $(printf '%node2.example.net ' "${NODES[@]}"); do
  ssh -o BatchMode=yes -o ConnectTimeout=12 "youruser@$h" true 2>/dev/null || true; sleep 1
done
ssh worker true 2>/dev/null || true
ssh -o BatchMode=yes "youruser@$MASTER" "mkdir -p $REMOTE_FW"

echo "==> Localizando cgroup do container kv-test"
CID=$(ssh worker "sudo crictl ps --name kv-test-container -q 2>/dev/null | head -1")
CG=$(ssh worker "sudo find /sys/fs/cgroup -maxdepth 6 -name 'crio-${CID}*' -type d 2>/dev/null | head -1")
[ -n "$CG" ] || { echo "ERRO: cgroup não encontrado"; exit 1; }
echo "    cid=${CID:0:12}  cpu.max=$(ssh worker "cat $CG/cpu.max 2>/dev/null") (50000 100000 = 0.5 core)"
echo "run_id=$RUN_ID N=10 secs=$SECS think=$THINK threads='$THREADS'" | tee "$OUT/params.txt"
printf "%-7s %-9s %-7s %-7s %-8s %-11s %-9s %-9s\n" threads rps_main p50ms p99ms maxms cores_peak thr_pct thr_s | tee "$OUT/summary.txt"

for T in $THREADS; do
  OD="$OUT/${T}-threads"; mkdir -p "$OD"
  RFILE="$REMOTE_FW/10_clients_${T}_threads_${THINK}_thinking.txt"
  SAMP="/tmp/kvcpu-$RUN_ID-$T.log"
  ssh worker "nohup bash -c 'for i in \$(seq 1 $((SECS+50))); do echo \"\$(date +%s) \$(cat $CG/cpu.stat 2>/dev/null|tr \"\n\" \" \")\"; sleep 1; done > $SAMP 2>&1 &' " >/dev/null
  sleep 2

  echo "==> T=$T threads  $(date +%H:%M:%S)"
  set +e
  NUM_CLIENT=10 NUM_THREAD=$T SECONDS_TO_RUN=$SECS THINKING_TIME=$THINK \
  SERVER_URL="$SERVER_URL" FILE_TO_WRITE="$REMOTE_FW" \
    ansible-playbook -f 12 -i "$INV" ansible-tests/run-tests.yaml >"$OD/ansible.log" 2>&1
  rc=$?
  set -e
  sleep 3
  ssh worker "sudo pkill -f 'cat $CG/cpu.stat' 2>/dev/null; true" || true
  scp -q "youruser@$MASTER:$RFILE" "$OD/latency.txt" 2>/dev/null || echo "    WARN: latency.txt T=$T (rc=$rc)"
  scp -q worker:"$SAMP" "$OD/cpu.log" 2>/dev/null || echo "    WARN: cpu.log T=$T"

  python3 - "$OD" "$SECS" "$T" "$OUT/summary.txt" <<'PY'
import sys,os
od,secs,T,summ=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
f=os.path.join(od,"latency.txt"); ok=0; lat=[]; sec=None
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
rps=ok/secs if secs else 0
c=os.path.join(od,"cpu.log"); rows=[]
if os.path.exists(c):
  for l in open(c):
    t=l.split()
    if len(t)<3: continue
    try: ts=int(t[0])
    except: continue
    d={}
    for i in range(1,len(t)-1,2):
      try: d[t[i]]=int(t[i+1])
      except: pass
    if 'usage_usec' in d: rows.append((ts,d))
peak=0.0; thrp=0; per=0; thrs=0.0
if len(rows)>=2:
  (t0,a),(t1,b)=rows[0],rows[-1]
  per=b.get('nr_periods',0)-a.get('nr_periods',0)
  thrp=b.get('nr_throttled',0)-a.get('nr_throttled',0)
  thrs=(b.get('throttled_usec',0)-a.get('throttled_usec',0))/1e6
  for (ta,da),(tb,db) in zip(rows,rows[1:]):
    w=tb-ta
    if w>0: peak=max(peak,(db['usage_usec']-da['usage_usec'])/1e6/w)
pct=(100*thrp/per) if per else 0
row=f"{T:<7} {rps:<9.1f} {p(.5):<7.1f} {p(.99):<7.1f} {(lat[-1] if lat else float('nan')):<8.1f} {peak:<11.3f} {pct:<9.1f} {thrs:<9.2f}"
print(row)
open(summ,"a").write(row+"\n")
PY
done

echo
echo "==> RESUMO (joelho = cores_peak→0.500 e thr_pct subindo)"
cat "$OUT/summary.txt"
echo "==> Resultados: $OUT"
