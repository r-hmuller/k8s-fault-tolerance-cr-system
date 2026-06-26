#!/bin/bash
set -e
cd /home
source /home/shrc 2>/dev/null || true
sudo systemctl restart docker.socket
sudo systemctl restart docker.service
sudo docker ps -a

REGISTRY=10.10.1.3:5000

build_and_push() {
  local repo_url="$1" image="$2" build_args="$3"
  local dir="/tmp/${image}"

  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only
  else
    rm -rf "$dir"
    git clone "$repo_url" "$dir"
  fi
  cd "$dir"

  # shellcheck disable=SC2086
  sudo docker build $build_args -t "$image" .
  sudo docker tag "$image" "${REGISTRY}/rodrigohmuller/${image}:latest"
  sudo docker push "${REGISTRY}/rodrigohmuller/${image}:latest"
}

build_and_push https://github.com/r-hmuller/kv-test         kv-test         ""
build_and_push https://github.com/r-hmuller/interceptor-grpc interceptor-grpc ""

# Tag estável do rootfs do kv-test (usado pelo daemon como rootfsImageRef em todos os
# checkpoints). Não é sobrescrita pelo snapshot loop, então cri-o sempre acha a imagem
# durante o restore. Veja CR_DAEMON_BASE_IMAGE no setup-worker.sh.
sudo docker tag kv-test "${REGISTRY}/rodrigohmuller/kv-test:base-v1"
sudo docker push "${REGISTRY}/rodrigohmuller/kv-test:base-v1"
