# deploy-experiments

Automation used to provision the cluster, deploy the components, run the
benchmark campaigns, and analyze the results. These scripts target our
bare-metal testbed (Emulab) and are provided for reproducibility; hostnames,
SSH aliases and the testbed user are environment-specific and must be adapted.

## Layout

| Path | What it does |
|------|--------------|
| `orchestrator.sh` | End-to-end cluster bring-up: registry → control plane (`kubeadm init` + Calico) → worker join (+ CRI-O/CRIU patches) → cert sync → image pre-pull → Multus/macvlan |
| `lib.sh` | Shared shell helpers (`prep_host_dir`, `apply_and_wait`, `preflight_ssh`, NodePort helpers) sourced by the orchestration scripts |
| `scripts/` | Per-node setup scripts, each run on a single host via `ssh host 'bash -s' < script.sh` (`setup-control-plane.sh`, `setup-worker.sh`, `setup-registry.sh`, `setup-multus.sh`, `sync-daemon-certs.sh`, `restore-test-client.sh`) |
| `run-kv-test.sh`, `run-interceptor.sh` | Deploy the workload and the interceptor, wire up NodePorts and `CR_DAEMON_REPLY_TARGET` |
| `run-*.sh` (sweeps/campaigns) | Experiment drivers: client/concurrency/think-time/vCPU sweeps, saturation probes, snapshot/restore tests |
| `ansible-tests/` | Benchmark fan-out across client nodes: `run-tests.yaml` (steady-state), `run-tests-with-pod-kill.yaml` (failover), per-N `inventory-*clients.yaml`, sweep playbooks |
| `analysis/` | Result processing and plotting (`plot_*.py`, `merge_pid_logs.py`) |
| `impl-details.txt` | Exact software stack, versions and flags read live from the nodes — methodology / reproducibility reference |

## Testbed assumptions

- SSH aliases `cp`, `worker`, `registry` (and a `node*.example.net`
  wildcard for clients) configured in `~/.ssh/config`.
- Experimental network on `10.10.x.x`; control plane at `10.10.1.2`,
  registry at `10.10.1.3:5000`.
- Kubernetes v1.32, CRI-O 1.32 + CRIU, Calico CNI (pod CIDR `192.168.0.0/16`).

Adapt the SSH aliases and the ansible inventories (`ansible_user`, host names)
to your environment before running. See [`../TESTING.md`](../TESTING.md) for the
end-to-end walkthrough.
