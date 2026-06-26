#!/usr/bin/env python3
"""Classic load-latency curves (throughput on X, latency on Y) comparing
kv-test direct vs interceptor at different vCPU limits.
Usage: python3 plot_tput_latency.py <RESULTADOS_dir>
Reads <dir>/<sweep>/summary.txt; writes throughput_latency_p50.png / _p99.png.
"""
import sys, os, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = sys.argv[1].rstrip("/")

SYSTEMS = [  # (glob prefix, label, color, marker)
    ("kv-direct-sweep-*",        "kv-test direct (1 vCPU)", "#1f77b4", "o"),
    ("interceptor-1cpu-sweep-*", "interceptor 1 vCPU",      "#d62728", "s"),
    ("interceptor-4cpu-sweep-*", "interceptor 4 vCPU",      "#ff7f0e", "^"),
    ("interceptor-6cpu-sweep-*", "interceptor 6 vCPU",      "#2ca02c", "D"),
]

def read_summary(d):
    rows = []
    for ln in open(os.path.join(d, "summary.txt")):
        p = ln.split()
        if not p or not p[0].isdigit(): continue
        rows.append({"clients": int(p[0]), "rps": float(p[1]),
                     "p50": float(p[2]), "p95": float(p[3]), "p99": float(p[4])})
    return truncate_at_saturation(rows)

def truncate_at_saturation(rows):
    """Keep points up to (and including) the first one where throughput
    REGRESSES vs the running max — that's the vertical rise into saturation.
    Beyond it the system is collapsed and points fold back over the X axis
    (throughput oscillates at high latency), which only adds noise."""
    out, max_rps = [], 0.0
    for r in rows:
        out.append(r)
        if r["rps"] < max_rps:
            break
        max_rps = max(max_rps, r["rps"])
    return out

data = {}
for pat, label, color, marker in SYSTEMS:
    hits = glob.glob(os.path.join(BASE, pat))
    if not hits: continue
    data[label] = (read_summary(hits[0]), color, marker)

for metric, fname in (("p50", "throughput_latency_p50.png"),
                      ("p99", "throughput_latency_p99.png")):
    fig, ax = plt.subplots(figsize=(8.5, 5.5))
    for label, (rows, color, marker) in data.items():
        xs = [r["rps"] for r in rows]
        ys = [r[metric] for r in rows]
        ax.plot(xs, ys, color=color, marker=marker, ms=5, lw=1.6, label=label)
    ax.set_xlabel("throughput (req/s)")
    ax.set_ylabel(f"{metric} latency (ms, log scale)")
    ax.set_yscale("log")
    ax.grid(alpha=0.3, which="both")
    ax.legend(loc="upper left")
    plt.tight_layout()
    out = os.path.join(BASE, fname)
    plt.savefig(out, dpi=120); plt.close(fig)
    print("saved:", out)
