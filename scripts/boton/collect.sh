#!/usr/bin/env bash
# Pull a run's block-breakdown logs off a Boton box and summarise them.
#
#   scripts/boton/collect.sh <host> <label> [outdir]
#   scripts/boton/collect.sh 5.161.112.81 baseline results/boton
#
# Then compare two runs:
#   python3 nmt/analyze_block_breakdown.py --label tip \
#     --baseline results/boton/baseline_summary.json results/boton/tip/block-breakdown.log
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${1:?usage: collect.sh <host> <label> [outdir]}"; LABEL="${2:?}"
OUT="${3:-$ROOT/results/boton}/$LABEL"
KEY="${BOTON_KEY:-$HOME/.ssh/rskj-automation}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25)
mkdir -p "$OUT"

# The log files are owned by the rsk user, so stage a readable copy first.
ssh "${SSH_OPTS[@]}" "ubuntu@$HOST" '
  rm -rf /tmp/collect && mkdir -p /tmp/collect
  sudo cp /var/log/rsk/stress/block-breakdown.log* /tmp/collect/ 2>/dev/null || true
  sudo cp /var/log/rsk/stress/rsk.log             /tmp/collect/ 2>/dev/null || true
  cp ~/results/*.log /tmp/collect/ 2>/dev/null || true
  sudo chown -R ubuntu:ubuntu /tmp/collect; ls /tmp/collect | head'
scp -q "${SSH_OPTS[@]}" "ubuntu@$HOST:/tmp/collect/*" "$OUT/" || true
echo "-> $OUT"; ls -lh "$OUT" | tail -5

python3 "$ROOT/nmt/analyze_block_breakdown.py" --label "$LABEL" \
        --save-json "$OUT/../${LABEL}_summary.json" "$OUT"/block-breakdown.log* || \
  echo "(analyze step failed -- run nmt/analyze_block_breakdown.py manually)"
