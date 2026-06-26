#!/bin/bash
set -euo pipefail

CP=cp
WORKER=worker
REGISTRY=registry
REGISTRY_IP=10.10.1.3
IMAGES=(kv-test interceptor-grpc)

source "$(dirname "$0")/lib.sh"

echo "==> Pre-flight: SSH em todos os hosts"
preflight_ssh "$REGISTRY" "$CP" "$WORKER"

echo "==> Registry"
ssh $REGISTRY 'bash -s' < scripts/setup-registry.sh

echo "==> Control plane (gerando join token)"
JOIN_CMD=$(ssh $CP 'bash -s' < scripts/setup-control-plane.sh | tail -1)
echo "Join: $JOIN_CMD"

echo "==> Worker"
# Re-run idempotente: o `kubeadm reset` dentro do setup-worker.sh limpa só o
# estado local do worker; o Node object continua registrado (Ready) no etcd do
# CP. Sem remover, o re-join falha com "a Node with name ... already exists".
#
# Ordem importa: se o kubelet do worker estiver vivo (rerun logo após um join
# bem-sucedido), ele RECRIA o Node no mesmo instante em que o apagamos no CP,
# e o join seguinte volta a falhar com "already exists". Por isso paramos o
# kubelet (reset local) ANTES de deletar no CP, e esperamos o delete concluir
# (sem --wait=false). --ignore-not-found torna tudo no-op num experimento novo.
WORKER_NODE=$(ssh $WORKER hostname -f)
ssh $WORKER 'sudo systemctl stop kubelet 2>/dev/null || true; \
  echo y | sudo kubeadm reset --cri-socket=unix:///var/run/crio/crio.sock >/dev/null 2>&1 || true'
ssh $CP "kubectl delete node $WORKER_NODE --ignore-not-found --timeout=60s" || true
ssh $WORKER "bash -s -- $(printf %q "$JOIN_CMD")" < scripts/setup-worker.sh

echo "==> Sync daemon certs (CP -> worker imported_keys)"
"$(dirname "$0")/scripts/sync-daemon-certs.sh" "$CP" "$WORKER"

# Workaround duplicate-IP: em alguns mapeamentos de nó o Emulab atribui o IP do
# registry (10.10.1.3) também a um nó cliente (ex.: node1), e os dois respondem
# ARP no mesmo segmento L2. O worker pode cachear o MAC errado e o pull/push pro
# registry leva RST ("connection refused") mesmo com o registry de pé. Fixamos um
# ARP estático no worker pro MAC real do registry (resolvido dinamicamente do
# próprio nó registry). Idempotente; `nud permanent` sobrevive ao kubeadm reset.
echo "==> Pin ARP do registry ($REGISTRY_IP) no worker"
REG_MAC=$(ssh $REGISTRY "dev=\$(ip -o -4 addr show | awk '/$REGISTRY_IP/ {print \$2; exit}'); cat /sys/class/net/\$dev/address")
WRK_DEV=$(ssh $WORKER "ip -o -4 addr show | awk '/10\\.10\\./ {print \$2; exit}'")
echo "   registry MAC=$REG_MAC  worker dev=$WRK_DEV"
ssh $WORKER "sudo ip neigh replace $REGISTRY_IP lladdr $REG_MAC dev $WRK_DEV nud permanent"

echo "==> Pre-pull imagens no worker"
for img in "${IMAGES[@]}"; do
  ssh $WORKER "sudo crictl pull $REGISTRY_IP:5000/rodrigohmuller/$img:latest"
done

echo "==> Verificando cluster"
ssh $CP "kubectl get nodes"

echo "==> Multus + macvlan no control plane"
ssh $CP 'bash -s' < scripts/setup-multus.sh
