#!/usr/bin/env bash
# Unattended Boton counterbalanced runs, cycling scenarios until a wall-clock deadline.
#
#   nohup scripts/boton/boton-sequence.sh 2026-09-23T12:00:00Z > /tmp/botonseq.log 2>&1 &
#
# Per scenario it runs BOTH directions:
#   slot fwd: box A = baseline, box D = tip
#   slot rev: box A = tip,      box D = baseline
# so each box runs both builds and the box term cancels when the two are averaged. This
# is not optional here: boxes in different regions measured the same jar 2x apart, and
# even co-located boxes showed ~8% before settling at parity.
#
# Every run restores the same pre-loaded seed database, so no run starts from genesis.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEADLINE="${1:?usage: boton-sequence.sh <ISO8601 deadline>}"
DUR_MIN="${DUR_MIN:-30}"
DEADLINE_EPOCH=$(python3 -c "import datetime;print(int(datetime.datetime.strptime('$DEADLINE','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))")

# Overridable, as in local-sequence.sh:
#   SCENARIOS="calldata:11:0.9" scripts/boton/boton-sequence.sh <deadline>
SCENARIOS="${SCENARIOS:-mainnet:14:0.9 ecdsa:7:0.9 indexer:16:0.3}"
# Continue numbering past existing bseqN dirs rather than overwriting them.
CYCLE=${CYCLE_OFFSET:-0}
while [ "$(date -u +%s)" -lt "$DEADLINE_EPOCH" ]; do
  CYCLE=$((CYCLE+1))
  for S in $SCENARIOS; do
    NAME=$(echo "$S" | cut -d: -f1); OPT=$(echo "$S" | cut -d: -f2); TH=$(echo "$S" | cut -d: -f3)
    for DIR in fwd rev; do
      NOW=$(date -u +%s); REMAIN=$(( (DEADLINE_EPOCH - NOW) / 60 ))
      [ "$REMAIN" -lt $((DUR_MIN + 15)) ] && { echo "[$(date -u +%H:%M:%S)] ${REMAIN}min left, stopping"; exit 0; }
      LABEL="bseq${CYCLE}-${NAME}-${DIR}"
      echo "[$(date -u +%H:%M:%S)] cycle $CYCLE | $NAME | slot $DIR | ${DUR_MIN}min | ${REMAIN}min left"
      if [ "$DIR" = "fwd" ]; then
        "$ROOT/scripts/boton/run-experiment.sh" "$LABEL" "$OPT" "${DUR_MIN}m" "" >/dev/null 2>&1
      else
        # Swap whatever jars were CONFIGURED, not hardcoded names. These were pinned to
        # rsk-tip.jar/rsk-baseline.jar, so any run overriding BOTON_JAR_* got the right
        # pair in fwd and the wrong one in rev -- silently. It cost 3 cycles of a
        # baseline+probe comparison whose rev slots ran the un-instrumented baseline.
        _JB="${BOTON_JAR_BASELINE:-rsk-baseline.jar}"; _JT="${BOTON_JAR_TIP:-rsk-tip.jar}"
        BOTON_JAR_BASELINE="$_JT" BOTON_JAR_TIP="$_JB" \
          "$ROOT/scripts/boton/run-experiment.sh" "$LABEL" "$OPT" "${DUR_MIN}m" "" >/dev/null 2>&1
      fi
      [ $? -ne 0 ] && { echo "  deploy FAILED, skipping"; continue; }
      sleep $((DUR_MIN * 60))
      "$ROOT/scripts/boton/collect-experiment.sh" "$LABEL" "$TH" 20 2>&1 \
        | grep -E "qualifying|totalMs|txExecutionMs|statePersistMs|saveReceiptsMs" | head -5
    done
    echo "  --- $NAME cycle $CYCLE: build effect (box term cancelled) ---"
    python3 "$ROOT/scripts/boton/crossover_estimate.py" \
      "$ROOT/results/boton/bseq${CYCLE}-${NAME}-fwd" "$ROOT/results/boton/bseq${CYCLE}-${NAME}-rev" 2>&1 | tail -12
  done
done
echo "[$(date -u +%H:%M:%S)] deadline reached after $CYCLE cycles"
