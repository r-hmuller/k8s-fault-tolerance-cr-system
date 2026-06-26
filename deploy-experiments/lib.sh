# Helpers compartilhados pelos scripts de orquestração no root do projeto.
# Não tem shebang porque é só pra `source`.

# Garante que um diretório existe no host com 777 (containers non-root precisam gravar).
prep_host_dir() {
  local host="$1" dir="$2"
  ssh "$host" "sudo mkdir -p $dir && sudo chmod 777 $dir"
}

# Aplica um manifest no CP e espera o rollout do deployment indicado.
apply_and_wait() {
  local cp="$1" yaml="$2" deployment="$3" timeout="${4:-120s}"
  ssh "$cp" "bash -lc 'export HOME=\$(getent passwd \$(whoami) | cut -d: -f6); \
    kubectl apply -f $yaml && \
    kubectl rollout status deploy/$deployment --timeout=$timeout'"
}

# Pre-flight: SSH funciona em todos os hosts (falha cedo se 1Password agent estiver bloqueado).
preflight_ssh() {
  local host
  for host in "$@"; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true \
      || { echo "SSH falhou em $host (1Password agent bloqueado? alias quebrado?)"; return 1; }
  done
}

# Cria Service NodePort pra um deployment, se ainda não existir. Idempotente entre reruns
# (sem isso, recriar muda o NodePort e quebra os yamls que referenciam a porta antiga).
ensure_nodeport_svc() {
  local cp="$1" deployment="$2" svc="$3" port="$4"
  ssh "$cp" "bash -lc 'kubectl get svc $svc >/dev/null 2>&1 || \
    kubectl expose deployment/$deployment --name=$svc --type=NodePort --port=$port'"
}

# Lê o NodePort de um Service. Se port_name for passado, filtra por nome; senão pega a primeira porta.
get_nodeport() {
  local cp="$1" svc="$2" port_name="${3:-}"
  if [ -n "$port_name" ]; then
    ssh "$cp" "kubectl get svc $svc -o jsonpath='{.spec.ports[?(@.name==\"$port_name\")].nodePort}'"
  else
    ssh "$cp" "kubectl get svc $svc -o jsonpath='{.spec.ports[0].nodePort}'"
  fi
}
