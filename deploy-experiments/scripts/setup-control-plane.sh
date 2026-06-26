#!/bin/bash
set -e
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
source /home/shrc 2>/dev/null || true
export HOME="$USER_HOME"

CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
K8S_VERSION="v1.32.8"
POD_CIDR="192.168.0.0/16"

# Idempotência: se o cluster já está saudável e o nó CP foi registrado com o
# hostname do experimento atual, pula reinit. Reduz reruns de minutos pra segundos.
# Tem que ficar fora do bloco { ... } 1>&2 abaixo, senão o join command vai pra stderr.
CURRENT_HOST=$(hostname)
if [ -f "$USER_HOME/.kube/config" ]; then
  NODE_NAME=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  READY=$(kubectl get node "$NODE_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$NODE_NAME" = "$CURRENT_HOST" ] && [ "$READY" = "True" ]; then
    echo "Cluster já saudável (nó $NODE_NAME Ready); pulando reinit do CP." >&2
    sudo kubeadm token create --print-join-command
    exit 0
  fi
fi

# Tudo entre { ... } 1>&2 vai pra stderr (o usuário vê o progresso),
# preservando o stdout para a última linha (join command capturado pelo orchestrator).
{
  sudo systemctl is-active --quiet crio || { echo "crio inativo"; exit 1; }

  CP_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)10\.10\.\d+\.\d+' | head -1)
  [ -z "$CP_IP" ] && { echo "Não achei IP 10.10.x.x"; exit 1; }
  echo "CP_IP=$CP_IP"

  echo y | sudo kubeadm reset --cri-socket=unix:///var/run/crio/crio.sock
  sudo rm -rf /etc/cni/net.d
  sudo iptables -F           || true
  sudo iptables -t nat -F    || true
  sudo iptables -t mangle -F || true
  sudo iptables -X           || true

  sudo kubeadm init \
    --apiserver-advertise-address="$CP_IP" \
    --pod-network-cidr="$POD_CIDR" \
    --kubernetes-version="$K8S_VERSION" \
    --cri-socket=unix:///var/run/crio/crio.sock

  mkdir -p "$USER_HOME/.kube"
  sudo cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$USER_HOME/.kube/config"

  kubectl apply -f "$CALICO_URL"
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s
} 1>&2

# Última linha do stdout = join command (orchestrator captura via tail -1)
sudo kubeadm token create --print-join-command
