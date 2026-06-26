#!/bin/bash
set -e
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
source /home/shrc 2>/dev/null || true
export HOME="$USER_HOME"

MULTUS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml"
MACVLAN_FILE="$USER_HOME/macvlan.yaml"

[ -f "$MACVLAN_FILE" ] || { echo "macvlan.yaml não encontrado em $MACVLAN_FILE"; exit 1; }

kubectl apply -f "$MULTUS_URL"
kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=300s

kubectl apply -f "$MACVLAN_FILE"
