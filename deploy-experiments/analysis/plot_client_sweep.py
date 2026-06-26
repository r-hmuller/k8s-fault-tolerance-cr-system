"""
Gráfico dual-eixo: vazão (req/s) e latência (p50/p99 ms) vs número de clientes.

Uso:
    python plot_client_sweep.py                    # experimento mais recente kv-sweep-*
    python plot_client_sweep.py <experiment_dir>
"""
import os
import sys
import glob
import re
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker


def parse_latency_file(filepath):
    ok = 0
    lat = []
    sec = None
    with open(filepath) as f:
        for ln in f:
            ln = ln.strip()
            if ln == "--- Status Counts ---":
                sec = "s"; continue
            if ln == "--- Latencies ---":
                sec = "l"; continue
            if ln.startswith("---"):
                sec = None; continue
            if sec == "s" and ln.startswith("204,"):
                try: ok += int(ln.split(",")[1])
                except: pass
            elif sec == "l" and "," in ln:
                try: lat.append(float(ln.split(",")[1]) * 1000)
                except: pass
    return ok, sorted(lat)


def percentile(lat, q):
    if not lat:
        return float("nan")
    return lat[min(len(lat) - 1, int(len(lat) * q))]


def discover_rounds(experiment_dir):
    rounds = []
    for entry in os.listdir(experiment_dir):
        m = re.match(r"^(\d+)-clients$", entry)
        if not m:
            continue
        lat_file = os.path.join(experiment_dir, entry, "latency.txt")
        if os.path.isfile(lat_file):
            rounds.append((int(m.group(1)), lat_file))
    rounds.sort(key=lambda x: x[0])
    return rounds


def latest_experiment_dir():
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "experiments-logs")
    candidates = sorted(glob.glob(os.path.join(base, "kv-sweep-*")))
    candidates = [c for c in candidates if os.path.isdir(c)]
    if not candidates:
        # fallback: any experiment
        candidates = sorted(glob.glob(os.path.join(base, "*")))
        candidates = [c for c in candidates if os.path.isdir(c)]
    if not candidates:
        sys.exit(f"Sem experimentos em {base}/")
    return candidates[-1]


def plot(experiment_dir, secs=90, threads=None):
    rounds = discover_rounds(experiment_dir)
    if not rounds:
        sys.exit(f"Sem subdiretórios N-clients com latency.txt em {experiment_dir}")

    ns, rps_list, p50_list, p95_list, p99_list = [], [], [], [], []
    for n, lat_file in rounds:
        ok, lat = parse_latency_file(lat_file)
        ns.append(n)
        rps_list.append(ok / secs)
        p50_list.append(percentile(lat, 0.50))
        p95_list.append(percentile(lat, 0.95))
        p99_list.append(percentile(lat, 0.99))

    ns = np.array(ns)
    rps_arr = np.array(rps_list)
    p50_arr = np.array(p50_list)
    p95_arr = np.array(p95_list)
    p99_arr = np.array(p99_list)

    fig, ax1 = plt.subplots(figsize=(10, 6))
    ax2 = ax1.twinx()

    color_thr = "#1f77b4"
    color_p50 = "#2ca02c"
    color_p95 = "#ff7f0e"
    color_p99 = "#d62728"

    l1, = ax1.plot(ns, rps_arr, "o-", color=color_thr, linewidth=2.2,
                   markersize=7, label="Vazão (req/s)")
    ax1.fill_between(ns, rps_arr, alpha=0.08, color=color_thr)

    l2, = ax2.plot(ns, p50_arr, "s--", color=color_p50, linewidth=1.8,
                   markersize=6, label="P50 latência")
    l3, = ax2.plot(ns, p95_arr, "^--", color=color_p95, linewidth=1.8,
                   markersize=6, label="P95 latência")
    l4, = ax2.plot(ns, p99_arr, "D--", color=color_p99, linewidth=1.8,
                   markersize=6, label="P99 latência")

    ax1.set_xlabel("Número de clientes", fontsize=13)
    ax1.set_ylabel("Vazão (req/s)", color=color_thr, fontsize=12)
    ax1.tick_params(axis="y", labelcolor=color_thr)
    ax1.set_ylim(bottom=0)
    ax1.set_xticks(ns)
    ax1.grid(True, alpha=0.3, axis="both")

    ax2.set_ylabel("Latência (ms)", fontsize=12)
    ax2.set_ylim(bottom=0)

    lines = [l1, l2, l3, l4]
    labels = [l.get_label() for l in lines]
    ax1.legend(lines, labels, loc="upper left", fontsize=10)

    exp_name = os.path.basename(experiment_dir)
    params_file = os.path.join(experiment_dir, "params.txt")
    if threads is None and os.path.exists(params_file):
        for ln in open(params_file):
            if ln.startswith("threads="):
                try: threads = int(ln.split("=")[1])
                except: pass
    thread_label = f"{threads}" if threads else "?"
    target = "interceptor" if "interceptor" in exp_name else "kv-test"
    plt.title(f"{target} — sweep de clientes ({thread_label} threads/cliente, 90s)\n{exp_name}",
              fontsize=12, fontweight="bold")
    plt.tight_layout()

    out_dir = os.path.join(experiment_dir, "plots")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "client_sweep.png")
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Plot salvo: {out_path}")
    return out_path


if __name__ == "__main__":
    if len(sys.argv) > 1:
        exp_dir = os.path.abspath(sys.argv[1])
    else:
        exp_dir = latest_experiment_dir()
    plot(exp_dir)
