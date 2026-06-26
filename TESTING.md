# Running the experiments

This document describes how the fault-tolerance / checkpoint-restore system is
deployed and how the benchmark is run to measure latency and availability
during checkpoint/restore events.

## Testbed topology

The experiments run on a small Kubernetes cluster (kubeadm, v1.32) provisioned
on bare-metal nodes:

| Role | Address | Runs |
|------|---------|------|
| Control plane (CP) | `10.10.1.2` | Kubernetes API, **interceptor** (exposed via NodePort) |
| Worker | `10.10.1.x` | **kv workload** pod, **k8s-cr-daemon** (node-level, under supervisor) |
| Registry | `10.10.1.3:5000` | Private image registry |
| Clients × N | `10.10.1.x` | **kv-python-benchmark** load generators |

Requests flow `client → interceptor (CP NodePort) → workload pod (worker)`. When
a checkpoint is triggered, the interceptor coordinates with the daemon over gRPC
and replays in-flight requests after the restore.

## Prerequisites

- **Kubernetes v1.32** with Calico CNI (pod CIDR `192.168.0.0/16`).
- **CRI-O 1.32 + CRIU** on the worker, with two required patches:
  - `signature_policy = ""` in `/etc/crio/crio.conf.d/10-crio.conf` (otherwise
    checkpoint restore fails with a namespaced signature-policy error);
  - a `runc` wrapper that injects `--tcp-established --ext-unix-sk` (and
    `--tcp-skip-in-flight` on checkpoint) so concurrent TCP connections survive
    the dump.
- A reachable **private registry** holding the `kv` workload image and the
  `interceptor-grpc` image.
- **k8s-cr-daemon** running on the worker with valid kubelet client certs
  (`admin.conf`, `apiserver-kubelet-client.{crt,key}`) synced from the CP.
- On each client node: `python3` and the benchmark dependencies
  (`pip install -r kv-python-benchmark/requirements.txt`).

> The cluster bring-up, deployment and benchmark fan-out are automated by the
> scripts under [`deploy-experiments/`](deploy-experiments/), which target our
> Emulab testbed (`deploy-experiments/orchestrator.sh` does the full bring-up).
> The steps below describe the artifacts that matter for reproducing the
> experiment regardless of the provisioning tool; the exact software stack and
> versions are recorded in
> [`deploy-experiments/impl-details.txt`](deploy-experiments/impl-details.txt).

## 1. Build and push the component images

Both Go components generate their gRPC stubs and are built into container images
pushed to the registry:

```bash
# regenerate gRPC code (only if the .proto changed)
make -C interceptor-grpc generate_grpc_code
make -C k8s-cr-daemon   generate_grpc_code

# build + push (uses each component's Dockerfile)
docker build -t <registry>/interceptor-grpc:latest interceptor-grpc/
docker push <registry>/interceptor-grpc:latest
```

The `k8s-cr-daemon` runs directly on the worker node (not as a pod), launched by
`supervisor`, because it needs host access to CRI-O/CRIU.

## 2. Configuration (environment variables)

### interceptor-grpc

| Var | Meaning |
|-----|---------|
| `APPLICATION_URL` | Full URL of the workload behind the interceptor (host:port) |
| `INTERCEPTOR_PORT` | Port the interceptor listens on |
| `GRPC_URL` | The interceptor's own gRPC address |
| `DAEMON_GRPC_URL` | Address of `k8s-cr-daemon` on the worker |
| `NAMESPACE` / `SERVICE_NAME` / `REGISTRY_NAME` | Target pod identity + registry for checkpoint images |
| `HEARTBEAT_ENABLED` / `HEARTBEAT_PATH` | Backend health probing |
| `CHECKPOINT_ENABLED` / `CHECKPOINT_INTERVAL` | Periodic checkpoint trigger |

### k8s-cr-daemon

| Var | Meaning |
|-----|---------|
| `CR_DAEMON_KUBECONFIG_PATH` / `CR_DAEMON_K8S_IP` | Cluster access |
| `CR_DAEMON_KUBELET_API` / `CR_DAEMON_KUBELET_{CERT,KEY,CA}` | Kubelet client TLS |
| `CR_DAEMON_GRPC_PORT` | Port the daemon serves gRPC on |
| `CR_DAEMON_PRIVATE_REGISTRY_URL` | Registry to push checkpoint images |
| `CR_DAEMON_REPLY_TARGET` | Interceptor gRPC endpoint the daemon replies to (set **after** the interceptor's gRPC NodePort exists) |

## 3. Deploy the workload and the interceptor

Apply the workload manifest first, expose it, then point the interceptor's
`APPLICATION_URL` at the workload's NodePort and deploy the interceptor. Finally
set `CR_DAEMON_REPLY_TARGET` on the worker to the interceptor's gRPC NodePort and
restart the daemon. In our setup this is automated by
`deploy-experiments/run-kv-test.sh` and `deploy-experiments/run-interceptor.sh`.

## 4. Run the benchmark

The benchmark spawns one process per "thread", each firing asynchronous requests
against the target URL (the interceptor's HTTP NodePort) for a fixed duration.

```bash
ulimit -n 65536
python3 kv-python-benchmark/main.py \
  <num_threads> <num_clients> <seconds> <url> <out_file> \
  <main_client> <seed_db> <debug> <thinking_time> \
  <save_requests> <replay_requests> <requests_file>
```

Positional arguments:

| # | Argument | Example | Meaning |
|---|----------|---------|---------|
| 1 | `num_threads` | `22` | Processes to spawn on this client |
| 2 | `num_clients` | `5` | Total client nodes (used for labeling/output) |
| 3 | `seconds` | `800` | Test duration |
| 4 | `url` | `http://10.10.1.2:30847` | Interceptor HTTP NodePort |
| 5 | `out_file` | `.../5_clients_22_threads_0.01_thinking.txt` | Latency output file |
| 6 | `main_client` | `True` | Exactly **one** client passes `True` (drives seeding + start signal) |
| 7 | `seed_db` | `True` | Populate the store (100k keys × 1024 B) before the run |
| 8 | `debug` | `False` | Verbose per-request logging |
| 9 | `thinking_time` | `0.01` | Delay between requests (seconds) |
| 10 | `save_requests` | `False` | Record every request to file (for later replay) |
| 11 | `replay_requests` | `False` | Replay a previously recorded request stream |
| 12 | `requests_file` | `.../requests.txt` | File for save/replay |

Only the **main client** (`main_client=True`, typically also the one with
`seed_db=True`) seeds the store and sends the `start` signal; the others just
generate load.

### Multi-client runs (ansible)

In practice the run is fanned out across all client nodes with ansible, driven
by environment variables (from `deploy-experiments/ansible-tests/`):

```bash
cd deploy-experiments/ansible-tests
NUM_THREAD=22 NUM_CLIENT=5 SECONDS_TO_RUN=800 \
SERVER_URL=http://10.10.1.2:30847 THINKING_TIME=0.01 \
ansible-playbook -i inventory-5clients.yaml run-tests.yaml
```

A pod-kill variant (`run-tests-with-pod-kill.yaml`) injects a failure during the
run to measure recovery behavior.

## 5. Output and analysis

Each process writes lines of the form:

```
ts,lat,status
```

`ts` = request timestamp, `lat` = latency, `status` = HTTP status code (e.g. a
`204` served vs. a `500` error — kept distinct so failed responses are not
counted as served throughput). Percentiles and timelines are computed from these
files. Output filenames encode the run parameters
(`<clients>_clients_<threads>_threads_<thinking>_thinking.txt`) so a parameter
sweep produces one file per configuration.

The plotting and aggregation scripts under
[`deploy-experiments/analysis/`](deploy-experiments/analysis/) consume these
files to produce the figures (latency/throughput curves, tail-latency,
snapshot/restore timelines, vCPU comparisons).
