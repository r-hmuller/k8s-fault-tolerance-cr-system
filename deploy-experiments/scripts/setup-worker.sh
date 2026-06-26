#!/bin/bash
set -e
JOIN_CMD="$1"

cd /home
source /home/shrc 2>/dev/null || true

# cri-o: signature_policy precisa ser "" pra restore de checkpoint funcionar.
# Profile do Emulab seta signature_policy = "/etc/crio/policy.json"; cri-o
# rejeita a rota de restore se QUALQUER policy estiver definida (mesmo
# insecureAcceptAnything), com erro "namespaced signature policy ... defined".
sudo sed -i -E 's|^(signature_policy = ).*|\1""|' /etc/crio/crio.conf.d/10-crio.conf

# Wrapper de runc: cri-o 1.32 hardcoda os args do `runc checkpoint`/`runc restore`
# e nunca passa --tcp-skip-in-flight/--ext-unix-sk. Sob carga TCP concorrente o
# checkpoint falha com `criu/sk-inet.c:176: inet: In-flight connection (l)` sem
# --tcp-skip-in-flight. Wrapper injeta as flags antes de exec'ar o runc real
# (mantido em /usr/libexec/crio/runc.bin).
#
# NÃO injetamos --tcp-established: com ele o CRIU DUMPA as conexões established e
# no restore tenta re-estabelecê-las; como o pod restaurado tem IP novo, falha com
# `soccr: Can't bind inet socket back: Cannot assign requested address` → restore
# quebra. Em vez disso usamos `tcp-close` no /etc/criu/default.conf (mais abaixo):
# o CRIU não dumpa as established (fecha-as) e o restore sobe limpo.
# Idempotente: o cp pra .bin só roda na primeira vez; o wrapper é reescrito sempre.
if [ ! -f /usr/libexec/crio/runc.bin ]; then
  sudo cp /usr/libexec/crio/runc /usr/libexec/crio/runc.bin
fi
sudo tee /usr/libexec/crio/runc >/dev/null <<'WRAPEOF'
#!/bin/bash
set -e
REAL_RUNC=/usr/libexec/crio/runc.bin
INJECT_CHECKPOINT=(--tcp-skip-in-flight --ext-unix-sk)
INJECT_RESTORE=(--ext-unix-sk)
args=()
extra=()
done_inject=0
for a in "$@"; do
  args+=("$a")
  if [ $done_inject -eq 0 ]; then
    case "$a" in
      checkpoint) extra=("${INJECT_CHECKPOINT[@]}"); done_inject=1 ;;
      restore)    extra=("${INJECT_RESTORE[@]}");    done_inject=1 ;;
      run|create|start|exec|kill|delete|state|ps|spec|init|update|pause|resume|events|list|features|help|--help|-h|--version|-v)
        done_inject=1 ;;
    esac
    if [ ${#extra[@]} -gt 0 ]; then
      args+=("${extra[@]}")
      extra=()
    fi
  fi
done
exec "$REAL_RUNC" "${args[@]}"
WRAPEOF
sudo chmod 755 /usr/libexec/crio/runc
sudo chown root:root /usr/libexec/crio/runc

# tcp-close global do CRIU: no dump, não captura conexões TCP established (fecha-as)
# em vez de dumpá-las. Necessário pro restore funcionar com o IP novo do pod (ver
# comentário do wrapper acima). CRIU lê /etc/criu/default.conf por padrão.
sudo mkdir -p /etc/criu
echo "tcp-close" | sudo tee /etc/criu/default.conf >/dev/null

sudo systemctl restart crio

echo y | sudo kubeadm reset
eval "sudo $JOIN_CMD"

# IP da rede experimental do Emulab (10.10.x.x, baseado no registry 10.10.1.3)
WORKER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)10\.10\.\d+\.\d+' | head -1)
[ -z "$WORKER_IP" ] && { echo "Não achei IP 10.10.x.x"; exit 1; }

# Rebuild do daemon a partir do source: o binário shipado em /home/k8s-cr-daemon-exec/k8s-cr-exec
# tem proto com package "snapshot_rpc" enquanto o interceptor usa "protos", causando Unimplemented
# na chamada gRPC. git pull se já clonado.
DAEMON_SRC=/tmp/k8s-cr-daemon
export PATH=$PATH:/usr/local/go/bin
# O profile do Emulab seta GOPATH=/home/go e HOME=/home (via /home/shrc), ambos
# não-graváveis pelo usuário youruser — go build falha com "permission denied"
# no module cache (/home/go/pkg/mod) e no build cache (/home/.cache/go-build).
# Redireciona ambos pra /tmp (world-writable no nó). Idempotente.
export GOPATH=/tmp/gopath
export GOMODCACHE=/tmp/gopath/pkg/mod
export GOCACHE=/tmp/go-build
mkdir -p "$GOMODCACHE" "$GOCACHE"
if [ -d "$DAEMON_SRC/.git" ]; then
  (cd "$DAEMON_SRC" && git pull)
else
  git clone git@github.com:r-hmuller/k8s-cr-daemon.git "$DAEMON_SRC"
fi
(cd "$DAEMON_SRC" && go build -o k8s-cr-exec .)

# Substitui o placeholder xx.xx.xx.xx (ou IP anterior) sem abrir vim
sudo sed -i -E "s/(CR_DAEMON_K8S_IP=)[^,]+/\1${WORKER_IP}/" \
  /etc/supervisor/conf.d/k8s-cr-daemon.conf

# CR_DAEMON_BASE_IMAGE: tag estável do rootfs original. Daemon usa essa imagem
# pra rootfsImageRef no checkpoint, evitando que a chain de snapshots quebre
# (cri-o GC pode remover layers órfãs quando :latest é sobrescrita pelo daemon
# a cada snapshot, deixando o rootfsImageRef apontando pra ID inexistente).
# Idempotente: insere se ausente, atualiza se presente.
BASE_IMAGE_VAR="CR_DAEMON_BASE_IMAGE=10.10.1.3:5000/rodrigohmuller/kv-test:base-v1"
if sudo grep -q "CR_DAEMON_BASE_IMAGE=" /etc/supervisor/conf.d/k8s-cr-daemon.conf; then
  sudo sed -i -E "s|CR_DAEMON_BASE_IMAGE=[^,]+|${BASE_IMAGE_VAR}|" /etc/supervisor/conf.d/k8s-cr-daemon.conf
else
  sudo sed -i -E "s|^(environment=.*PRIVATE_REGISTRY_URL=[^,]+)|\\1,${BASE_IMAGE_VAR}|" /etc/supervisor/conf.d/k8s-cr-daemon.conf
fi

sudo supervisorctl stop all
sudo install -m 755 -o root -g root "$DAEMON_SRC/k8s-cr-exec" /home/k8s-cr-daemon-exec/k8s-cr-exec
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start all || true
sudo supervisorctl status || true
