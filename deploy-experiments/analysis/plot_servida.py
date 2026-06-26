#!/usr/bin/env python3
"""Vazão SERVIDA (bin pela CONCLUSÃO: start+latência) de um run do
run-snapshot-restore-tests.sh. Diferente do plot_snapshot_test.py (que bina pelo
DISPARO e mostra carga ofertada), este mostra o que o serviço realmente concluiu:
buraco = interceptor segurando requests durante o snapshot; rajada = flush do
backlog no unblock. Se houver <run>/kill.log, desenha a linha do kill do pod.

Uso: python3 plot_servida.py <pasta_do_run> [intervalo_snapshot_s]
Lê <run>/<host>/*.pid* e, se existir, <run>/params.txt (clients/think no título).
"""
import sys, os, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = sys.argv[1].rstrip("/")
INTERVAL = int(sys.argv[2]) if len(sys.argv) > 2 else 240
BIN = 10.0

# linhas: "ts,lat" (formato antigo, status desconhecido) ou "ts,lat,status"
rows = []
has_status = False
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
                    if st is not None: has_status = True
                    rows.append((float(a[0]), float(a[1]), st))
                except ValueError: pass
if not rows:
    sys.exit(f"sem latências em {BASE}/*/*.pid*")
t0 = min(r[0] for r in rows)

# título a partir do params.txt, se houver
title_bits = f"snapshot a cada {INTERVAL}s"
params = os.path.join(BASE, "params.txt")
if os.path.exists(params):
    kv = {}
    for ln in open(params):
        for tok in ln.split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                kv[k] = v
    title_bits = (f"{kv.get('clients','?')} clientes, think={kv.get('think','?')}, "
                  f"seed={kv.get('seed_qty','?')}, snapshot a cada {INTERVAL}s")

# janelas REAIS de bloqueio do snapshot, a partir do interceptor-cycle.json
# (logs do interceptor: "Starting snapshot" = interceptor para de enviar;
#  "Snapshot complete, requests unblocked" = libera). Fallback: grade nominal.
import json as _json
from datetime import datetime as _dt
def _iso2epoch(t):
    return _dt.fromisoformat(t.replace("Z", "+00:00")).timestamp()
block_spans = []
cyc = os.path.join(BASE, "interceptor-cycle.json")
# SNAP_MARKS=nominal força a grade por intervalo (estilo antigo) em vez das
# faixas reais de bloqueio lidas do interceptor-cycle.json.
if os.environ.get("SNAP_MARKS") == "nominal":
    cyc = ""
if cyc and os.path.exists(cyc):
    start = None
    for ln in open(cyc, errors="ignore"):
        # aceita JSON puro (kubectl logs) ou com prefixo do cri-o
        # ("timestamp stream F {json}", caso dos logs rotacionados do worker)
        i = ln.find("{")
        if i < 0: continue
        try: d = _json.loads(ln[i:].strip())
        except ValueError: continue
        m = d.get("message", "")
        if m == "Starting snapshot":
            start = _iso2epoch(d["time"])
        elif m == "Snapshot complete, requests unblocked" and start is not None:
            block_spans.append((start - t0, _iso2epoch(d["time"]) - t0))
            start = None

# linha do kill, se houver
kill_t = None
kill_log = os.path.join(BASE, "kill.log")
if os.path.exists(kill_log):
    for tok in open(kill_log).read().split():
        if tok.startswith("epoch="):
            kill_t = float(tok.split("=", 1)[1]) - t0

bins = {}      # conclusões 204 (ou todas, no formato antigo)
err_bins = {}  # conclusões não-204 (só com status no formato novo)
for ts, lat, st in rows:
    b = int((ts + lat - t0) // BIN)
    if st is None or st == "204":
        bins.setdefault(b, []).append(lat * 1000)
    else:
        err_bins[b] = err_bins.get(b, 0) + 1
maxb = max(list(bins) + list(err_bins))
xs  = [b * BIN for b in range(maxb + 1)]
rps = [len(bins.get(b, [])) / BIN for b in range(maxb + 1)]
eps = [err_bins.get(b, 0) / BIN for b in range(maxb + 1)]
p50 = [sorted(bins[b])[len(bins[b]) // 2] if bins.get(b) else None for b in range(maxb + 1)]

fig, ax1 = plt.subplots(figsize=(13, 6.5))
lbl_ok = "vazão servida (204/s)" if has_status else "vazão servida (respostas/s — formato antigo, inclui erros)"
ax1.fill_between(xs, rps, step="post", color="#1f77b4", alpha=0.35)
ax1.plot(xs, rps, color="#1f77b4", lw=1.5, label=lbl_ok)
if os.environ.get("PLOT_ERRORS") == "1" and has_status and any(eps):
    ax1.fill_between(xs, eps, step="post", color="#d62728", alpha=0.45)
    ax1.plot(xs, eps, color="#d62728", lw=1.2, label="erros (não-204/s)")
ax1.set_xlabel("tempo (s)"); ax1.set_ylabel("respostas/s", color="#1f77b4")
ax2 = ax1.twinx()
ax2.plot(xs, p50, "r--", lw=1.2, label="p50 do bin — só 204 (ms)" if has_status else "p50 do bin (ms)")
ax2.set_yscale("log"); ax2.set_ylabel("p50 por bin — ms (log)", color="r")
if block_spans:
    for i, (b0, b1) in enumerate(block_spans):
        if b1 < 0 or b0 > maxb * BIN: continue
        ax1.axvspan(b0, b1, color="green", alpha=0.15)
        ax1.axvline(b0, color="green", ls=":", alpha=0.9)
        ax1.text(b0, ax1.get_ylim()[1] * 0.93, f"snap{i+1} bloqueio {b1-b0:.0f}s",
                 rotation=90, color="green", fontsize=8, ha="right")
else:
    for s in range(INTERVAL, int(maxb * BIN), INTERVAL):
        ax1.axvline(s, color="green", ls=":", alpha=0.8)
        ax1.text(s, ax1.get_ylim()[1] * 0.93, f"snap t+{s}s (nominal)", rotation=90,
                 color="green", fontsize=8, ha="right")
if kill_t is not None:
    ax1.axvline(kill_t, color="purple", ls="--", lw=1.8, alpha=0.9)
    ax1.text(kill_t, ax1.get_ylim()[1] * 0.55, f"kill pod (t≈{kill_t:.0f}s)",
             rotation=90, color="purple", fontsize=9, ha="right", fontweight="bold")
h1, l1 = ax1.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
ax1.legend(h1 + h2, l1 + l2, loc="upper right")
ax1.set_title(f"Vazão SERVIDA (bin pela conclusão) — {title_bits}\n"
              "buraco = interceptor segurando requests; rajada = flush do backlog no unblock")
ax1.grid(alpha=0.3)
out = os.path.join(BASE, "snapshot_servida.png")
plt.tight_layout(); plt.savefig(out, dpi=110)
print("salvo:", out)
