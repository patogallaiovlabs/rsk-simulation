#!/usr/bin/env bash
# Unattended local serial A/B, cycling scenarios until a wall-clock deadline.
#
#   nohup scripts/local-sequence.sh 2026-09-23T12:00:00Z > /tmp/localseq.log 2>&1 &
#
# For each scenario it runs baseline then tip, back to back on the same machine, each
# starting from the identical pre-loaded seed database. Cycles round the scenario list
# until the deadline, so later cycles are repetitions -- which is the point: with the
# same build, replay runs varied 12-14% on totalMs, so a single run of anything proves
# nothing. Repetitions are what let an effect be separated from that noise.
#
# Arms alternate baseline-first/tip-first per cycle so any drift over the night does not
# land preferentially on one build.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEADLINE="${1:?usage: local-sequence.sh <ISO8601 deadline, e.g. 2026-09-23T12:00:00Z>}"
DUR_MIN="${DUR_MIN:-30}"
DEADLINE_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.strptime('$DEADLINE','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))")

# scenario:option:threshold  (indexer does not saturate blocks, hence the low threshold)
# Overridable so a single scenario can be cycled on its own without editing this list:
#   SCENARIOS="calldata:11:0.9" scripts/local-sequence.sh <deadline>
SCENARIOS="${SCENARIOS:-mainnet:14:0.9 ecdsa:7:0.9 indexer:16:0.3}"
# Cycle numbering continues from previously collected cycles instead of restarting at
# 1, which would overwrite results/local-ab/seq1-* from an earlier sequence. Set to the
# highest existing seqN before launching a follow-up run.
CYCLE=${CYCLE_OFFSET:-0}
while [ "$(date -u +%s)" -lt "$DEADLINE_EPOCH" ]; do
  CYCLE=$((CYCLE+1))
  for S in $SCENARIOS; do
    NAME=$(echo "$S" | cut -d: -f1); OPT=$(echo "$S" | cut -d: -f2); TH=$(echo "$S" | cut -d: -f3)
    # alternate which build goes first each cycle
    if [ $((CYCLE % 2)) -eq 1 ]; then ARMS="baseline tip"; else ARMS="tip baseline"; fi
    for ARM in $ARMS; do
      NOW=$(date -u +%s)
      REMAIN=$(( (DEADLINE_EPOCH - NOW) / 60 ))
      [ "$REMAIN" -lt $((DUR_MIN + 5)) ] && { echo "[$(date -u +%H:%M:%S)] ${REMAIN}min left, stopping"; exit 0; }
      LABEL="seq${CYCLE}-${NAME}"
      echo "[$(date -u +%H:%M:%S)] cycle $CYCLE | $NAME (opt $OPT) | arm $ARM | ${DUR_MIN}min | ${REMAIN}min budget left"
      "$ROOT/scripts/local-ab.sh" "$ARM" "$OPT" "${DUR_MIN}m" "$LABEL" >/dev/null 2>&1 \
        || { echo "  launch FAILED"; continue; }
      sleep $((DUR_MIN * 60))
      "$ROOT/scripts/local-ab-collect.sh" "$LABEL" "$ARM" "$TH" 2>&1 | grep -E "qualifying|totalMs|txExecutionMs|statePersistMs|no block-breakdown" | head -5
      # ABORT on a run that produced no data. An earlier overnight sequence logged
      # "no block-breakdown.log recovered" on every arm and kept going for ~10 hours,
      # producing 24 empty results. A harness that cannot collect must stop, not persist.
      if [ ! -s "$ROOT/results/local-ab/${LABEL}-${ARM}/summary.json" ]; then
        echo "[$(date -u +%H:%M:%S)] ABORT: ${LABEL}-${ARM} produced no summary.json -- collection is broken, stopping the sequence"
        exit 1
      fi
    done
  done
done
echo "[$(date -u +%H:%M:%S)] deadline reached after $CYCLE cycles"
