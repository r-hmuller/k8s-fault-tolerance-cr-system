"""
Mescla os arquivos .pid* gerados pelo benchmark em latency.txt por round.

Uso:
    python merge_pid_logs.py <experiment_dir> [master_host]

master_host padrão: node1.example.net
"""
import sys
import os
import re
import subprocess
import glob


def merge_pids(master, remote_dir, local_round_dir, n, threads, think):
    pattern = f"{remote_dir}/{n}_clients_{threads}_threads_{think}_thinking.txt.pid*"
    result = subprocess.run(
        ["ssh", f"youruser@{master}", f"cat {pattern} 2>/dev/null || true"],
        capture_output=True, text=True)
    if not result.stdout.strip():
        print(f"  N={n}: sem dados no master ({pattern})")
        return False

    total_ok = 0
    lats = []
    sec = None
    for ln in result.stdout.splitlines():
        ln = ln.strip()
        if ln == "--- Status Counts ---":
            sec = "s"; continue
        if ln == "--- Latencies ---":
            sec = "l"; continue
        if ln.startswith("---"):
            sec = None; continue
        if sec == "s" and ln.startswith("204,"):
            try: total_ok += int(ln.split(",")[1])
            except: pass
        elif sec == "l" and "," in ln:
            lats.append(ln)

    out_path = os.path.join(local_round_dir, "latency.txt")
    with open(out_path, "w") as f:
        f.write("--- Status Counts ---\n")
        f.write(f"204,{total_ok}\n")
        f.write("--- Latencies ---\n")
        f.write("\n".join(lats) + "\n")
    print(f"  N={n}: {len(lats)} pontos, {total_ok} req OK → {out_path}")
    return True


def main():
    exp_dir = sys.argv[1] if len(sys.argv) > 1 else None
    master = sys.argv[2] if len(sys.argv) > 2 else "node1.example.net"

    if exp_dir is None:
        base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "experiments-logs")
        candidates = sorted(glob.glob(os.path.join(base, "kv-sweep-*")))
        candidates = [c for c in candidates if os.path.isdir(c)]
        if not candidates:
            sys.exit("Sem experimentos kv-sweep-* em experiments-logs/")
        exp_dir = candidates[-1]

    exp_dir = os.path.abspath(exp_dir)
    exp_name = os.path.basename(exp_dir)
    # Remote dir: under /tmp (gravação sem quota)
    remote_dir = f"/tmp/{exp_name}"

    print(f"Experimento: {exp_dir}")
    print(f"Master: {master}  Remote: {remote_dir}")

    threads, think = 22, 0
    rounds = []
    for entry in os.listdir(exp_dir):
        m = re.match(r"^(\d+)-clients$", entry)
        if not m:
            continue
        rounds.append(int(m.group(1)))
    rounds.sort()

    for n in rounds:
        round_dir = os.path.join(exp_dir, f"{n}-clients")
        merge_pids(master, remote_dir, round_dir, n, threads, think)


if __name__ == "__main__":
    main()
