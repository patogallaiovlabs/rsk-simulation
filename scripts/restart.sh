#!/usr/bin/env bash
set -euo pipefail

# Run from the repo root regardless of where this script is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker network create rsk-simulation-net 2>/dev/null || true
docker compose -f docker-compose.tools.yml down -v
docker compose -f docker-compose.rskj.yml down -v
docker compose -f docker-compose.tools.yml up -d
docker compose -f docker-compose.rskj.yml up -d
