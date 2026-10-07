#!/usr/bin/env bash
# Deterministic block-replay benchmark -- LARGE sample (1158 blocks, 2-1159).
#
# Same methodology as run_replay.sh (see README.md), but replays a much bigger,
# statistically stronger sample: 1158 blocks built specifically to contain 1000+
# blocks at >=90% gas utilization (1026 blocks qualify at that threshold; see
# README.md "Large sample (blocks 2-1159)" section for how it was built).
#
# Usage:
#   ./bench/deterministic-replay/run_replay_1159.sh <label>
#
# Requires: the rsk-nodes-rskj-miner1 image already built from the current repos/rskj
# checkout (docker compose -f docker-compose.rskj.yml build rskj-miner1), and Docker
# running. Produces bench/deterministic-replay/results/<label>_block-breakdown.log and
# <label>_summary.json (percentiles), and prints a table.
#
# To compare two rounds:
#   python3 nmt/analyze_block_breakdown.py --gas-limit 25000000 --threshold 0.9 \
#     --label <after-label> --baseline bench/deterministic-replay/results/<before-label>_summary.json \
#     bench/deterministic-replay/results/<after-label>_block-breakdown.log

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <label>" >&2
  exit 1
fi

LABEL="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_DIR="$REPO_ROOT/bench/deterministic-replay"
RESULTS_DIR="$BENCH_DIR/results"
SCRATCH_VOLUME="${SCRATCH_VOLUME:-rsk-bench-scratch-1159}"
# LOGBACK silences the trie loggers on BOTH arms of a comparison. Newer builds emit
# trie_cache_*/trie_store_* DEBUG records from inside block execution that older builds
# have no statements for, so without this the newer arm pays logging cost the older one
# does not -- an asymmetry that inflates its own txExecutionMs.
#   LOGBACK=$REPO_ROOT/rsk/logback-lean.xml ./run_replay_1159.sh <label>
IMAGE="${IMAGE:-rsk-nodes-rskj-miner1}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$RESULTS_DIR"

echo "==> Extracting seed (genesis+block1, built from the 1159-block chain) into a fresh scratch volume"
docker volume create "$SCRATCH_VOLUME" >/dev/null
docker run --rm -v "$SCRATCH_VOLUME":/to alpine sh -c 'rm -rf /to/* /to/..?* /to/.[!.]* 2>/dev/null; true'
docker run --rm \
  -v "$BENCH_DIR/seed-genesis-block1-1159.tar.gz":/seed.tar.gz:ro \
  -v "$SCRATCH_VOLUME":/to \
  alpine sh -c 'tar xzf /seed.tar.gz -C /to'

echo "==> Staging the blocks-to-replay file"
gunzip -c "$BENCH_DIR/blocks_2_to_1159.txt.gz" > "$TMP_DIR/blocks_replay.txt"
docker run --rm -v "$TMP_DIR":/from:ro -v "$SCRATCH_VOLUME":/to alpine cp /from/blocks_replay.txt /to/blocks_replay.txt

echo "==> Replaying blocks 2-1159 through ConnectBlocks (full connect pipeline)"
# Optional: set CPUSET_CPUS (e.g. "6-9") to pin this container to cores the compose
# miners aren't using, so the replay can run alongside a live network without stopping it.
CPU_PIN_ARGS=()
if [ -n "${CPUSET_CPUS:-}" ]; then
  echo "    Pinning to cpuset-cpus=$CPUSET_CPUS"
  CPU_PIN_ARGS=(--cpuset-cpus "$CPUSET_CPUS")
fi
docker run --rm ${CPU_PIN_ARGS[@]+"${CPU_PIN_ARGS[@]}"} \
  -v "$SCRATCH_VOLUME":/var/lib/rsk \
  -v "$REPO_ROOT/rsk/genesis:/var/lib/rsk/genesis" \
  -v "$REPO_ROOT/rsk/rsk.conf:/var/lib/rsk/rsk.conf" \
  -v "${LOGBACK:-$REPO_ROOT/rsk/logback.xml}:/var/lib/rsk/logback.xml" \
  -e MINER_ID=1 \
  -e IS_MINER=false \
  -e BLOCK_GAS_LIMIT=25000000 \
  -e GENESIS_FILE=/var/lib/rsk/genesis/genesis_25M.json \
  -e FLUSH_BLOCKS=10 \
  -e DEFAULT_JVM_OPTS="-Xms2G -Xmx4G -XX:NativeMemoryTracking=summary" \
  -e RSKJ_SYS_PROPS="-Drsk.conf.file=/var/lib/rsk/rsk.conf -Dlogging.dir=test/local-regtest/" \
  -e RSKJ_LOG_PROPS="-Dlogback.configurationFile=/var/lib/rsk/logback.xml -Dlogging.stdout=INFO -Dlogging.file=INFO -Dlogging=INFO" \
  -e RSKJ_CLASS=co.rsk.cli.tools.ConnectBlocks \
  -e RSKJ_OPTS="--regtest --file /var/lib/rsk/blocks_replay.txt" \
  "$IMAGE" 2>&1 | tee "$RESULTS_DIR/${LABEL}_raw.log" | grep -cE "result IMPORTED_BEST" | xargs -I{} echo "    {} blocks IMPORTED_BEST (want 1158; check ${LABEL}_raw.log if not)"

echo "==> Pulling block-breakdown.log (and any rotated archives) and analyzing"
docker run --rm -v "$SCRATCH_VOLUME":/from:ro -v "$RESULTS_DIR":/to alpine sh -c "
  cp /from/test/local-regtest/block-breakdown.log '/to/${LABEL}_block-breakdown.log'
  for f in /from/test/local-regtest/block-breakdown-*.log.gz; do
    if [ -e \"\$f\" ]; then cp \"\$f\" /to/; fi
  done
  true
"

shopt -s nullglob
ROTATED=("$RESULTS_DIR"/block-breakdown-*.log.gz)
shopt -u nullglob

python3 "$REPO_ROOT/nmt/analyze_block_breakdown.py" --gas-limit 25000000 --threshold 0.9 --label "$LABEL" \
  --save-json "$RESULTS_DIR/${LABEL}_summary.json" \
  "$RESULTS_DIR/${LABEL}_block-breakdown.log" "${ROTATED[@]}"

echo ""
echo "Done. Saved:"
echo "  $RESULTS_DIR/${LABEL}_block-breakdown.log"
echo "  $RESULTS_DIR/${LABEL}_summary.json"
echo ""
echo "To compare against a previous round:"
echo "  python3 nmt/analyze_block_breakdown.py --gas-limit 25000000 --threshold 0.9 --label $LABEL \\"
echo "    --baseline $RESULTS_DIR/<previous-label>_summary.json \\"
echo "    $RESULTS_DIR/${LABEL}_block-breakdown.log"
