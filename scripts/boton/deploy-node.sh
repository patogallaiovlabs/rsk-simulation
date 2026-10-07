#!/usr/bin/env bash
# Deploy one RSKj build to one Boton box as a regtest stress miner.
#
#   scripts/boton/deploy-node.sh <host> <miner-id> <jar> [peer-enode-url]
#   scripts/boton/deploy-node.sh 5.161.112.81 1 /tmp/rsk-baseline.jar
#   GAS_LIMIT=7000000 scripts/boton/deploy-node.sh <host> 1 <jar>   # gas-limit sweep
#
# miner-id picks the deterministic peer key / coinbase / peer port (5050<id>),
# matching the local docker miners. Wipes the node's database: it is a fresh
# experiment every time, never an in-place upgrade.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${1:?usage: deploy-node.sh <host> <miner-id> <jar> [peer-enode-url]}"
MINER_ID="${2:?}"; JAR="${3:?}"; PEER="${4:-}"
KEY="${BOTON_KEY:-$HOME/.ssh/rskj-automation}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 -o ServerAliveInterval=15)
STAGE=$(mktemp -d)

echo "=== staging config for miner-id $MINER_ID ==="
"$ROOT/scripts/boton/make-node-conf.sh" "$STAGE/stress.conf" "$PEER" "${GAS_LIMIT:-25000000}"
# GAS_LIMIT drives BOTH the -D flags and the genesis file; they must move together or
# the node mines against one limit while genesis declares another. Genesis is staged
# under the canonical name genesis.json so nothing downstream encodes the size.
GAS_LIMIT="${GAS_LIMIT:-25000000}"
GAS_M=$((GAS_LIMIT / 1000000))
GENESIS_SRC="$ROOT/rsk/genesis/genesis_${GAS_M}M.json"
[ -f "$GENESIS_SRC" ] || { echo "no genesis for ${GAS_M}M at $GENESIS_SRC" >&2; \
  echo "available: $(ls "$ROOT/rsk/genesis/" | tr '\n' ' ')" >&2; exit 1; }
echo "=== gas limit ${GAS_LIMIT} (genesis_${GAS_M}M.json) ==="
sed -e "s/__MINER_ID__/$MINER_ID/g" -e "s/__GAS_LIMIT__/$GAS_LIMIT/g" \
    "$ROOT/scripts/boton/templates/sysconfig-rsk.tmpl" > "$STAGE/sysconfig-rsk"
grep -q "__GAS_LIMIT__\|__MINER_ID__" "$STAGE/sysconfig-rsk" \
  && { echo "placeholder left unsubstituted in sysconfig-rsk" >&2; exit 1; }

# BOTON_EXTRA_PROPS appends -D flags to JAVA_OPTS, for testing a tunable without
# rebuilding. The motivating case: 35d600ebd bounds DataSourceWithCache's async-flush
# queue at 4 batches and BLOCKS the producer when full --
#   -Ddatasourcewithcache.asyncFlush.maxQueueDepth=N
# raises that bound, which is how you separate "this commit is slow" from "this bound
# is set too low for this workload".
if [ -n "${BOTON_EXTRA_PROPS:-}" ]; then
  # JAVA_OPTS is a line-continued block; append to its last line (no trailing backslash).
  sed -i.bak "s#^ -Dsystem.profiling.enabled=true -Dblockchain.flushNumberOfBlocks=10\$# -Dsystem.profiling.enabled=true -Dblockchain.flushNumberOfBlocks=10 ${BOTON_EXTRA_PROPS}#" \
      "$STAGE/sysconfig-rsk" && rm -f "$STAGE/sysconfig-rsk.bak"
  grep -q -- "${BOTON_EXTRA_PROPS%% *}" "$STAGE/sysconfig-rsk" \
    || { echo "BOTON_EXTRA_PROPS not applied -- check the JAVA_OPTS anchor" >&2; exit 1; }
  echo "  extra props: ${BOTON_EXTRA_PROPS}"
fi
# Seed must match the gas limit: a chain mined at 25M restored under a 7M node is a
# different chain with a different state size, and measures neither. 25M keeps the
# legacy filename (already staged on every box); other limits get a per-limit file,
# uploaded once and reused by later deploys at the same limit.
if [ "$GAS_M" = "25" ]; then
  REMOTE_SEED=/home/ubuntu/seed-loaded-1159.tar.gz
  LOCAL_SEED="$ROOT/bench/live-mining/seed/seed-loaded-1159.tar.gz"
else
  REMOTE_SEED="/home/ubuntu/seed-loaded-1159-${GAS_M}M.tar.gz"
  LOCAL_SEED="$ROOT/bench/live-mining/seed/seed-loaded-1159-${GAS_M}M.tar.gz"
fi
if ! ssh "${SSH_OPTS[@]}" "ubuntu@$HOST" "[ -f '$REMOTE_SEED' ]" 2>/dev/null; then
  [ -f "$LOCAL_SEED" ] || { echo "no seed for ${GAS_M}M at $LOCAL_SEED" >&2
    echo "build it first: scripts/build-seed.sh ${GAS_LIMIT}" >&2; exit 1; }
  echo "=== uploading ${GAS_M}M seed ($(du -h "$LOCAL_SEED" | cut -f1)) -- once per box ==="
  scp -q "${SSH_OPTS[@]}" "$LOCAL_SEED" "ubuntu@$HOST:$REMOTE_SEED"
fi
echo "  seed: $REMOTE_SEED"

cp "$GENESIS_SRC" "$STAGE/genesis.json"
# rsk/logback.xml already wires the BLOCK-BREAKDOWN appender that
# nmt/analyze_block_breakdown.py parses. Two benchmark-only fixes on the way out:
#
#  1. rsk.log's rotation pattern hardcodes ./logs, which the rsk service user
#     cannot write.
#  2. minerserver -> ERROR. At WARN it emits one "Invalid nonce, expected N,
#     found M" line per future-nonce tx per candidate rebuild; a build without
#     the d7d5f68d9 fix wrote 741MB across 144 rotations in 65h (288k lines in a
#     single file) while a build with it wrote 1.7MB. That asymmetric disk I/O
#     lands on the same 2 cores being measured, so it contaminates an A/B. Both
#     sides get ERROR, which keeps the two configs identical.
#
# The repo's rsk/logback.xml is left alone -- the local docker sim keeps WARN.
sed -e 's#<fileNamePattern>\./logs/rskj-#<fileNamePattern>${logging.dir:-./logs}/rskj-#' \
    -e 's#<logger name="minerserver" level="WARN"/>#<logger name="minerserver" level="ERROR"/>#' \
    "$ROOT/rsk/logback.xml" > "$STAGE/logback.xml"

# LEAN_LOGGING=1 silences the trie loggers. Newer builds emit trie_cache_commit /
# trie_cache_save / trie_store_save DEBUG records from inside block execution that
# older builds have no statements for, so the newer side pays logging cost the older
# one does not -- the mirror image of the minerserver spam. Turning them off on BOTH
# sides equalises it. Costs the trie_* rows; keeps totalMs/executeMs/txExecutionMs/
# statePersistMs/saveReceiptsMs, which both sides emit identically.
if [ "${LEAN_LOGGING:-0}" = "1" ]; then
  sed -i.bak -e 's#<logger name="state" level="DEBUG">#<logger name="state" level="INFO">#' \
             -e 's#<logger name="triestore" level="DEBUG">#<logger name="triestore" level="INFO">#' \
             "$STAGE/logback.xml" && rm -f "$STAGE/logback.xml.bak"
  echo "  LEAN_LOGGING: trie loggers silenced on this node"
fi
grep -q 'name="minerserver" level="ERROR"' "$STAGE/logback.xml" \
  || { echo "minerserver logger not suppressed -- check rsk/logback.xml" >&2; exit 1; }

echo "=== pushing to $HOST ($(du -h "$JAR" | cut -f1) jar) ==="
scp -q "${SSH_OPTS[@]}" "$JAR" "ubuntu@$HOST:/tmp/rsk-new.jar"
scp -q "${SSH_OPTS[@]}" "$STAGE/stress.conf" "$STAGE/sysconfig-rsk" \
        "$STAGE/genesis.json" "$STAGE/logback.xml" \
        "$ROOT/scripts/boton/remote/install.sh" "ubuntu@$HOST:/tmp/"
rm -rf "$STAGE"

echo "=== installing ==="
ssh "${SSH_OPTS[@]}" "ubuntu@$HOST" "SEED='$REMOTE_SEED' bash /tmp/install.sh"
