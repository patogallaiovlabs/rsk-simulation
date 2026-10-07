#!/usr/bin/env bash
set -euo pipefail

# Run from the repo root regardless of where this script is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

KEEP_VOLUMES=0
for arg in "$@"; do
  case "$arg" in
    --keep-volumes|-k)
      KEEP_VOLUMES=1
      ;;
    -h|--help)
      echo "Usage: $0 [--keep-volumes|-k]"
      echo "  --keep-volumes, -k  Restart stacks without deleting volumes."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--keep-volumes|-k]" >&2
      exit 1
      ;;
  esac
done

docker network create rsk-simulation-net 2>/dev/null || true
if [[ "$KEEP_VOLUMES" -eq 1 ]]; then
  docker compose -f docker-compose.tools.yml down
  docker compose -f docker-compose.rskj.yml down
else
  docker compose -f docker-compose.tools.yml down -v
  docker compose -f docker-compose.rskj.yml down -v
fi
docker compose -f docker-compose.tools.yml up -d
docker compose -f docker-compose.rskj.yml up -d
