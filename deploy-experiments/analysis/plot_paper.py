#!/usr/bin/env python3
"""Paper-ready plots (English, no title) from a run of run-snapshot-restore-tests.sh.
Generates two separate figures in the run dir:
  throughput.png — served 204/s over time (completion-binned)
  latency.png    — p50/p99 per bin (204 only, log scale)
Both draw the REAL snapshot block windows (from interceptor-cycle.json) as
shaded spans, and the pod-kill line (from kill.log) when present.

Usage: python3 plot_paper.py <run_dir>
"""
import sys, os, glob, json
from datetime import datetime
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = sys.argv[1].rstrip("/")
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
                try:
                    st = a[2].strip() if len(a) > 2 else None
                    rows.append((float(a[0]), float(a[1]), st))
                except ValueError: pass
if not rows:
    sys.exit(f"no latencies under {BASE}/*/*.pid*")
t0 = min(r[0] for r in rows)

# real snapshot block windows from the interceptor cycle log
def iso2epoch(t):
    return datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
block_spans = []
cyc = os.path.join(BASE, "interceptor-cycle.json")
if os.path.exists(cyc):
    start = None
    for ln in open(cyc, errors="ignore"):
        i = ln.find("{")
        if i < 0: continue
        try: d = json.loads(ln[i:].strip())
        except ValueError: continue
        m = d.get("message", "")
        if m == "Starting snapshot":
            start = iso2epoch(d["time"])
        elif m == "Snapshot complete, requests unblocked" and start is not None:
            block_spans.append((start - t0, iso2epoch(d["time"]) - t0))
            start = None

kill_t = None
kill_log = os.path.join(BASE, "kill.log")
if os.path.exists(kill_log):
    for tok in open(kill_log).read().split():
        if tok.startswith("epoch="):
            kill_t = float(tok.split("=", 1)[1]) - t0

# completion-binned series, 204 only
bins = {}
for ts, lat, st in rows:
    if st is not None and st != "204":
        continue
    b = int((ts + lat - t0) // BIN)
    bins.setdefault(b, []).append(lat * 1000)
maxb = max(bins)
xs  = [b * BIN for b in range(maxb + 1)]
rps = [len(bins.get(b, [])) / BIN for b in range(maxb + 1)]
def pct(v, q):
    return v[min(len(v) - 1, int(len(v) * q))]
p50 = [pct(sorted(bins[b]), .50) if bins.get(b) else None for b in range(maxb + 1)]
p99 = [pct(sorted(bins[b]), .99) if bins.get(b) else None for b in range(maxb + 1)]

def decorate(ax, ymax_frac=0.93):
    for i, (b0, b1) in enumerate(block_spans):
        if b1 < 0 or b0 > maxb * BIN: continue
        ax.axvspan(b0, b1, color="green", alpha=0.15)
        ax.axvline(b0, color="green", ls=":", alpha=0.9)
        ax.text(b0, ax.get_ylim()[1] * ymax_frac, f"snapshot block {b1-b0:.0f}s",
                rotation=90, color="green", fontsize=8, ha="right")
    if kill_t is not None:
        ax.axvline(kill_t, color="purple", ls="--", lw=1.8, alpha=0.9)
        ax.text(kill_t, ax.get_ylim()[1] * 0.55, f"pod kill (t≈{kill_t:.0f}s)",
                rotation=90, color="purple", fontsize=9, ha="right", fontweight="bold")
    ax.set_xlabel("time (s)")
    ax.grid(alpha=0.3)

# --- throughput ---
fig, ax = plt.subplots(figsize=(11, 5))
ax.fill_between(xs, rps, step="post", color="#1f77b4", alpha=0.35)
ax.plot(xs, rps, color="#1f77b4", lw=1.5, label="served throughput (successful req/s)")
ax.set_ylabel("successful requests/s")
decorate(ax)
ax.legend(loc="upper right")
plt.tight_layout()
out = os.path.join(BASE, "throughput.png")
plt.savefig(out, dpi=120); plt.close(fig)
print("saved:", out)

# --- latency ---
fig, ax = plt.subplots(figsize=(11, 5))
ax.plot(xs, p50, color="#d62728", lw=1.5, label="p50 per 10s bin")
ax.plot(xs, p99, color="#ff7f0e", lw=1.2, ls="--", label="p99 per 10s bin")
ax.set_yscale("log")
ax.set_ylabel("latency (ms, log scale)")
decorate(ax)
ax.legend(loc="upper right")
plt.tight_layout()
out = os.path.join(BASE, "latency.png")
plt.savefig(out, dpi=120); plt.close(fig)
print("saved:", out)
