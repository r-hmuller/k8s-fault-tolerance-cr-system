"""
Gera gráficos do teste de restore (run-restore-test.sh).

Uso:
    python plot_restore_test.py                       # experimento mais recente
    python plot_restore_test.py <experiment_dir>

Lê:
    <experiment_dir>/c{1..N}.log     (ts key value post_code get_code status)
    <experiment_dir>/restores.log    (offset epoch_at_trigger duration_s exit_code)

Saída:
    <experiment_dir>/plots/throughput.png
    <experiment_dir>/plots/error-rate.png
"""
import glob
import os
import re
import sys
from collections import defaultdict

import matplotlib.pyplot as plt
import numpy as np


def latest_run(base_dir):
    runs = sorted(glob.glob(os.path.join(base_dir, "restore-test-*")))
    if not runs:
        sys.exit(f"sem runs em {base_dir}")
    return runs[-1]


def parse_client_log(path):
    """yield (ts:int, status:str, post_t:float|None, get_t:float|None)

    Format: ts key expected post_code get_code [post_t get_t] status
    Older logs (sem latência) têm 6 campos; novos têm 8.
    """
    with open(path) as f:
        for line in f:
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 6:
                continue
            try:
                ts = int(parts[0])
            except ValueError:
                continue
            status = parts[-1]
            if len(parts) >= 8:
                try:
                    post_t = float(parts[5])
                    get_t = float(parts[6])
                except ValueError:
                    post_t, get_t = None, None
            else:
                post_t, get_t = None, None
            yield ts, status, post_t, get_t


def parse_restores(path):
    """returns list of (epoch_at_trigger, duration_s, exit_code)"""
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 4:
                try:
                    out.append((int(parts[1]), int(parts[2]), int(parts[3])))
                except ValueError:
                    pass
    return out


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    if len(sys.argv) > 1:
        run_dir = sys.argv[1]
    else:
        run_dir = latest_run(os.path.join(base, "experiments-logs"))
    print(f"run: {run_dir}")

    client_logs = sorted(glob.glob(os.path.join(run_dir, "c*.log")))
    if not client_logs:
        sys.exit("sem logs de cliente")

    # Per-client per-second counters: throughput[cid][sec] = count(OK)
    throughput = defaultdict(lambda: defaultdict(int))
    errors = defaultdict(lambda: defaultdict(int))
    # Per-second latency samples: lat[kind][sec] = list of ms
    lat = {"post": defaultdict(list), "get": defaultdict(list), "rt": defaultdict(list)}
    t_min, t_max = None, None
    has_latency = False

    for path in client_logs:
        cid = os.path.basename(path).replace(".log", "")
        for ts, status, post_t, get_t in parse_client_log(path):
            t_min = ts if t_min is None else min(t_min, ts)
            t_max = ts if t_max is None else max(t_max, ts)
            if status == "OK":
                throughput[cid][ts] += 1
                if post_t is not None and get_t is not None:
                    has_latency = True
                    lat["post"][ts].append(post_t * 1000)
                    lat["get"][ts].append(get_t * 1000)
                    lat["rt"][ts].append((post_t + get_t) * 1000)
            else:
                errors[cid][ts] += 1

    if t_min is None:
        sys.exit("logs vazios")

    seconds = list(range(t_min, t_max + 1))
    rel = [s - t_min for s in seconds]

    restores = parse_restores(os.path.join(run_dir, "restores.log"))

    plots_dir = os.path.join(run_dir, "plots")
    os.makedirs(plots_dir, exist_ok=True)

    # --- Throughput plot ---
    fig, ax = plt.subplots(figsize=(14, 6))
    for cid in sorted(throughput):
        y = [throughput[cid].get(s, 0) for s in seconds]
        ax.plot(rel, y, label=cid, alpha=0.7, linewidth=0.9)
    total = [sum(throughput[c].get(s, 0) for c in throughput) for s in seconds]
    ax.plot(rel, total, label="total", color="black", linewidth=1.6)

    for trig, dur, ec in restores:
        x = trig - t_min
        ax.axvspan(x, x + dur, color="red", alpha=0.18)
        ax.axvline(x, color="red", linestyle="--", linewidth=0.8)

    ax.set_xlabel("seconds since test start")
    ax.set_ylabel("successful POST+GET round-trips per second")
    ax.set_title(f"Throughput — {os.path.basename(run_dir)}\n(red bands = rollout-restart windows)")
    ax.legend(loc="upper right", ncol=len(throughput) + 1, fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out = os.path.join(plots_dir, "throughput.png")
    fig.savefig(out, dpi=120)
    plt.close(fig)
    print(f"  -> {out}")

    # --- Error-rate plot ---
    fig, ax = plt.subplots(figsize=(14, 4))
    err_total = [sum(errors[c].get(s, 0) for c in errors) for s in seconds]
    ax.bar(rel, err_total, width=1.0, color="orangered", alpha=0.8)
    for trig, dur, ec in restores:
        x = trig - t_min
        ax.axvspan(x, x + dur, color="red", alpha=0.18)
    ax.set_xlabel("seconds since test start")
    ax.set_ylabel("failed requests / sec (POST_FAIL+GET_FAIL+MISMATCH)")
    ax.set_title("Errors per second")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out = os.path.join(plots_dir, "error-rate.png")
    fig.savefig(out, dpi=120)
    plt.close(fig)
    print(f"  -> {out}")

    # --- Latency plot (POST+GET round-trip, p50/p95/p99 per second) ---
    if has_latency:
        fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)
        kinds = [("post", "POST latency (ms)"), ("get", "GET latency (ms)"), ("rt", "POST+GET round-trip (ms)")]
        for ax, (kind, title) in zip(axes, kinds):
            p50, p95, p99 = [], [], []
            for s in seconds:
                samples = lat[kind].get(s, [])
                if samples:
                    a = np.array(samples)
                    p50.append(np.percentile(a, 50))
                    p95.append(np.percentile(a, 95))
                    p99.append(np.percentile(a, 99))
                else:
                    p50.append(np.nan)
                    p95.append(np.nan)
                    p99.append(np.nan)
            ax.plot(rel, p50, label="p50", linewidth=1.0, alpha=0.9)
            ax.plot(rel, p95, label="p95", linewidth=1.0, alpha=0.9, color="darkorange")
            ax.plot(rel, p99, label="p99", linewidth=1.0, alpha=0.9, color="firebrick")
            for trig, dur, ec in restores:
                x = trig - t_min
                ax.axvspan(x, x + dur, color="red", alpha=0.15)
            ax.set_ylabel(title)
            ax.legend(loc="upper right", fontsize=9)
            ax.grid(True, alpha=0.3)
        axes[-1].set_xlabel("seconds since test start")
        axes[0].set_title(f"Latency percentiles — {os.path.basename(run_dir)}")
        fig.tight_layout()
        out = os.path.join(plots_dir, "latency.png")
        fig.savefig(out, dpi=120)
        plt.close(fig)
        print(f"  -> {out}")
    else:
        print("  (sem latência nos logs — re-rode com client atualizado)")


if __name__ == "__main__":
    main()
