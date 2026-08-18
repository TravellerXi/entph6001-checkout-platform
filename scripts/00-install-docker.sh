#!/usr/bin/env bash
# Installs Docker Engine from Docker's official repository (per Lab 1.2).
# Docker is required only to BUILD images; K3s runs them via containerd.
set -euo pipefail

echo "==> prerequisites"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl >/dev/null
sudo install -m 0755 -d /etc/apt/keyrings

echo "==> Docker GPG key"
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Docker apt repository"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq

echo "==> install engine"
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

# Group membership only takes effect on a new login session.
sudo usermod -aG docker "$USER"

echo "docker : $(sudo docker --version)"
echo "compose: $(sudo docker compose version)"
echo "==> done (re-login required for rootless docker group access)"
