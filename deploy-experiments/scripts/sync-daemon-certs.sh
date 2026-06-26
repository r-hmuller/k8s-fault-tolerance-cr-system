#!/bin/bash
# Copia admin.conf + apiserver-kubelet-client.{crt,key} do CP pro imported_keys do daemon
# no worker. Necessário a cada experimento Emulab — kubeadm init regenera CA, então o
# admin.conf que vem shipado em /home/k8s-cr-daemon-exec/imported_keys/ fica com cert
# de um cluster antigo e a chamada do daemon pra apiserver falha com x509.
set -e

CP="${1:-cp}"
WORKER="${2:-worker}"
DEST=/home/k8s-cr-daemon-exec/imported_keys

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ssh "$CP" 'sudo cat /etc/kubernetes/admin.conf' > "$TMP/admin.conf"
ssh "$CP" 'sudo cat /etc/kubernetes/pki/apiserver-kubelet-client.crt' > "$TMP/apiserver-kubelet-client.crt"
ssh "$CP" 'sudo cat /etc/kubernetes/pki/apiserver-kubelet-client.key' > "$TMP/apiserver-kubelet-client.key"

cat "$TMP/admin.conf"                   | ssh "$WORKER" "sudo tee $DEST/admin.conf >/dev/null && sudo chmod 600 $DEST/admin.conf"
cat "$TMP/apiserver-kubelet-client.crt" | ssh "$WORKER" "sudo tee $DEST/apiserver-kubelet-client.crt >/dev/null && sudo chmod 644 $DEST/apiserver-kubelet-client.crt"
cat "$TMP/apiserver-kubelet-client.key" | ssh "$WORKER" "sudo tee $DEST/apiserver-kubelet-client.key >/dev/null && sudo chmod 600 $DEST/apiserver-kubelet-client.key"

# Best-effort: o daemon rebuildado exige CR_DAEMON_REPLY_TARGET, que só é setado
# depois pelo run-interceptor.sh (precisa do NodePort gRPC do interceptor, que
# ainda não existe aqui). Logo é esperado o daemon ficar FATAL neste ponto — o
# que importa nesta etapa é só os certs estarem no lugar. Não abortar o
# orchestrator (senão pula pre-pull + Multus).
ssh "$WORKER" 'sudo supervisorctl restart k8s-cr-daemon; sleep 2; sudo supervisorctl status k8s-cr-daemon' || true
