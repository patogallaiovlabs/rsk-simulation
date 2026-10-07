#!/usr/bin/env bash
# Runs ON a Boton box. Installs node 20 + k6 so the load generator runs locally
# against 127.0.0.1:4444 -- no inbound firewall rule needed, and no WAN latency
# between k6 and the node. Idempotent.
set -euo pipefail
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg jq
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs
fi
if ! command -v k6 >/dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/k6.gpg
  sudo chmod a+r /etc/apt/keyrings/k6.gpg
  echo "deb [signed-by=/etc/apt/keyrings/k6.gpg] https://dl.k6.io/deb stable main" \
    | sudo tee /etc/apt/sources.list.d/k6.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq k6
fi
echo "node=$(node --version) npm=$(npm --version) k6=$(k6 version 2>&1 | head -1)"
