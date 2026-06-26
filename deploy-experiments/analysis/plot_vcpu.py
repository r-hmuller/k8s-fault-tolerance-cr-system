#!/usr/bin/env python3
"""Gera os 2 gráficos comparativos de uma campanha vCPU.
Uso: python3 plot_vcpu.py <pasta_resultados> [rotulo_think]
Descobre sozinho os dirs kv-direct/interceptor-{1,4,6}cpu-sweep-* dentro da pasta.
Saídas na própria pasta: vcpu_comparison.png (vazão+p50) e vcpu_tail_p95_p99.png."""
import sys, os, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = sys.argv[1].rstrip("/")
THINK = sys.argv[2] if len(sys.argv) > 2 else ""

# (prefixo_do_dir, label, cor, marcador)
SPEC = [
    ("kv-direct-sweep-*",        "kv-test 1v (direto)", "#444444", "o"),
    ("interceptor-1cpu-sweep-*", "interceptor 1v",      "#d62728", "s"),
    ("interceptor-4cpu-sweep-*", "interceptor 4v",      "#1f77b4", "^"),
    ("interceptor-6cpu-sweep-*", "interceptor 6v",      "#2ca02c", "D"),
]

def resolve(pat):
    hits = sorted(glob.glob(os.path.join(BASE, pat)))
    return hits[-1] if hits else None

def load(d):
    c, rps, p50, p95, p99 = [], [], [], [], []
    with open(os.path.join(d, "summary.txt")) as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 5 and p[0].isdigit():
                c.append(int(p[0])); rps.append(float(p[1]))
                p50.append(float(p[2])); p95.append(float(p[3])); p99.append(float(p[4]))
    return c, rps, p50, p95, p99

SERIES = []
for pat, label, color, mk in SPEC:
    d = resolve(pat)
    if d:
        SERIES.append((load(d), label, color, mk))

sub = f" — think={THINK}s" if THINK else ""

# ---- Gráfico 1: vazão (linha cheia, esq) + p50 (tracejada, log, dir) ----
fig, ax1 = plt.subplots(figsize=(11, 6.5))
ax2 = ax1.twinx(); ax2.set_yscale("log")
ax2.axhspan(1, 100, color="green", alpha=0.06)
for (c, rps, p50, _, _), label, color, mk in SERIES:
    ax1.plot(c, rps, marker=mk, color=color, lw=2, ms=6, ls="-", label=label)
    ax2.plot(c, p50, marker=mk, color=color, lw=1.6, ms=5, ls="--", alpha=0.9)
ax1.set_xlabel("clientes (x8 processos)")
ax1.set_ylabel("vazão — requests/s  (linha cheia)")
ax2.set_ylabel("p50 — ms, escala log  (linha tracejada)")
ax1.grid(True, alpha=0.3)
leg1 = ax1.legend(title="config", fontsize=9, loc="upper left"); ax1.add_artist(leg1)
ax1.legend(handles=[plt.Line2D([], [], color="#333", ls="-", lw=2, label="vazão (esq.)"),
                    plt.Line2D([], [], color="#333", ls="--", lw=2, label="p50 (dir.)")],
           fontsize=9, loc="lower right")
fig.suptitle(f"Vazão + latência p50: kv-test vs interceptor 1/4/6 vCPU{sub}", fontsize=12)
fig.tight_layout(rect=[0, 0, 1, 0.96])
o1 = os.path.join(BASE, "vcpu_comparison.png"); fig.savefig(o1, dpi=130); plt.close(fig)

# ---- Gráfico 2: cauda p95 / p99 (log) ----
fig, (axl, axr) = plt.subplots(1, 2, figsize=(13, 6), sharex=True)
for ax, sel, tit in ((axl, 3, "p95"), (axr, 4, "p99")):
    ax.set_yscale("log"); ax.axhspan(0.5, 100, color="green", alpha=0.06)
    ax.axhline(100, color="green", ls=":", lw=1, alpha=0.5)
    for vals, label, color, mk in SERIES:
        y = vals[sel]
        ax.plot(vals[0], y, marker="o", color=color, lw=2, ms=6, label=label)
    ax.set_title(f"{tit} x clientes"); ax.set_xlabel("clientes (x8 processos)")
    ax.set_ylabel(f"{tit} — ms (escala log)"); ax.grid(True, which="both", alpha=0.25)
axl.legend(title="config", fontsize=9, loc="upper left")
fig.suptitle(f"Latência de cauda p95/p99{sub} (faixa verde = <100ms)", fontsize=12)
fig.tight_layout(rect=[0, 0, 1, 0.94])
o2 = os.path.join(BASE, "vcpu_tail_p95_p99.png"); fig.savefig(o2, dpi=130); plt.close(fig)

print("salvo:", o1); print("salvo:", o2)
