#!/usr/bin/env bash
# Build a seed database at a given gas limit, locally in docker.
#
#   scripts/build-seed.sh <gas-limit> [target-height] [k6-option]
#   scripts/build-seed.sh 7000000
#
# WHY. The gas-limit sweep cannot reuse one seed across limits: a chain mined at 7M and
# one mined at 25M are different chains with different state sizes, so a 25M seed
# restored under a 7M node measures neither. One seed per gas limit is required.
#
# The existing seed-loaded-1159.tar.gz has NO recorded provenance -- this script exists
# so the new ones do. It mines from genesis under live load until the target height,
# then tars the database in the same internal layout the restorers expect
# (test/local-regtest/database/..., restored with --strip-components=3).
#
# Cost: the node mines on a ~10s median block time, so ~1159 blocks is ~3.2h. Run the
# different gas limits in parallel on different machines rather than back to back.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAS_LIMIT="${1:?usage: build-seed.sh <gas-limit> [target-height] [k6-option]}"
TARGET_H="${2:-1159}"          # matches the existing 25M seed's height
OPT="${3:-14}"                 # mainnet-sim: mixed realistic load, so state is populated
GAS_M=$((GAS_LIMIT / 1000000))
GENESIS="$ROOT/rsk/genesis/genesis_${GAS_M}M.json"
OUT="$ROOT/bench/live-mining/seed/seed-loaded-${TARGET_H}-${GAS_M}M.tar.gz"
CF="$ROOT/docker-compose.local-ab.yml"
VOL=rsk-simulation_rskj-data-ab
# docker-compose.local-ab.yml requires AB_IMAGE. The sweep is tip-only, so seeds are
# built with tip unless overridden.
export AB_IMAGE="${AB_IMAGE:-rskj-local:tip}"

[ -f "$GENESIS" ] || { echo "no genesis at $GENESIS" >&2; exit 1; }
[ -f "$OUT" ] && { echo "seed already exists: $OUT -- refusing to overwrite" >&2; exit 0; }

echo "=== building ${GAS_M}M seed to height $TARGET_H (opt $OPT) ==="
docker compose -f "$CF" down -v >/dev/null 2>&1 || true
export GAS_LIMIT GAS_M
docker compose -f "$CF" up -d >/dev/null || { echo "compose up failed" >&2; exit 1; }
echo "  node up at ${GAS_LIMIT} gas limit, EMPTY database (seeds are built from genesis)"

for i in $(seq 1 60); do
  curl -s -m 3 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://localhost:4444 >/dev/null 2>&1 && { echo "  RPC up"; break; }
  sleep 5
done

# Confirm the limit took effect on a MINED BLOCK, not from the env var -- the sweep spec
# is explicit about this, and a silently-wrong limit invalidates every cell built on it.
sleep 15
ACTUAL=$(curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
  http://localhost:4444 | /usr/bin/python3 -c 'import json,sys;print(int(json.load(sys.stdin)["result"]["gasLimit"],16))')
[ "$ACTUAL" = "$GAS_LIMIT" ] || { echo "  MINED BLOCK reports gasLimit=$ACTUAL, expected $GAS_LIMIT" >&2
  docker compose -f "$CF" down -v >/dev/null 2>&1; exit 1; }
echo "  verified on-chain gasLimit: $ACTUAL"

( cd "$ROOT/repos/rskj-k6-tests" && nohup ./infinite.sh "$OPT" > "/tmp/seed-${GAS_M}M-k6.log" 2>&1 < /dev/null & )
echo "  load started; mining to height $TARGET_H ..."

while :; do
  H=$(curl -s -m 5 -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      http://localhost:4444 2>/dev/null | /usr/bin/python3 -c 'import json,sys;print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null || echo 0)
  [ "$H" -ge "$TARGET_H" ] && { echo "  reached height $H"; break; }
  sleep 60
done

pkill -f "k6 run" 2>/dev/null || true
sleep 5
docker compose -f "$CF" stop >/dev/null 2>&1      # clean RocksDB close before archiving
mkdir -p "$(dirname "$OUT")"
docker run --rm -v "$VOL":/from:ro -v "$(dirname "$OUT")":/out alpine \
  tar czf "/out/$(basename "$OUT")" -C /from test/local-regtest/database
docker compose -f "$CF" down -v >/dev/null 2>&1
echo "=== done: $OUT ($(du -h "$OUT" | cut -f1)) ==="
