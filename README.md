# k8s-fault-tolerance-cr-system

Fault tolerance and live migration of stateful pods on Kubernetes via
container **checkpoint/restore** (CRIU + CRI-O). This repository unifies the
three components of the system into a single project for reference and
citation.

## Architecture

A gRPC/HTTP **interceptor** sits in front of the stateful workload. It triggers
checkpoints of the running pod, monitors backend health, and replays in-flight
requests after a restore, so that the service survives node failure or
migration with minimal disruption. The actual checkpoint/restore work is
performed by a **node-level daemon** that drives CRI-O/CRIU and publishes the
resulting checkpoint images to a registry. A **key-value workload and
benchmark** is used to measure latency and availability under
checkpoint/restore.

```
            client requests
                  │
                  ▼
        ┌───────────────────┐      gRPC       ┌────────────────────┐
        │  interceptor-grpc │ ───────────────▶│   k8s-cr-daemon    │
        │  (proxy / control)│   snapshot req  │ (node CRIU/CRI-O)  │
        └───────────────────┘                 └────────────────────┘
                  │                                      │
                  ▼                                      ▼
        stateful workload pod                 checkpoint image → registry
                  ▲
                  │  load / measurement
        ┌───────────────────┐
        │ kv-python-benchmark│
        └───────────────────┘
```

## Components

### `interceptor-grpc/` (Go)
gRPC/HTTP interceptor that fronts the workload. Responsibilities:
- queues and reprocesses in-flight requests, draining and replaying them on recovery;
- triggers pod snapshots and talks to the daemon over gRPC (`crController`);
- monitors backend health via heartbeat and gates traffic / canary verdicts during transitions.

### `k8s-cr-daemon/` (Go)
Node-level daemon exposing a gRPC `SnapshotRPCService`. It checkpoints and
restores pods through CRI-O/CRIU and builds/pushes the checkpoint images to the
cluster registry.

### `kv-python-benchmark/` (Python)
Key-value HTTP workload plus an async load generator used to evaluate the
system. It records per-request `ts,lat,status` timelines and latency
percentiles to quantify availability and tail latency during
checkpoint/restore events.

## Repository layout

| Path | Language | Role |
|------|----------|------|
| `interceptor-grpc/` | Go | Request proxy and checkpoint/restore controller |
| `k8s-cr-daemon/`    | Go | Node-level CRIU/CRI-O checkpoint/restore daemon |
| `kv-python-benchmark/` | Python | Workload and benchmark client |

Each component keeps its own build files (`go.mod` / `requirements.txt`) and can
be built independently from its subdirectory.

## Citation

See [`CITATION.cff`](CITATION.cff), or use the **"Cite this repository"** button
on GitHub.
