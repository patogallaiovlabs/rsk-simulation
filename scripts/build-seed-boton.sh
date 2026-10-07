#!/usr/bin/env bash
# Build a seed database at a given gas limit ON A BOTON BOX (systemd, not docker).
#
#   scripts/build-seed-boton.sh <host> <miner-id> <gas-limit> [target-height] [k6-opt]
#   scripts/build-seed-boton.sh 178.156.204.38 2 10000000
#
# Companion to scripts/build-seed.sh (which builds locally in docker). Same output
# layout, so either seed restores through the same code path.
#
# The box already holds ~/seed-loaded-1159.tar.gz (the 25M seed) and remote/install.sh
# restores it automatically. A seed must be built from GENESIS, so that file is moved
# aside for the duration and put back at the end -- losing it would cost a 1GB transfer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?usage: build-seed-boton.sh <host> <miner-id> <gas-limit> [height] [opt]}"
MINER="${2:?}"; GAS_LIMIT="${3:?}"; TARGET_H="${4:-1159}"; OPT="${5:-14}"
GAS_M=$((GAS_LIMIT / 1000000))
JAR="${SEED_JAR:-/Users/patricio/.claude/jobs/d8b8d974/tmp/deploy/rsk-tip.jar}"
OUT="$ROOT/bench/live-mining/seed/seed-loaded-${TARGET_H}-${GAS_M}M.tar.gz"
S="-i $HOME/.ssh/rskj-automation"
[ -f "$OUT" ] && { echo "seed exists: $OUT -- refusing to overwrite" >&2; exit 0; }

echo "=== ${GAS_M}M seed on $HOST (miner $MINER) -> height $TARGET_H ==="
ssh -i "$HOME/.ssh/rskj-automation" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" \
  'mv -f ~/seed-loaded-1159.tar.gz ~/seed-25M.hold 2>/dev/null; echo "  25M seed parked as ~/seed-25M.hold"'

GAS_LIMIT="$GAS_LIMIT" "$ROOT/scripts/boton/deploy-node.sh" "$HOST" "$MINER" "$JAR" 2>&1 | tail -3

ACTUAL=$(ssh -i "$HOME/.ssh/rskj-automation" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" \
  'sleep 20; curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",false],\"id\":1}" http://127.0.0.1:4444 | python3 -c "import json,sys;print(int(json.load(sys.stdin)[\"result\"][\"gasLimit\"],16))"')
[ "$ACTUAL" = "$GAS_LIMIT" ] || { echo "  MINED BLOCK gasLimit=$ACTUAL, expected $GAS_LIMIT -- aborting" >&2; exit 1; }
echo "  verified on-chain gasLimit: $ACTUAL"

"$ROOT/scripts/boton/run-load.sh" "$HOST" "$OPT" "DURATION=6h" 2>&1 | tail -1

while :; do
  H=$(ssh -i "$HOME/.ssh/rskj-automation" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" \
    'curl -s -m 5 -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}" http://127.0.0.1:4444 | python3 -c "import json,sys;print(int(json.load(sys.stdin)[\"result\"],16))"' 2>/dev/null || echo 0)
  [ "${H:-0}" -ge "$TARGET_H" ] && { echo "  reached height $H"; break; }
  sleep 120
done

echo "=== archiving ==="
ssh -i "$HOME/.ssh/rskj-automation" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" "
  pkill -f '[k]6 run' 2>/dev/null; sleep 3
  sudo systemctl stop rsk; sleep 5          # clean RocksDB close before archiving
  sudo tar czf /tmp/seed-${GAS_M}M.tar.gz -C /var/lib/rsk --transform 's,^database,test/local-regtest/database,' database
  sudo chown ubuntu:ubuntu /tmp/seed-${GAS_M}M.tar.gz
  ls -la /tmp/seed-${GAS_M}M.tar.gz | awk '{print \"  built: \"\$5\" bytes\"}'
  mv -f ~/seed-25M.hold ~/seed-loaded-1159.tar.gz 2>/dev/null; echo '  25M seed restored'"

mkdir -p "$(dirname "$OUT")"
scp -q -i "$HOME/.ssh/rskj-automation" -o IdentitiesOnly=yes -o BatchMode=yes "ubuntu@$HOST:/tmp/seed-${GAS_M}M.tar.gz" "$OUT"
echo "=== done: $OUT ($(du -h "$OUT" | cut -f1)) ==="
