import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np

df = pd.read_csv("resultados-tempo-snapshot.csv")
df.columns = df.columns.str.strip()

registros = df["quantidade_registros"]
tempos = df["tempo(s)"]

# --- Análise ---
df["throughput"] = registros / tempos
df["tempo_por_registro_ms"] = (tempos / registros) * 1000

print("=== Dados brutos ===")
print(df[["quantidade_registros", "tempo(s)", "throughput", "tempo_por_registro_ms"]].to_string(index=False))

# Crescimento relativo
print("\n=== Crescimento relativo entre pontos ===")
for i in range(1, len(df)):
    fator_reg = registros.iloc[i] / registros.iloc[i - 1]
    fator_tempo = tempos.iloc[i] / tempos.iloc[i - 1]
    print(
        f"  {int(registros.iloc[i-1]):>9,} → {int(registros.iloc[i]):>9,}: "
        f"registros x{fator_reg:.1f}, tempo x{fator_tempo:.2f}  "
        f"(razão tempo/registros = {fator_tempo/fator_reg:.3f})"
    )

# Ajuste de curva (linear e potência)
log_r = np.log(registros)
log_t = np.log(tempos)
coef = np.polyfit(log_r, log_t, 1)
expoente = coef[0]
print(f"\n=== Ajuste de lei de potência: tempo ∝ n^{expoente:.4f} ===")
if expoente < 1.05:
    print("  → Comportamento próximo de O(n) — crescimento LINEAR")
elif expoente < 1.5:
    print("  → Comportamento entre O(n) e O(n log n) — levemente super-linear")
else:
    print("  → Comportamento super-linear significativo")

# --- Gráfico ---
fig, ax = plt.subplots(figsize=(8, 5))

ax.plot(registros, tempos, marker="o", linewidth=2, markersize=7, color="#2563EB")

for x, y in zip(registros, tempos):
    ax.annotate(f"{y:.1f}s", (x, y), textcoords="offset points", xytext=(6, 6), fontsize=9)

ax.set_xlabel("Quantidade de Registros")
ax.set_ylabel("Tempo (s)")
ax.xaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{int(v):,}"))
ax.grid(True, linestyle="--", alpha=0.5)

plt.tight_layout()
plt.savefig("grafico_snapshot.png", dpi=150, bbox_inches="tight")
print("\nGráfico salvo em: grafico_snapshot.png")
plt.show()
