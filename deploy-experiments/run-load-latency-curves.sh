#!/bin/bash
# Sweep think_time pra cada (sistema, configuração) e gera curva throughput x latência.
# Cada combinação roda 1 round (N=1) de 60s com 12 procs/host.
#
# Saída: experiments-logs/load-latency-<timestamp>/manifest.tsv mapeando
# (system, think) -> run_dir, mais um comparativo.png ao final.
set -euo pipefail
cd "$(dirname "$0")"

CAMPAIGN_ID=$(date +%Y%m%d-%H%M%S)
CAMPAIGN_DIR="experiments-logs/load-latency-$CAMPAIGN_ID"
mkdir -p "$CAMPAIGN_DIR"
MANIFEST="$CAMPAIGN_DIR/manifest.tsv"
printf "system\tthink\trun_dir\n" > "$MANIFEST"

THINKS=(0.5 0.1 0.05 0.02 0.01 0.005)

# (system_label, server_url, restart_deploy, interceptor_cpu_or_empty)
CONFIGS=(
  "kv-test|http://10.10.1.2:32541|kv-test-deployment|"
  "interceptor-1cpu|http://10.10.1.2:32425|interceptor|1"
  "interceptor-2cpu|http://10.10.1.2:32425|interceptor|2"
  "interceptor-4cpu|http://10.10.1.2:32425|interceptor|4"
)

for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r SYSTEM SERVER_URL RESTART_DEPLOY CPU <<< "$cfg"

  if [ -n "$CPU" ]; then
    echo "=== set interceptor cpu=$CPU ==="
    ssh cp "kubectl set resources deploy/interceptor --containers=kv-interceptor --requests=cpu=${CPU},memory=4Gi --limits=cpu=${CPU},memory=4Gi >/dev/null && kubectl rollout status deploy/interceptor --timeout=120s >/dev/null"
  fi

  for THINK in "${THINKS[@]}"; do
    echo ""
    echo "########## $SYSTEM  think=$THINK ##########"
    # Cada chamada do sweep gera seu próprio RUN_ID em date. Capturo o
    # run_id pelo nome da última pasta criada após o sweep.
    SWEEP_NS="1" \
    NUM_THREAD=12 \
    THINKING_TIME="$THINK" \
    SECONDS_TO_RUN=60 \
    SERVER_URL="$SERVER_URL" \
    RESTART_DEPLOY="$RESTART_DEPLOY" \
      ./run-saturation-sweep.sh >/dev/null 2>&1 || echo "    sweep falhou $SYSTEM think=$THINK"

    # O run-saturation-sweep gera RUN_ID baseado em date; a última pasta
    # kv-test-* é a desse round.
    RUN_DIR=$(ls -td experiments-logs/kv-test-* | head -1)
    printf "%s\t%s\t%s\n" "$SYSTEM" "$THINK" "$RUN_DIR" >> "$MANIFEST"
    echo "    salvo: $RUN_DIR"
  done
done

echo ""
echo "=== gerando plot final ==="
python3 - <<PY
import glob, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from collections import defaultdict

manifest = "$CAMPAIGN_DIR/manifest.tsv"
data = defaultdict(list)  # system -> [(rps, p50_ms, think), ...]

with open(manifest) as f:
    r = csv.DictReader(f, delimiter="\t")
    for row in r:
        rd = row["run_dir"]
        files = sorted(glob.glob(f"{rd}/1-clients/per-host/*/*.pid*"))
        if not files: continue
        lats=[]
        for fpath in files:
            in_lat=False
            for line in open(fpath):
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
ax.set_xscale("linear")
ax.grid(True, alpha=0.3, which="both")
ax.legend()
plt.tight_layout()
out = "$CAMPAIGN_DIR/comparativo_throughput_latencia.png"
plt.savefig(out, dpi=150)
print("salvo:", out)
PY

echo "=== FIM. Resultados em $CAMPAIGN_DIR ==="
