#!/usr/bin/env python3
"""Comparativo focado em CAUDA (p95/p99) das 4 configs do sweep de vCPU.
O p50 esconde a diferença (1v colapsa só na cauda) — aqui em escala log.
Lê os summary.txt (cols: clients rps p50 p95 p99)."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# (dir, label, cor)
SERIES = [
    ("kv-direct-sweep-20260607-152333",        "kv-test 1v (direto)", "#444444"),
    ("interceptor-1cpu-sweep-20260607-155218", "interceptor 1v",      "#d62728"),
    ("interceptor-4cpu-sweep-20260607-162231", "interceptor 4v",      "#1f77b4"),
    ("interceptor-6cpu-sweep-20260607-174027", "interceptor 6v",      "#2ca02c"),
]
BASE = "testes-8jun/RESULTADOS-vcpu-kv-vs-interceptor_2026-06-07"

def load(path):
    c, p95, p99 = [], [], []
    with open(os.path.join(BASE, path, "summary.txt")) as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 5 and p[0].isdigit():
                c.append(int(p[0])); p95.append(float(p[3])); p99.append(float(p[4]))
    return c, p95, p99

fig, (axl, axr) = plt.subplots(1, 2, figsize=(13, 6), sharex=True)
for ax, idx, titulo in ((axl, 1, "p95"), (axr, 2, "p99")):
    ax.set_yscale("log")
    ax.axhspan(0.5, 100, color="green", alpha=0.06)   # faixa saudável < 100ms
    ax.axhline(100, color="green", ls=":", lw=1, alpha=0.5)
    for d, label, color in SERIES:
        c, p95, p99 = load(d)
        y = p95 if idx == 1 else p99
        ax.plot(c, y, marker="o", color=color, lw=2, ms=6, label=label)
    ax.set_title(f"{titulo} x clientes")
    ax.set_xlabel("clientes (x8 processos)")
    ax.set_ylabel(f"{titulo} — ms (escala log)")
    ax.grid(True, which="both", alpha=0.25)
axl.legend(title="config", fontsize=9, loc="upper left")

fig.suptitle("Latência de cauda: kv-test direto vs interceptor 1/4/6 vCPU "
             "(mem 6Gi, think=0.03, 90s)\nfaixa verde = <100ms; 1 vCPU colapsa "
             "(~74s no p99 @9 clientes), 4v≈6v estáveis", fontsize=11)
fig.tight_layout(rect=[0, 0, 1, 0.94])
out = os.path.join(BASE, "vcpu_tail_p95_p99.png")
fig.savefig(out, dpi=130)
print("salvo em", out)
