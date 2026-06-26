#!/usr/bin/env python3
"""Vazão e latência ao longo do tempo de um teste de snapshot periódico sob carga.
Uso: python3 plot_snapshot_test.py <pasta_local_do_teste> [intervalo_snapshot_s]
Lê os .pid* (linhas ts,latency da seção --- Latencies ---), agrega sucessos em
bins de 10s -> rps, e plota rps + p50 do bin. Os "buracos" = janelas de snapshot."""
import sys, os, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = sys.argv[1].rstrip("/")
INTERVAL = int(sys.argv[2]) if len(sys.argv) > 2 else 240
BIN = 10.0

rows = []
for f in glob.glob(os.path.join(BASE, "*", "*.pid*")):
    insec = False
    with open(f, errors="ignore") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln == "--- Latencies ---": insec = True; continue
            if ln.startswith("---"): insec = False; continue
            if insec and "," in ln:
                a = ln.split(",")
                try: rows.append((float(a[0]), float(a[1])))
                except: pass
rows.sort()
t0 = rows[0][0]
bins = {}
for ts, lat in rows:
    b = int((ts - t0) // BIN)
    bins.setdefault(b, []).append(lat * 1000)  # ms

maxb = max(bins)
xs = [b * BIN for b in range(maxb + 1)]
rps = [len(bins.get(b, [])) / BIN for b in range(maxb + 1)]
p50 = [sorted(bins[b])[len(bins[b]) // 2] if bins.get(b) else 0 for b in range(maxb + 1)]

fig, ax1 = plt.subplots(figsize=(13, 6.5))
ax1.fill_between(xs, rps, step="post", color="#1f77b4", alpha=0.35)
ax1.plot(xs, rps, color="#1f77b4", lw=1.5, label="vazão (sucessos/s)")
ax1.set_xlabel("tempo (s)"); ax1.set_ylabel("vazão — sucessos/s (204)", color="#1f77b4")
ax1.tick_params(axis="y", labelcolor="#1f77b4")
ax1.set_ylim(bottom=0)

ax2 = ax1.twinx(); ax2.set_yscale("log")
# só plota p50 onde houve sucesso
xp = [x for x, p in zip(xs, p50) if p > 0]; yp = [p for p in p50 if p > 0]
ax2.plot(xp, yp, color="#d62728", lw=1.2, ls="--", alpha=0.8, label="p50 do bin (ms)")
ax2.set_ylabel("p50 por bin — ms (log)", color="#d62728")
ax2.tick_params(axis="y", labelcolor="#d62728")

# marca onde os snapshots deveriam disparar (múltiplos do intervalo)
for k in range(1, int(xs[-1] // INTERVAL) + 1):
    ax1.axvline(k * INTERVAL, color="green", ls=":", lw=1.3, alpha=0.7)
    ax1.text(k * INTERVAL, ax1.get_ylim()[1]*0.96, f"snap t+{k*INTERVAL}s",
             rotation=90, va="top", ha="right", fontsize=8, color="green")

ax1.grid(True, alpha=0.25)
fig.suptitle(f"Snapshot periódico (a cada {INTERVAL}s) sob carga de 6 clientes — "
             f"vazão e latência no tempo\nburacos de vazão = janelas de snapshot "
             f"(~83-90s de bloqueio cada)", fontsize=11)
l1, lab1 = ax1.get_legend_handles_labels(); l2, lab2 = ax2.get_legend_handles_labels()
ax1.legend(l1 + l2, lab1 + lab2, loc="upper right", fontsize=9)
fig.tight_layout(rect=[0, 0, 1, 0.95])
out = os.path.join(BASE, "snapshot_throughput_timeline.png")
fig.savefig(out, dpi=130)
print("salvo:", out)
