"""
Compara dois experimentos (ex.: kv-test direto vs com interceptor).

Uso:
    python plot_comparison.py <kv-test_dir> <interceptor_dir> [-o <out_dir>]

Cada dir deve ter o layout {N}-clients/{latency.txt, throughput.log}.
Saída padrão: <kv-test_dir>/plots/comparison/.
"""
import argparse
import os
import re
import sys
import numpy as np
import matplotlib.pyplot as plt


def parse_latency(filepath):
    latencies = []
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
                        latencies.append(float(parts[1]) * 1000)
                    except ValueError:
                        pass
    return latencies


def parse_throughput(filepath):
    counts = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if "," not in line:
                continue
            parts = line.split(",")
            if len(parts) != 2:
                continue
            try:
                counts.append(int(parts[1]))
            except ValueError:
                pass
    return counts


def collect(experiment_dir):
    """Retorna dict {N: {'p50': .., 'p95': .., 'p99': .., 'thr': ..}}."""
    out = {}
    if not os.path.isdir(experiment_dir):
        return out
    for entry in os.listdir(experiment_dir):
        m = re.match(r"(\d+)-clients$", entry)
        if not m:
            continue
        n = int(m.group(1))
        rdir = os.path.join(experiment_dir, entry)
        lat = parse_latency(os.path.join(rdir, "latency.txt"))
        thr = parse_throughput(os.path.join(rdir, "throughput.log"))
        if not lat or not thr:
            continue
        trimmed = thr[1:-1] if len(thr) > 4 else thr
        out[n] = {
            "p50": float(np.percentile(lat, 50)),
            "p95": float(np.percentile(lat, 95)),
            "p99": float(np.percentile(lat, 99)),
            "thr": float(np.mean(trimmed)),
        }
    return out


def plot_latency(stats_a, stats_b, label_a, label_b, out_path):
    clients = sorted(set(stats_a) | set(stats_b))
    if not clients:
        return
    p50_a = [stats_a[c]["p50"] if c in stats_a else np.nan for c in clients]
    p99_a = [stats_a[c]["p99"] if c in stats_a else np.nan for c in clients]
    p50_b = [stats_b[c]["p50"] if c in stats_b else np.nan for c in clients]
    p99_b = [stats_b[c]["p99"] if c in stats_b else np.nan for c in clients]

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(clients, p50_a, marker="o", label=f"{label_a} — mediana", color="steelblue")
    ax.plot(clients, p50_b, marker="o", label=f"{label_b} — mediana", color="darkorange")
    ax.plot(clients, p99_a, marker="s", linestyle="--", label=f"{label_a} — P99", color="steelblue", alpha=0.6)
    ax.plot(clients, p99_b, marker="s", linestyle="--", label=f"{label_b} — P99", color="darkorange", alpha=0.6)
    ax.set_xlabel("Número de clientes")
    ax.set_ylabel("Latência (ms)")
    ax.set_title("Latência por número de clientes")
    ax.set_xticks(clients)
    ax.set_ylim(bottom=0)
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"  {out_path}")


def plot_throughput(stats_a, stats_b, label_a, label_b, out_path):
    clients = sorted(set(stats_a) | set(stats_b))
    if not clients:
        return
    thr_a = [stats_a[c]["thr"] if c in stats_a else np.nan for c in clients]
    thr_b = [stats_b[c]["thr"] if c in stats_b else np.nan for c in clients]

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(clients, thr_a, marker="o", label=label_a, color="steelblue")
    ax.plot(clients, thr_b, marker="o", label=label_b, color="darkorange")
    ax.set_xlabel("Número de clientes")
    ax.set_ylabel("Vazão média (req/s)")
    ax.set_title("Vazão por número de clientes")
    ax.set_xticks(clients)
    ax.set_ylim(bottom=0)
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"  {out_path}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("kv_test_dir", help="experimento sem interceptor")
    p.add_argument("interceptor_dir", help="experimento com interceptor")
    p.add_argument("-o", "--output", help="dir de saída (default: <kv_test_dir>/plots/comparison)")
    p.add_argument("--label-a", default="Sem interceptor")
    p.add_argument("--label-b", default="Com interceptor")
    args = p.parse_args()

    out_dir = args.output or os.path.join(args.kv_test_dir, "plots", "comparison")
    os.makedirs(out_dir, exist_ok=True)

    stats_a = collect(args.kv_test_dir)
    stats_b = collect(args.interceptor_dir)
    if not stats_a or not stats_b:
        sys.exit("Pelo menos um dos experimentos não tem dados utilizáveis")

    print(f"A ({args.label_a}): {sorted(stats_a)}")
    print(f"B ({args.label_b}): {sorted(stats_b)}")
    print(f"Saída: {out_dir}\n")

    plot_latency(stats_a, stats_b, args.label_a, args.label_b,
                 os.path.join(out_dir, "comparison_latencia.png"))
    plot_throughput(stats_a, stats_b, args.label_a, args.label_b,
                    os.path.join(out_dir, "comparison_vazao.png"))


if __name__ == "__main__":
    main()
