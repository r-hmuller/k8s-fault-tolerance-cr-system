#!/usr/bin/env python3
"""Plot comparativo das 4 configs (todas ClusterIP/6Gi exceto kv-test direto).
Lê os summary.txt e gera rps x clients e p50 x clients lado a lado."""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# (dir, label, cor, marcador)
SERIES = [
    ("kv-direct-sweep-20260607-152333",         "kv-test 1v (direto)", "#444444", "o"),
    ("interceptor-1cpu-sweep-20260607-155218",  "interceptor 1v",      "#d62728", "s"),
    ("interceptor-4cpu-sweep-20260607-162231",  "interceptor 4v",      "#1f77b4", "^"),
    ("interceptor-6cpu-sweep-20260607-174027",  "interceptor 6v",      "#2ca02c", "D"),
]

BASE = "testes-8jun/RESULTADOS-vcpu-kv-vs-interceptor_2026-06-07"

def load(path):
    clients, rps, p50 = [], [], []
    with open(os.path.join(BASE, path, "summary.txt")) as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 5 and p[0].isdigit():
                clients.append(int(p[0])); rps.append(float(p[1])); p50.append(float(p[2]))
    return clients, rps, p50

fig, ax1 = plt.subplots(figsize=(11, 6.5))
ax2 = ax1.twinx()           # eixo direito: latência
ax2.set_yscale("log")
ax2.axhspan(1, 100, color="green", alpha=0.06)  # faixa "saudável" < 100ms

for d, label, color, mk in SERIES:
    c, rps, p50 = load(d)
    ax1.plot(c, rps, marker=mk, color=color, lw=2, ms=6, ls="-",  label=label)  # vazão
    ax2.plot(c, p50, marker=mk, color=color, lw=1.6, ms=5, ls="--", alpha=0.9)  # latência

ax1.set_xlabel("clientes (x8 threads)")
ax1.set_ylabel("vazão — requests/s  (linha cheia)")
ax2.set_ylabel("p50 — ms, escala log  (linha tracejada)")
ax1.grid(True, alpha=0.3)

# Legenda 1: configs (cores). Legenda 2: estilo de linha = métrica.
leg1 = ax1.legend(title="config", fontsize=9, loc="upper right")
ax1.add_artist(leg1)
style_handles = [plt.Line2D([], [], color="#333", ls="-",  lw=2, label="vazão (esq.)"),
                 plt.Line2D([], [], color="#333", ls="--", lw=2, label="p50 (dir.)")]
ax1.legend(handles=style_handles, fontsize=9, loc="center right")

fig.suptitle("kv-test vs interceptor (ClusterIP, 6Gi) — vazão + latência no mesmo eixo\n"
             "nó Emulab E5530 @2.4GHz, kv-test fixo em 1 core", fontsize=11)
fig.tight_layout(rect=[0, 0, 1, 0.95])
out = os.path.join(BASE, "vcpu_comparison.png")
fig.savefig(out, dpi=130)
print("salvo em", out)
