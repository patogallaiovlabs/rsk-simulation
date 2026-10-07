#!/usr/bin/env bash
# Start one labelled A/B experiment across both Boton boxes.
#
#   scripts/boton/run-experiment.sh <label> <k6-option> <duration> [k6-env] [--lean]
#   scripts/boton/run-experiment.sh keccak 2 1h "RATE=1 TIME_UNIT=12s PRE_VUS=5"
#   scripts/boton/run-experiment.sh keccak-lean 2 1h "RATE=1 TIME_UNIT=12s" --lean
#
# Stops and archives the previous run on each box, redeploys both builds cold (page
# cache dropped, database wiped), starts the resource sampler, then starts the load.
# Returns immediately -- collect with collect-experiment.sh.
#
# --lean sets LEAN_LOGGING=1 so trie loggers are silenced on BOTH sides; see
# deploy-node.sh for why that matters when comparing builds of different ages.
#
# NOTE: plain strings, not associative arrays -- macOS ships bash 3.2, where
# `declare -A` is a syntax error.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="${1:?usage: run-experiment.sh <label> <k6-option> <duration> [k6-env] [--lean]}"
OPT="${2:?}"; DUR="${3:?}"; K6ENV="${4:-}"; LEAN="${5:-}"
JARS="${BOTON_JARS:-/Users/patricio/.claude/jobs/d8b8d974/tmp/deploy}"
KEY="${BOTON_KEY:-$HOME/.ssh/rskj-automation}"
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25"

# role:host:miner-id:jar
# The jar for each role can be overridden, which is how the bisect works: box A holds
# the fixed reference build while box B cycles through candidate commits.
#   BOTON_JAR_TIP=rsk-35d600ebd.jar scripts/boton/run-experiment.sh bisect-3 2 30m ...
JAR_BASELINE="${BOTON_JAR_BASELINE:-rsk-baseline.jar}"
JAR_TIP="${BOTON_JAR_TIP:-rsk-tip.jar}"
# Hosts are overridable so a replaced box drops in without editing scripts:
#   BOTON_HOST_B=1.2.3.4 scripts/boton/run-experiment.sh ...
# or set them once in docs/boton/hosts.env (gitignored).
[ -f "$ROOT/docs/boton/hosts.env" ] && . "$ROOT/docs/boton/hosts.env"
HOST_A="${BOTON_HOST_A:-5.161.112.81}"
HOST_B="${BOTON_HOST_B:-91.107.194.5}"
# MINER_ID is normally 1 on box A and 2 on box B, but it is overridable so the pair can
# be SWAPPED. That matters: a brand-new box C, with hardware/JDK/k6/node all verified
# identical to box A, still measured txExecutionMs p50 44ms against box A's 24ms -- the
# same figure the box it replaced produced. The only thing that travelled across the
# rebuild was this role assignment, so swapping the IDs tests whether the asymmetry is
# our configuration rather than the infrastructure.
MINER_A="${BOTON_MINER_A:-1}"
MINER_B="${BOTON_MINER_B:-2}"
NODES="baseline:$HOST_A:$MINER_A:$JAR_BASELINE tip:$HOST_B:$MINER_B:$JAR_TIP"
f() { echo "$1" | cut -d: -f"$2"; }

LEANFLAG=0; [ "$LEAN" = "--lean" ] && LEANFLAG=1
echo "### experiment '$LABEL': option $OPT, duration $DUR, env '${K6ENV:-none}', lean=$LEANFLAG"

for N in $NODES; do
  H=$(f "$N" 2)
  ssh $SSH_OPTS "ubuntu@$H" "
    pkill -f 'sample[-]resources' 2>/dev/null || true
    pkill -f '[i]nfinite.sh' 2>/dev/null || true; sleep 1
    pkill -f '[k]6 run' 2>/dev/null || true; sleep 1
    mkdir -p ~/archive/prev
    mv ~/results/resources.csv ~/archive/prev/ 2>/dev/null || true
    sudo cp /var/log/rsk/stress/block-breakdown* ~/archive/prev/ 2>/dev/null || true
    sudo chown -R ubuntu:ubuntu ~/archive || true
    echo '  '\$(hostname)': previous run stopped and archived'" &
done; wait

for N in $NODES; do
  ROLE=$(f "$N" 1); H=$(f "$N" 2); M=$(f "$N" 3); J=$(f "$N" 4)
  ( LEAN_LOGGING=$LEANFLAG "$ROOT/scripts/boton/deploy-node.sh" "$H" "$M" "$JARS/$J" 2>&1 \
      | grep -E "MemAvailable|git.hash|service:|LEAN" | sed "s/^/  [$ROLE] /" ) &
done; wait

for N in $NODES; do
  H=$(f "$N" 2)
  ssh $SSH_OPTS "ubuntu@$H" '
    mkdir -p ~/results
    setsid nohup bash /tmp/sample-resources.sh 15 /home/ubuntu/results/resources.csv >/tmp/res.log 2>&1 </dev/null &
    sleep 3' &
done; wait
echo "  resource samplers started"

for N in $NODES; do
  ROLE=$(f "$N" 1); H=$(f "$N" 2)
  ( "$ROOT/scripts/boton/run-load.sh" "$H" "$OPT" "DURATION=$DUR ${K6ENV}" 2>&1 \
      | tail -1 | sed "s/^/  [$ROLE] /" ) &
done; wait

mkdir -p "$ROOT/results/boton"
echo "$LABEL opt=$OPT dur=$DUR lean=$LEANFLAG env='${K6ENV}' started $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >> "$ROOT/results/boton/experiments.log"
echo "### started $(date -u +%H:%M:%S) UTC -- collect with: scripts/boton/collect-experiment.sh $LABEL"
