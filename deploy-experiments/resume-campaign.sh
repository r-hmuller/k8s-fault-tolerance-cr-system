#!/bin/bash
# Resume os 9 rounds que faltam do load-vs-latency campaign:
# interceptor-2cpu {0.02, 0.01, 0.005} + interceptor-4cpu {all 6}.
# Adiciona sleeps entre rodadas pra não estourar o 1Password ssh-agent.
set -euo pipefail
cd "$(dirname "$0")"

CAMPAIGN_DIR="experiments-logs/load-latency-20260529-121828"
MANIFEST="$CAMPAIGN_DIR/manifest.tsv"

# Remove as 3 entradas erradas do 2cpu (apontavam pro mesmo run_dir do think=0.05)
grep -v $'\tinterceptor-2cpu\t0.02\t' "$MANIFEST" \
  | grep -v $'\tinterceptor-2cpu\t0.01\t' \
  | grep -v $'\tinterceptor-2cpu\t0.005\t' \
  > "$MANIFEST.clean"
mv "$MANIFEST.clean" "$MANIFEST"

run_one() {
  local SYSTEM=$1 THINK=$2 SERVER_URL=$3 RESTART_DEPLOY=$4
  echo "########## $SYSTEM  think=$THINK ##########"
  SWEEP_NS="1" NUM_THREAD=12 THINKING_TIME="$THINK" SECONDS_TO_RUN=60 \
    SERVER_URL="$SERVER_URL" RESTART_DEPLOY="$RESTART_DEPLOY" \
    ./run-saturation-sweep.sh >/dev/null 2>&1 || { echo "    falhou"; return 1; }
  local RUN_DIR=$(ls -td experiments-logs/kv-test-* | head -1)
  printf "%s\t%s\t%s\n" "$SYSTEM" "$THINK" "$RUN_DIR" >> "$MANIFEST"
  echo "    salvo: $RUN_DIR"
  sleep 5
}

# 2 CPU - resume
for THINK in 0.02 0.01 0.005; do
  run_one interceptor-2cpu "$THINK" http://10.10.1.2:32425 interceptor
done

echo "=== set interceptor cpu=4 ==="
ssh cp "kubectl set resources deploy/interceptor --containers=kv-interceptor --requests=cpu=4,memory=4Gi --limits=cpu=4,memory=4Gi >/dev/null && kubectl rollout status deploy/interceptor --timeout=120s >/dev/null"
sleep 8

# 4 CPU - all 6
for THINK in 0.5 0.1 0.05 0.02 0.01 0.005; do
  run_one interceptor-4cpu "$THINK" http://10.10.1.2:32425 interceptor
done

echo "=== rebuilding plot ==="
python3 - <<PY
import glob, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from collections import defaultdict

manifest = "$CAMPAIGN_DIR/manifest.tsv"
data = defaultdict(list)
with open(manifest) as f:
    r = csv.DictReader(f, delimiter="\t")
    for row in r:
        rd = row["run_dir"]
        files = sorted(glob.glob(f"{rd}/1-clients/per-host/*/*.pid*"))
        if not files: continue
        lats=[]
        for fp in files:
            in_lat=False
            for line in open(fp):
                if line.startswith("--- Latencies"): in_lat=True; continue
                if line.startswith("---"): in_lat=False; continue
                if in_lat and "," in line:
                    try: lats.append(float(line.split(",")[1])*1000)
                    except: pass
        if not lats: continue
        lats.sort()
        rps = len(lats) / 60.0
        p50 = lats[len(lats)//2]
        data[row["system"]].append((rps, p50, float(row["think"])))

fig, ax = plt.subplots(figsize=(12, 7))
fig.suptitle("Throughput x Latência mediana — N=1, 12 procs/host, 60s", fontweight="bold")
colors = {"kv-test": "#1f77b4", "interceptor-1cpu": "#ff7f0e",
          "interceptor-2cpu": "#2ca02c", "interceptor-4cpu": "#d62728"}
for sys_name, pts in data.items():
    pts.sort()
    rps_arr = [p[0] for p in pts]
    p50_arr = [p[1] for p in pts]
    ax.plot(rps_arr, p50_arr, marker="o", linewidth=2, color=colors.get(sys_name,"#888"), label=sys_name)
    for r, p, t in pts:
        ax.annotate(f"think={t}", (r,p), textcoords="offset points", xytext=(5,5), fontsize=7, alpha=0.7)

ax.set_xlabel("Vazão atingida (req/s)")
ax.set_ylabel("Latência mediana P50 (ms, log)")
ax.set_yscale("log")
ax.grid(True, alpha=0.3, which="both")
ax.legend()
plt.tight_layout()
out = "$CAMPAIGN_DIR/comparativo_throughput_latencia.png"
plt.savefig(out, dpi=150)
print("salvo:", out)
PY

echo "=== FIM. $CAMPAIGN_DIR ==="
