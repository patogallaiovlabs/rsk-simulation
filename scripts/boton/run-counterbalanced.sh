#!/usr/bin/env bash
# Run one workload as a counterbalanced pair and report the box-cancelled build effect.
#
#   scripts/boton/run-counterbalanced.sh <label> <k6-option> <duration> [k6-env] [threshold]
#   scripts/boton/run-counterbalanced.sh mainnet-sim 14 40m "" 0.9
#
#   slot 1 (forward) : box A = baseline, box B = tip
#   slot 2 (reversed): box A = tip,      box B = baseline
#
# Each box therefore runs both builds, so every estimate compares builds on the same
# hardware; the opposite ordering cancels the time term when the two are averaged.
#
# This exists because a single-direction A/B across two boxes cannot separate a build
# effect from a box effect. Boxes in different Hetzner regions measured the same jar at
# 24ms vs 44ms on this workload -- a 96% "regression" that was pure environment. Even
# co-located boxes show ~8%, which is the same order as the effects being chased.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="${1:?usage: run-counterbalanced.sh <label> <option> <duration> [env] [threshold]}"
OPT="${2:?}"; DUR="${3:?}"; K6ENV="${4:-}"; THRESH="${5:-0.9}"

# minutes to wait for a run of DUR plus deploy/settle overhead
secs=$(python3 -c "
import re,sys
d='$DUR'
m=re.match(r'(\d+)([mh])',d)
n=int(m.group(1)); print(n*60 if m.group(2)=='m' else n*3600)")
SETTLE=$((secs + 300))

echo "############ counterbalanced '$LABEL' — option $OPT, $DUR per slot ############"

echo ">>> slot 1 (forward): box A = baseline, box B = tip"
"$ROOT/scripts/boton/run-experiment.sh" "${LABEL}-fwd" "$OPT" "$DUR" "$K6ENV" ${6:-} 2>&1 | tail -3
echo ">>> waiting ${SETTLE}s for slot 1"
sleep "$SETTLE"
"$ROOT/scripts/boton/collect-experiment.sh" "${LABEL}-fwd" "$THRESH" 20 2>&1 | tail -6

echo ">>> slot 2 (reversed): box A = tip, box B = baseline"
BOTON_JAR_BASELINE=rsk-tip.jar BOTON_JAR_TIP=rsk-baseline.jar \
  "$ROOT/scripts/boton/run-experiment.sh" "${LABEL}-rev" "$OPT" "$DUR" "$K6ENV" ${6:-} 2>&1 | tail -3
echo ">>> waiting ${SETTLE}s for slot 2"
sleep "$SETTLE"
"$ROOT/scripts/boton/collect-experiment.sh" "${LABEL}-rev" "$THRESH" 20 2>&1 | tail -6

echo "############ build effect, box term cancelled ############"
python3 "$ROOT/scripts/boton/crossover_estimate.py" \
  "$ROOT/results/boton/${LABEL}-fwd" "$ROOT/results/boton/${LABEL}-rev" || true
