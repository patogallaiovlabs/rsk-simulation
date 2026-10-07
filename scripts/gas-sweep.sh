#!/usr/bin/env bash
# One machine's share of the gas-limit sweep: block processing time vs gas limit, on the
# tip build only. The build is held constant; the gas limit is the variable.
#
#   scripts/gas-sweep.sh <host|local> <miner-id> <cycles> <opt:limit,limit,...> ...
#   scripts/gas-sweep.sh 5.78.115.226 3 6 14:7000000,10000000,17000000,25000000 11:17000000,25000000
#
# WHOLE SCENARIOS ARE PINNED TO ONE MACHINE, deliberately. An A/A with identical jars,
# seeds and gas limits measured 89ms on us-west against 129ms on us-east -- a 45% box
# term, the same order as the effects being chased. Keeping every gas limit of a curve
# on one machine makes that term constant within the curve, so it cancels from the
# SHAPE. It does NOT make absolutes comparable across machines: never overlay two
# scenarios from different boxes on a shared axis.
#
# Each run is deployed cold from the seed matching its gas limit, so no run inherits
# page cache or database growth from the previous one.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?usage: gas-sweep.sh <host|local> <miner-id> <cycles> <opt:limits> ...}"
MINER="${2:?}"; CYCLES="${3:?}"; shift 3
DUR_MIN="${DUR_MIN:-30}"
JAR="${SWEEP_JAR:-/Users/patricio/.claude/jobs/d8b8d974/tmp/deploy/rsk-tip.jar}"
BUILD="${SWEEP_BUILD:-392ae5506}"
OUT="$ROOT/results/sweep/sweep-runs.csv"
KEY="$HOME/.ssh/rskj-automation"
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo "machine,scenario_opt,gas_limit,cycle,build,mean_util,qualifying_blocks,height_from,height_to,totalMs_p50,totalMs_p95,totalMs_max,executeMs_p50,txExecutionMs_p50,statePersistMs_p50,saveReceiptsMs_p50,verdict" > "$OUT"

STATS_PY='
import re,sys,statistics as st
LIM=int(sys.argv[1])
rxc=re.compile(r"block connect breakdown.*?block=(\d+).*?totalMs=(\d+).*?executeMs=(\d+).*?saveReceiptsMs=(\d+).*?gasUsed=(\d+)")
rxe=re.compile(r"block execute breakdown.*?block=(\d+).*?txExecutionMs=(\d+).*?statePersistMs=(\d+).*?gasUsed=(\d+)")
tot=[];ex=[];sr=[];txe=[];sp=[];util=[];hs=[]
for ln in sys.stdin:
    m=rxc.search(ln)
    if m:
        h,t,e,s,g=(int(x) for x in m.groups()); util.append(g/LIM)
        if g>=0.9*LIM: tot.append(t);ex.append(e);sr.append(s);hs.append(h)
        continue
    m=rxe.search(ln)
    if m:
        h,x,p,g=(int(v) for v in m.groups())
        if g>=0.9*LIM: txe.append(x);sp.append(p)
p50=lambda v: round(st.median(v),1) if v else ""
p95=lambda v: round(sorted(v)[int(len(v)*0.95)],1) if v else ""
mx =lambda v: max(v) if v else ""
mu = round(sum(util)/len(util),4) if util else 0
print(",".join(str(x) for x in [mu,len(tot),min(hs) if hs else "",max(hs) if hs else "",
      p50(tot),p95(tot),mx(tot),p50(ex),p50(txe),p50(sp),p50(sr)]))
'

for SPEC in "$@"; do
  OPT="${SPEC%%:*}"; LIMITS="${SPEC#*:}"
  for GL in ${LIMITS//,/ }; do
    GM=$((GL / 1000000))
    for C in $(seq 1 "$CYCLES"); do
      echo "[$(date -u +%H:%M:%S)] $HOST | opt $OPT | ${GM}M | cycle $C/$CYCLES"

      if [ "$HOST" = "local" ]; then
        export GAS_LIMIT=$GL GAS_M=$GM AB_IMAGE=rskj-local:tip
        SEED="$ROOT/bench/live-mining/seed/seed-loaded-1159-${GM}M.tar.gz"
        [ "$GM" = "25" ] && SEED="$ROOT/bench/live-mining/seed/seed-loaded-1159.tar.gz"
        docker compose -f "$ROOT/docker-compose.local-ab.yml" down -v >/dev/null 2>&1
        docker volume create rsk-simulation_rskj-data-ab >/dev/null
        U=$(docker run --rm --entrypoint sh rskj-local:tip -c 'id -u rsk'); G=$(docker run --rm --entrypoint sh rskj-local:tip -c 'id -g rsk')
        docker run --rm -v rsk-simulation_rskj-data-ab:/to -v "$SEED":/seed.tar.gz:ro alpine \
          sh -c "rm -rf /to/* /to/..?* /to/.[!.]* 2>/dev/null; tar xzf /seed.tar.gz -C /to && chown -R ${U}:${G} /to" >/dev/null
        docker compose -f "$ROOT/docker-compose.local-ab.yml" up -d >/dev/null
        sleep 45
        ACTUAL=$(curl -s -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' http://localhost:4444 | /usr/bin/python3 -c 'import json,sys;print(int(json.load(sys.stdin)["result"]["gasLimit"],16))' 2>/dev/null)
      else
        GAS_LIMIT=$GL "$ROOT/scripts/boton/deploy-node.sh" "$HOST" "$MINER" "$JAR" >/dev/null 2>&1
        sleep 25
        ACTUAL=$(ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" \
          'curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",false],\"id\":1}" http://127.0.0.1:4444 | python3 -c "import json,sys;print(int(json.load(sys.stdin)[\"result\"][\"gasLimit\"],16))"' 2>/dev/null)
      fi
      # A silently-wrong limit yields a believable curve that measures nothing. Skip the
      # cell rather than record it.
      if [ "${ACTUAL:-0}" != "$GL" ]; then
        echo "  on-chain gasLimit=${ACTUAL:-none}, expected $GL -- SKIPPING cell"
        echo "$HOST,$OPT,$GL,$C,$BUILD,,,,,,,,,,,,GASLIMIT-MISMATCH" >> "$OUT"; continue
      fi

      if [ "$HOST" = "local" ]; then
        pkill -f "k6 run" 2>/dev/null
        ( cd "$ROOT/repos/rskj-k6-tests" && nohup ./infinite.sh "$OPT" > "/tmp/sweep-$OPT-$GM-$C.log" 2>&1 < /dev/null & )
      else
        "$ROOT/scripts/boton/run-load.sh" "$HOST" "$OPT" "DURATION=${DUR_MIN}m" >/dev/null 2>&1
      fi
      sleep $(( DUR_MIN * 60 ))

      if [ "$HOST" = "local" ]; then
        pkill -f "k6 run" 2>/dev/null
        ROW=$(docker exec rskj-ab sh -c 'cat /var/lib/rsk/test/local-regtest/block-breakdown.log 2>/dev/null' 2>/dev/null | /usr/bin/python3 -c "$STATS_PY" "$GL")
      else
        ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" 'pkill -f "[k]6 run" 2>/dev/null' 2>/dev/null
        ROW=$(ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" \
          'sudo cat /var/log/rsk/stress/block-breakdown.log 2>/dev/null || sudo grep -h "breakdown" /var/log/rsk/stress/*.log 2>/dev/null' 2>/dev/null | /usr/bin/python3 -c "$STATS_PY" "$GL")
      fi
      MU=$(echo "$ROW" | cut -d, -f1)
      V=$(/usr/bin/python3 -c "
mu='${MU:-0}' or '0'
print('OK' if float(mu)>=0.90 else ('MARGINAL' if float(mu)>=0.80 else 'EXCLUDE-UNDERFILL'))" 2>/dev/null || echo UNKNOWN)
      echo "$HOST,$OPT,$GL,$C,$BUILD,$ROW,$V" >> "$OUT"
      echo "  -> util=$MU verdict=$V"
    done
  done
done
echo "### sweep share complete on $HOST -> $OUT"
