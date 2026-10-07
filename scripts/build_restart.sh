#!/usr/bin/env bash
set -euo pipefail

# Run from the repo root regardless of where this script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

KEEP_VOLUMES=0
for arg in "$@"; do
  case "$arg" in
    --keep-volumes|-k)
      KEEP_VOLUMES=1
      ;;
    -h|--help)
      echo "Usage: $0 [--keep-volumes|-k]"
      echo "  --keep-volumes, -k  Rebuild images and restart without deleting volumes."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--keep-volumes|-k]" >&2
      exit 1
      ;;
  esac
done

docker compose -f docker-compose.rskj.yml build --no-cache
if [[ "$KEEP_VOLUMES" -eq 1 ]]; then
  "$SCRIPT_DIR/restart.sh" --keep-volumes
else
  "$SCRIPT_DIR/restart.sh"
fi
