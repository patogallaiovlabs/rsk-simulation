#!/usr/bin/env bash
# Stop a local arm, pull its block-breakdown log out of the container, and summarise.
#   scripts/local-ab-collect.sh <label> <arm> [threshold]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:?}"; ARM="${2:?}"; THRESH="${3:-0.9}"
OUT="$ROOT/results/local-ab/${LABEL}-${ARM}"
pkill -f "[i]nfinite.sh" 2>/dev/null || true; sleep 1
pkill -f "[k]6 run" 2>/dev/null || true; sleep 1
docker cp rskj-ab:/var/lib/rsk/test/local-regtest/block-breakdown.log "$OUT/" 2>/dev/null || \
  docker exec rskj-ab sh -c 'cat $(ls -t /var/lib/rsk/test/local-regtest/block-breakdown.log 2>/dev/null | head -1)' > "$OUT/block-breakdown.log" 2>/dev/null || true
if [ -s "$OUT/block-breakdown.log" ]; then
  python3 "$ROOT/nmt/analyze_block_breakdown.py" --label "${LABEL}-${ARM}" --threshold "$THRESH" \
    --min-block 20 --save-json "$OUT/summary.json" "$OUT/block-breakdown.log" | tail -18
else
  echo "no block-breakdown.log recovered from the container -- check the logging.dir path"
fi
