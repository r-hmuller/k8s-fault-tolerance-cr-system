"""
Gera todos os gráficos agregados de um experimento.

Uso:
    python plot_all.py                    # usa o experimento mais recente
    python plot_all.py <experiment_dir>   # usa o diretório informado

Espera o layout produzido por exp-round.sh:
    <experiment_dir>/
        {N}-clients/
            latency.txt
            throughput.log

Salva os PNGs em <experiment_dir>/plots/.
"""
import os
import re
import sys
import glob
import numpy as np
import matplotlib.pyplot as plt
from datetime import datetime
from scipy.ndimage import uniform_filter1d

COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2"]


def parse_latency(filepath):
    """Lê o bloco --- Latencies --- de latency.txt. Retorna (timestamps, latencies_ms)."""
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
    return np.array(timestamps), np.array(latencies)


def parse_status_counts(filepath):
    """Lê o bloco --- Status Counts --- de latency.txt. Retorna dict {status: count}."""
    counts = {}
    in_block = False
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if line == "--- Status Counts ---":
                in_block = True
                continue
            if line.startswith("---"):
                in_block = False
                continue
            if in_block and "," in line:
                parts = line.split(",")
                if len(parts) == 2:
                    try:
                        counts[str(parts[0])] = int(parts[1])
                    except ValueError:
                        pass
    return counts


def parse_throughput(filepath):
    timestamps, counts = [], []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if "," not in line:
                continue
            parts = line.split(",")
            if len(parts) != 2:
                continue
            try:
                timestamps.append(int(parts[0]))
                counts.append(int(parts[1]))
            except ValueError:
                pass
    return np.array(timestamps), np.array(counts)


def smooth(y, window_frac=0.06):
    if len(y) == 0:
        return y
    w = max(3, int(len(y) * window_frac))
    if w % 2 == 0:
        w += 1
    return uniform_filter1d(y.astype(float), size=w)


def discover_rounds(experiment_dir):
    """Retorna lista ordenada de (N, round_dir)."""
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


def plot_latency_temporal(rounds, out_dir):
    fig, ax = plt.subplots(figsize=(13, 5))
    fig.suptitle("Latência ao longo do tempo (master client)", fontweight="bold")

    for i, (n, rdir) in enumerate(rounds):
        ts, lat = parse_latency(os.path.join(rdir, "latency.txt"))
        if len(lat) == 0:
            continue
        elapsed = ts - ts[0]
        idx = np.argsort(elapsed)
        elapsed, lat = elapsed[idx], lat[idx]
        color = COLORS[i % len(COLORS)]
        ax.scatter(elapsed, lat, s=4, alpha=0.20, color=color)
        if len(lat) >= 10:
            ax.plot(elapsed, smooth(lat, 0.08), linewidth=1.8, color=color, label=f"{n} cliente(s)")

    ax.set_xlabel("Tempo decorrido (s)")
    ax.set_ylabel("Latência (ms)")
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=8, loc="upper right")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    out = os.path.join(out_dir, "latencia_temporal.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  {out}")


def plot_latency_boxplot(rounds, out_dir):
    data, labels = [], []
    for n, rdir in rounds:
        _, lat = parse_latency(os.path.join(rdir, "latency.txt"))
        if len(lat) == 0:
            continue
        p99 = np.percentile(lat, 99)
        data.append(lat[lat <= p99 * 1.5])
        labels.append(f"{n}c")
    if not data:
        return

    fig, ax = plt.subplots(figsize=(max(6, len(data) * 1.2), 5))
    fig.suptitle("Distribuição de latências (clip @ 1.5×P99)", fontweight="bold")
    bp = ax.boxplot(
        data, patch_artist=True,
        medianprops=dict(color="black", linewidth=2),
        flierprops=dict(marker=".", markersize=2, alpha=0.3),
        widths=0.55,
    )
    for patch, color in zip(bp["boxes"], COLORS):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)
    ax.set_xticks(range(1, len(labels) + 1))
    ax.set_xticklabels(labels)
    ax.set_xlabel("Número de clientes")
    ax.set_ylabel("Latência (ms)")
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    out = os.path.join(out_dir, "latencia_distribuicao.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  {out}")


def plot_latency_cdf(rounds, out_dir):
    fig, ax = plt.subplots(figsize=(9, 5))
    fig.suptitle("CDF de latências", fontweight="bold")
    for i, (n, rdir) in enumerate(rounds):
        _, lat = parse_latency(os.path.join(rdir, "latency.txt"))
        if len(lat) == 0:
            continue
        sorted_lat = np.sort(lat)
        cdf = np.arange(1, len(sorted_lat) + 1) / len(sorted_lat)
        ax.plot(sorted_lat, cdf, linewidth=1.6, color=COLORS[i % len(COLORS)],
                label=f"{n} cliente(s)")
    ax.set_xscale("log")
    ax.set_xlabel("Latência (ms, escala log)")
    ax.set_ylabel("F(x)")
    ax.set_ylim(0, 1.005)
    ax.axhline(0.5, linestyle=":", color="gray", linewidth=0.8)
    ax.axhline(0.95, linestyle=":", color="gray", linewidth=0.8)
    ax.axhline(0.99, linestyle=":", color="gray", linewidth=0.8)
    ax.legend(fontsize=8, loc="lower right")
    ax.grid(True, alpha=0.3, which="both")
    plt.tight_layout()
    out = os.path.join(out_dir, "latencia_cdf.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  {out}")


def plot_throughput_temporal(rounds, out_dir):
    fig, ax = plt.subplots(figsize=(13, 5))
    fig.suptitle("Vazão ao longo do tempo (servidor)", fontweight="bold")

    for i, (n, rdir) in enumerate(rounds):
        ts, counts = parse_throughput(os.path.join(rdir, "throughput.log"))
        if len(counts) == 0:
            continue
        if len(ts) > 4:
            ts, counts = ts[1:-1], counts[1:-1]
        elapsed = ts - ts[0]
        color = COLORS[i % len(COLORS)]
        ax.plot(elapsed, counts, linewidth=0.6, alpha=0.30, color=color)
        if len(counts) >= 5:
            ax.plot(elapsed, smooth(counts, 0.06), linewidth=2, color=color, label=f"{n} cliente(s)")

    ax.set_xlabel("Tempo decorrido (s)")
    ax.set_ylabel("Requisições / s")
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=8, loc="upper right")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    out = os.path.join(out_dir, "vazao_temporal.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  {out}")


def plot_scalability(rounds, out_dir):
    """Vazão média + p50/p95/p99 de latência por número de clientes."""
    ns, mean_thr, p50, p95, p99 = [], [], [], [], []
    for n, rdir in rounds:
        ts, counts = parse_throughput(os.path.join(rdir, "throughput.log"))
        _, lat = parse_latency(os.path.join(rdir, "latency.txt"))
        if len(counts) == 0 or len(lat) == 0:
            continue
        trimmed = counts[1:-1] if len(counts) > 4 else counts
        ns.append(n)
        mean_thr.append(float(np.mean(trimmed)))
        p50.append(float(np.percentile(lat, 50)))
        p95.append(float(np.percentile(lat, 95)))
        p99.append(float(np.percentile(lat, 99)))

    if not ns:
        return

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))
    fig.suptitle("Escalabilidade — vazão e latência por número de clientes", fontweight="bold")

    ax1.plot(ns, mean_thr, marker="o", linewidth=2, color="#2563EB")
    for x, y in zip(ns, mean_thr):
        ax1.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(6, 6), fontsize=9)
    ax1.set_xlabel("Número de clientes")
    ax1.set_ylabel("Vazão média (req/s)")
    ax1.set_xticks(ns)
    ax1.set_ylim(bottom=0)
    ax1.grid(True, alpha=0.3)

    ax2.plot(ns, p50, marker="o", label="P50 (mediana)", color="#2ca02c")
    ax2.plot(ns, p95, marker="s", label="P95", color="#ff7f0e", linestyle="--")
    ax2.plot(ns, p99, marker="^", label="P99", color="#d62728", linestyle="--")
    ax2.set_xlabel("Número de clientes")
    ax2.set_ylabel("Latência (ms)")
    ax2.set_xticks(ns)
    ax2.set_ylim(bottom=0)
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    out = os.path.join(out_dir, "escalabilidade.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  {out}")


def plot_status_codes(rounds, out_dir):
    """Stacked bar — counts de cada HTTP status por round, agrupado por classe."""
    per_round = []
    all_codes = set()
    for n, rdir in rounds:
        counts = parse_status_counts(os.path.join(rdir, "latency.txt"))
        per_round.append((n, counts))
        all_codes.update(counts.keys())
    if not all_codes:
        return

    def code_class(code):
        try:
            return int(code) // 100
        except ValueError:
            return 0

    class_color = {2: "#2ca02c", 3: "#1f77b4", 4: "#ff7f0e", 5: "#d62728", 0: "#7f7f7f"}
    codes = sorted(all_codes, key=lambda c: (code_class(c), c))
    ns = [n for n, _ in per_round]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5),
                                   gridspec_kw={"width_ratios": [3, 2]})
    fig.suptitle("HTTP status codes (master client, main thread)", fontweight="bold")

    bottoms = np.zeros(len(ns))
    for code in codes:
        vals = np.array([counts.get(code, 0) for _, counts in per_round], dtype=float)
        ax1.bar(ns, vals, bottom=bottoms, color=class_color.get(code_class(code), "#7f7f7f"),
                edgecolor="white", linewidth=0.4, label=str(code))
        bottoms += vals

    for i, (n, counts) in enumerate(per_round):
        total = sum(counts.values())
        if total:
            ax1.text(n, total, f"{total:,}", ha="center", va="bottom", fontsize=8)

    ax1.set_xlabel("Número de clientes")
    ax1.set_ylabel("Requisições (master client)")
    ax1.set_xticks(ns)
    ax1.legend(title="Status", fontsize=8)
    ax1.grid(True, axis="y", alpha=0.3)

    err_pct = []
    for _, counts in per_round:
        total = sum(counts.values()) or 1
        err = sum(v for c, v in counts.items() if code_class(c) >= 4)
        err_pct.append(100 * err / total)
    ax2.bar(ns, err_pct, color="#d62728", edgecolor="white", linewidth=0.4)
    for n, p in zip(ns, err_pct):
        ax2.text(n, p, f"{p:.2f}%", ha="center", va="bottom", fontsize=8)
    ax2.set_xlabel("Número de clientes")
    ax2.set_ylabel("Erros (4xx + 5xx) %")
    ax2.set_xticks(ns)
    ax2.set_ylim(bottom=0, top=max(err_pct + [1]) * 1.3)
    ax2.grid(True, axis="y", alpha=0.3)

    plt.tight_layout()
    out = os.path.join(out_dir, "status_codes.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  {out}")


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

    out_dir = os.path.join(experiment_dir, "plots")
    os.makedirs(out_dir, exist_ok=True)

    print(f"Experimento: {experiment_dir}")
    print(f"Rounds: {[n for n, _ in rounds]}")
    print(f"Saída: {out_dir}\n")

    plot_latency_temporal(rounds, out_dir)
    plot_latency_boxplot(rounds, out_dir)
    plot_latency_cdf(rounds, out_dir)
    plot_throughput_temporal(rounds, out_dir)
    plot_scalability(rounds, out_dir)
    plot_status_codes(rounds, out_dir)


if __name__ == "__main__":
    main()
