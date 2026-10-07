#!/usr/bin/env bash
# Clone a miner's Docker volume (database) to another miner, skipping a full resync.
#
# Usage:
#   scripts/clone_db.sh <source> <target>
#
# Arguments:
#   source   Container/service name of the donor node  (e.g. rskj-miner1)
#   target   Container/service name of the target node (e.g. rskj-miner2)
#
# What it does:
#   1. Stops both source and target (source needs to be stopped for a consistent
#      RocksDB snapshot; target is overwritten entirely).
#   2. Copies only the DB subdir (test/local-regtest/database) from source to target
#      using an alpine helper.
#   3. Restarts both nodes.
#
# Gotchas (from CLAUDE.md):
#   - Match the DB backend. The source's dbKind.properties must match the target's
#     runtime datasource, or the target ignores the data and resyncs from scratch.
#   - Node identity is safe: peer.privateKey and coinbase derive from MINER_ID via
#     -D system properties, not from the DB, so cloned nodes don't collide.
#
# Example:
#   scripts/clone_db.sh rskj-miner1 rskj-miner2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

COMPOSE_FILE="docker-compose.rskj.yml"
VOLUME_PREFIX="rsk-nodes_rskj-data"

# ── args ──────────────────────────────────────────────────────────────────────
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <source> <target>" >&2
  echo "Example: $0 rskj-miner1 rskj-miner2" >&2
  exit 1
fi

SOURCE="$1"
TARGET="$2"

if [[ "$SOURCE" == "$TARGET" ]]; then
  echo "Error: source and target are the same ($SOURCE)" >&2
  exit 1
fi

# Derive volume names from service names: rskj-miner1 → rsk-nodes_rskj-data-miner1
source_suffix="${SOURCE#rskj-}"   # miner1
target_suffix="${TARGET#rskj-}"   # miner2
SOURCE_VOL="${VOLUME_PREFIX}-${source_suffix}"
TARGET_VOL="${VOLUME_PREFIX}-${target_suffix}"

echo "==> source   : $SOURCE  (volume: $SOURCE_VOL)"
echo "==> target   : $TARGET  (volume: $TARGET_VOL)"

# ── confirm ───────────────────────────────────────────────────────────────────
echo ""
echo "WARNING: This will WIPE $TARGET_VOL:test/local-regtest/database and replace it with $SOURCE_VOL's."
read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# ── ensure volumes exist ───────────────────────────────────────────────────────
for vol in "$SOURCE_VOL" "$TARGET_VOL"; do
  if ! docker volume inspect "$vol" &>/dev/null; then
    echo "Error: volume '$vol' does not exist." >&2
    echo "  Run 'docker volume ls' to see available volumes." >&2
    exit 1
  fi
done

# ── stop both nodes ───────────────────────────────────────────────────────────
echo ""
echo "==> stopping $SOURCE and $TARGET"
docker compose -f "$COMPOSE_FILE" stop "$SOURCE" "$TARGET"

# ── clone volume ──────────────────────────────────────────────────────────────
DB_SUBDIR="test/local-regtest/database"
echo "==> cloning $SOURCE_VOL:/$DB_SUBDIR → $TARGET_VOL:/$DB_SUBDIR (this can take several minutes for large DBs)"
docker run --rm \
  -v "${SOURCE_VOL}:/from:ro" \
  -v "${TARGET_VOL}:/to" \
  alpine sh -c "rm -rf /to/${DB_SUBDIR} && mkdir -p /to/${DB_SUBDIR%/*} && cp -a /from/${DB_SUBDIR} /to/${DB_SUBDIR%/*}/"
echo "    done"

# ── restart both nodes ────────────────────────────────────────────────────────
echo "==> starting $SOURCE and $TARGET"
docker compose -f "$COMPOSE_FILE" start "$SOURCE" "$TARGET"

echo ""
echo "==> clone complete. Watch $TARGET logs to confirm it boots with a non-zero best block:"
echo "    docker logs -f $TARGET | grep -E 'Best block|Completed syncing'"
