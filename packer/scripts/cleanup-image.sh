#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# Remove provisioning artifacts that do not need to be baked into the image.
sudo rm -f \
  /tmp/amazon-cloudwatch-agent.deb \
  /tmp/run-llama-server.sh \
  /tmp/llama-server.service \
  /tmp/cloudwatch-agent-config.json \
  /tmp/model.gguf \
  /tmp/placeholder-model.txt

# Trim package manager caches and stale package indexes.
sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
sudo env DEBIAN_FRONTEND=noninteractive apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /var/cache/apt/archives/*

# Drop journals and machine-generated logs that are only useful during the bake.
sudo journalctl --rotate || true
sudo journalctl --vacuum-time=1s || true
sudo rm -rf /var/log/journal/*
sudo find /var/log -type f \( -name '*.log' -o -name '*.gz' -o -name '*.[0-9]' \) -delete || true

# Remove transient cloud-init state so instances boot from a clean baseline.
sudo cloud-init clean --logs || true

# Remove any stopped containers or dangling Docker data left by runtime setup.
sudo docker system prune -af --volumes || true

sudo sync
