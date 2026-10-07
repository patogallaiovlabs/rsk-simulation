#!/usr/bin/env bash
# Run ONE arm of a local serial A/B: a single miner in Docker, one build, one scenario.
#
#   scripts/local-ab.sh <baseline|tip> <k6-option> <duration> <label> [k6-env]
#   scripts/local-ab.sh baseline 14 40m mainnet-local
#
# Both arms run on the SAME machine, back to back, so there is no box term at all -- the
# failure mode that made two cloud boxes read the same jar 2x apart. What remains is a
# time term; keep the machine otherwise idle and run the arms back to back.
#
# Results land in results/local-ab/<label>-<arm>/ and are analysed with the same
# nmt/analyze_block_breakdown.py used for the Boton runs.
#
# NOTE this is arm64 (Apple Silicon) while Boton is amd64: the *build effect* is
# comparable across the two, absolute millisecond values are not.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM="${1:?usage: local-ab.sh <baseline|tip> <option> <duration> <label> [k6-env]}"
OPT="${2:?}"; DUR="${3:?}"; LABEL="${4:?}"; K6ENV="${5:-}"
IMG="rskj-local:${ARM}"
OUT="$ROOT/results/local-ab/${LABEL}-${ARM}"; mkdir -p "$OUT"
CF="$ROOT/docker-compose.local-ab.yml"

# Gas limit drives BOTH the compose env (genesis + BLOCK_GAS_LIMIT) and which seed is
# restored. A 25M-mined chain restored under a 7M node is a different chain with a
# different state size and measures neither, so they must move together.
GAS_LIMIT="${GAS_LIMIT:-25000000}"
GAS_M=$((GAS_LIMIT / 1000000))
export GAS_LIMIT GAS_M
if [ "$GAS_M" = "25" ]; then
  SEED="${SEED:-$ROOT/bench/live-mining/seed/seed-loaded-1159.tar.gz}"
else
  SEED="${SEED:-$ROOT/bench/live-mining/seed/seed-loaded-1159-${GAS_M}M.tar.gz}"
fi

echo "### local arm '$ARM' ($IMG), option $OPT, $DUR"
docker rm -f rskj-ab >/dev/null 2>&1 || true
AB_IMAGE="$IMG" docker compose -f "$CF" down -v >/dev/null 2>&1 || true

# Restore the pre-loaded database rather than starting from genesis. Every arm therefore
# begins from byte-identical, already-populated state: no warm-up bias, comparable trie
# depth and DB size from the first block, and the receipt/state paths are exercised at a
# realistic size instead of on an empty store.
if [ -f "$SEED" ]; then
  echo "  restoring seed: $(basename "$SEED") ($(du -h "$SEED" | cut -f1))"
  docker volume create rsk-simulation_rskj-data-ab >/dev/null
  # chown after extraction: tar runs as root in the helper container and creates the
  # intermediate dirs (test/, test/local-regtest/) owned by root, while the node runs as
  # user 'rsk'. Without this the node cannot create ANY log file there -- including
  # block-breakdown.log -- and every run silently produces no measurements at all.
  RSK_UID=$(docker run --rm --entrypoint sh "$IMG" -c 'id -u rsk' 2>/dev/null || echo 1000)
  RSK_GID=$(docker run --rm --entrypoint sh "$IMG" -c 'id -g rsk' 2>/dev/null || echo 1000)
  docker run --rm -v rsk-simulation_rskj-data-ab:/to -v "$SEED":/seed.tar.gz:ro alpine \
    sh -c "rm -rf /to/* /to/..?* /to/.[!.]* 2>/dev/null; tar xzf /seed.tar.gz -C /to && chown -R ${RSK_UID}:${RSK_GID} /to" \
    || { echo "  seed restore FAILED"; exit 1; }
  echo "  seed restored: $(docker run --rm -v rsk-simulation_rskj-data-ab:/v alpine du -sh /v/test/local-regtest/database 2>/dev/null | cut -f1)"
else
  echo "  WARNING: no seed at $SEED -- starting from an EMPTY database"
fi

AB_IMAGE="$IMG" docker compose -f "$CF" up -d >/dev/null
echo "  waiting for RPC..."
for i in $(seq 1 60); do
  curl -s -m 3 -X POST http://localhost:4444 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' >/dev/null 2>&1 && break
  sleep 5
done
curl -s -m 3 -X POST http://localhost:4444 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' >/dev/null || { echo "RPC never came up"; exit 1; }
echo "  RPC up; starting k6"

cd "$ROOT/repos/rskj-k6-tests"
# No setsid here: that is a Linux utility and this arm runs on macOS. Detach with a
# subshell + nohup instead, or the run dies with the invoking shell.
( RPC_URL=http://localhost:4444 env $K6ENV DURATION="$DUR" \
    nohup ./infinite.sh "$OPT" > "$OUT/k6.log" 2>&1 < /dev/null & )
echo "  k6 started -> $OUT/k6.log"
echo "  collect with: scripts/local-ab-collect.sh $LABEL $ARM [threshold]"
