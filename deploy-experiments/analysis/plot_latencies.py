"""
Gera 1 gráfico detalhado por round (time series + histograma).

Uso:
    python plot_latencies.py                    # experimento mais recente
    python plot_latencies.py <experiment_dir>

Saída: <experiment_dir>/plots/per-round/{N}-clients.png
"""
import os
import sys
import glob
import re
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime


def parse_latency(filepath):
    timestamps, latencies = [], []
    in_lat = False
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if line == "--- Latencies ---":
                in_lat = True
                continue
            if line.startswith("---"):
                in_lat = False
                continue
            if in_lat and "," in line:
                parts = line.split(",")
                if len(parts) == 2:
                    try:
                        timestamps.append(float(parts[0]))
                        latencies.append(float(parts[1]) * 1000)
                    except ValueError:
                        pass
    return timestamps, latencies


def discover_rounds(experiment_dir):
    rounds = []
    for entry in os.listdir(experiment_dir):
        m = re.match(r"(\d+)-clients$", entry)
        if not m:
            continue
        rounds.append((int(m.group(1)), os.path.join(experiment_dir, entry)))
    rounds.sort(key=lambda x: x[0])
    return rounds


def latest_experiment_dir():
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "experiments-logs")
    candidates = sorted(glob.glob(os.path.join(base, "*")))
    candidates = [c for c in candidates if os.path.isdir(c)]
    if not candidates:
        sys.exit(f"Sem experimentos em {base}/")
    return candidates[-1]


def plot_one(n, round_dir, out_dir):
    filepath = os.path.join(round_dir, "latency.txt")
    if not os.path.isfile(filepath):
        print(f"  {n} clients: sem latency.txt, pulando")
        return
    timestamps, latencies = parse_latency(filepath)
    if not timestamps:
        print(f"  {n} clients: sem dados de latência")
        return

    datetimes = [datetime.fromtimestamp(ts) for ts in timestamps]
    median = np.median(latencies)
    p95 = np.percentile(latencies, 95)
    p99 = np.percentile(latencies, 99)

    fig, axes = plt.subplots(2, 1, figsize=(12, 8))
    fig.suptitle(f"{n} cliente(s) — n={len(latencies)}, mediana={median:.2f}ms, "
                 f"P95={p95:.2f}ms, P99={p99:.2f}ms", fontsize=12)

    ax1 = axes[0]
    window = max(1, len(latencies) // 20)
    smoothed = np.convolve(latencies, np.ones(window) / window, mode="same")
    ax1.plot(datetimes, latencies, linewidth=0.6, alpha=0.3, color="steelblue", label="Raw")
    ax1.plot(datetimes, smoothed, linewidth=1.5, color="steelblue", label=f"Média móvel (w={window})")
    ax1.set_xlabel("Tempo")
    ax1.set_ylabel("Latência (ms)")
    ax1.set_title("Latência ao longo do tempo")
    ax1.set_ylim(0, max(p99 * 1.5, 50))
    ax1.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax1.legend(fontsize=8)
    fig.autofmt_xdate()
    ax1.grid(True, alpha=0.3)

    ax2 = axes[1]
    clipped = [l for l in latencies if l <= p99 * 1.5]
    ax2.hist(clipped, bins=60, color="steelblue", edgecolor="white", linewidth=0.3)
    ax2.axvline(median, color="orange", linestyle="--", label=f"Mediana: {median:.2f} ms")
    ax2.axvline(p95, color="red", linestyle="--", label=f"P95: {p95:.2f} ms")
    ax2.axvline(p99, color="darkred", linestyle="--", label=f"P99: {p99:.2f} ms")
    ax2.set_xlabel("Latência (ms)")
    ax2.set_ylabel("Frequência")
    ax2.set_title("Distribuição de latências (clip @ 1.5×P99)")
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    out_path = os.path.join(out_dir, f"{n}-clients.png")
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"  {out_path}  (n={len(latencies)}, median={median:.2f}ms, p99={p99:.2f}ms)")


def main():
    if len(sys.argv) > 1:
        experiment_dir = os.path.abspath(sys.argv[1])
    else:
        experiment_dir = latest_experiment_dir()

    if not os.path.isdir(experiment_dir):
        sys.exit(f"Diretório não existe: {experiment_dir}")

    rounds = discover_rounds(experiment_dir)
    if not rounds:
        sys.exit(f"Sem subdiretórios N-clients em {experiment_dir}")

    out_dir = os.path.join(experiment_dir, "plots", "per-round")
    os.makedirs(out_dir, exist_ok=True)

    print(f"Experimento: {experiment_dir}")
    print(f"Rounds: {[n for n, _ in rounds]}")
    print(f"Saída: {out_dir}\n")

    for n, rdir in rounds:
        plot_one(n, rdir, out_dir)


if __name__ == "__main__":
    main()
