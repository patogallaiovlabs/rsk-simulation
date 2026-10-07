#!/usr/bin/env bash
# Run a queue of counterbalanced scenario pairs on the Boton boxes, unattended.
#
#   nohup scripts/boton/queue-scenarios.sh > /tmp/queue.log 2>&1 &
#
# Each entry is label:option:duration:threshold:env — run BOTH directions (box A and
# box D each take both builds), collected and reduced to a box-cancelled build effect.
#
# Why these three:
#   indexer-v2 — the scenario was retuned for block saturation and re-paced on
#                mainnet-sim's model (oversupply + per-account in-flight cap); its
#                earlier numbers came from 30-58% full blocks and were unusable.
#   keccak     — the ONLY trie-write-heavy workload (one ~22M-gas tx per block) and the
#                one scenario never redone after the cross-region bug invalidated it.
#                A full block reads 89.2% there, hence threshold 0.85, not 0.9.
#   calldata   — exercises Transaction.nonZeroDataBytes() memoization, which scales with
#                calldata size and which nothing else in the set touches.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

QUEUE=(
  "indexer-v2:16:30m:0.9:"
  "keccak-seeded:2:30m:0.85:RATE=1 TIME_UNIT=12s PRE_VUS=5"
  "calldata:11:30m:0.9:"
)

for ENTRY in "${QUEUE[@]}"; do
  LABEL="${ENTRY%%:*}"; REST="${ENTRY#*:}"
  OPT="${REST%%:*}"; REST="${REST#*:}"
  DUR="${REST%%:*}"; REST="${REST#*:}"
  TH="${REST%%:*}"; K6ENV="${REST#*:}"
  echo "################################################################"
  echo "[$(date -u +%H:%M:%S)] QUEUE: $LABEL (opt $OPT, $DUR/slot, threshold $TH)"
  echo "################################################################"
  "$ROOT/scripts/boton/run-counterbalanced.sh" "$LABEL" "$OPT" "$DUR" "$K6ENV" "$TH" 2>&1
  echo "[$(date -u +%H:%M:%S)] $LABEL complete"
done
echo "[$(date -u +%H:%M:%S)] QUEUE FINISHED"
