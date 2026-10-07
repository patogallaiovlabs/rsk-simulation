#!/usr/bin/env bash
# Deterministic block-replay benchmark.
#
# Replays the EXACT same 91 blocks (2-92, ~150-200 heavy transactions each) through
# RSKj's full BlockChainImpl.tryToConnect() pipeline, every time, regardless of which
# machine or which code changes are under test in repos/rskj. See README.md in this
# directory for the full explanation and manual step-by-step equivalent of this script.
#
# Usage:
#   ./bench/deterministic-replay/run_replay.sh <label>
#
# Requires: the rsk-nodes-rskj-miner1 image already built from the current repos/rskj
# checkout (docker compose -f docker-compose.rskj.yml build rskj-miner1), and Docker
# running. Produces bench/deterministic-replay/results/<label>_block-breakdown.log and
# <label>_summary.json (percentiles), and prints a table.
#
# To compare two rounds:
#   python3 nmt/analyze_block_breakdown.py --gas-limit 25000000 --threshold 0.5 \
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
SCRATCH_VOLUME="rsk-bench-scratch"
IMAGE="rsk-nodes-rskj-miner1"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$RESULTS_DIR"

echo "==> Extracting seed (genesis+block1) archive into a fresh scratch volume"
docker volume create "$SCRATCH_VOLUME" >/dev/null
docker run --rm -v "$SCRATCH_VOLUME":/to alpine sh -c 'rm -rf /to/* /to/..?* /to/.[!.]* 2>/dev/null; true'
docker run --rm \
  -v "$BENCH_DIR/seed-genesis-block1.tar.gz":/seed.tar.gz:ro \
  -v "$SCRATCH_VOLUME":/to \
  alpine sh -c 'tar xzf /seed.tar.gz -C /to'

echo "==> Staging the blocks-to-replay file"
gunzip -c "$BENCH_DIR/blocks_2_to_92.txt.gz" > "$TMP_DIR/blocks_replay.txt"
docker run --rm -v "$TMP_DIR":/from:ro -v "$SCRATCH_VOLUME":/to alpine cp /from/blocks_replay.txt /to/blocks_replay.txt

echo "==> Replaying blocks 2-92 through ConnectBlocks (full connect pipeline)"
docker run --rm \
  -v "$SCRATCH_VOLUME":/var/lib/rsk \
  -v "$REPO_ROOT/rsk/genesis:/var/lib/rsk/genesis" \
  -v "$REPO_ROOT/rsk/rsk.conf:/var/lib/rsk/rsk.conf" \
  -v "$REPO_ROOT/rsk/logback.xml:/var/lib/rsk/logback.xml" \
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
  "$IMAGE" 2>&1 | tee "$RESULTS_DIR/${LABEL}_raw.log" | grep -cE "result IMPORTED_BEST" | xargs -I{} echo "    {} blocks IMPORTED_BEST (want 91; check ${LABEL}_raw.log if not)"

echo "==> Pulling block-breakdown.log and analyzing"
docker run --rm -v "$SCRATCH_VOLUME":/from:ro -v "$RESULTS_DIR":/to alpine \
  cp /from/test/local-regtest/block-breakdown.log "/to/${LABEL}_block-breakdown.log"

python3 "$REPO_ROOT/nmt/analyze_block_breakdown.py" --gas-limit 25000000 --threshold 0.5 --label "$LABEL" \
  --save-json "$RESULTS_DIR/${LABEL}_summary.json" \
  "$RESULTS_DIR/${LABEL}_block-breakdown.log"

echo ""
echo "Done. Saved:"
echo "  $RESULTS_DIR/${LABEL}_block-breakdown.log"
echo "  $RESULTS_DIR/${LABEL}_summary.json"
echo ""
echo "To compare against a previous round:"
echo "  python3 nmt/analyze_block_breakdown.py --gas-limit 25000000 --threshold 0.5 --label $LABEL \\"
echo "    --baseline $RESULTS_DIR/<previous-label>_summary.json \\"
echo "    $RESULTS_DIR/${LABEL}_block-breakdown.log"
