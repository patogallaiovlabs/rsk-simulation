#!/usr/bin/env bash
# Verify a scenario actually SATURATES blocks at a given gas limit, before spending
# cycles measuring it.
#
#   scripts/saturation-check.sh <host|local> <gas-limit> <minutes> <opt> [opt...]
#
# The sweep's central trap: a k6 option tuned to fill a 25M block fills a quarter of
# it at 7M -- or overflows at 7M what it merely filled at 25M. Either way the number
# measures the load generator, not the node, and produces a believable flat curve.
# The spec requires mean utilization >= 0.90 per cell, recorded next to the timings;
# a cell that cannot reach it is excluded rather than plotted.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?usage: saturation-check.sh <host|local> <gas-limit> <minutes> <opt>...}"
GAS_LIMIT="${2:?}"; MINS="${3:?}"; shift 3; OPTS=("$@")
GAS_M=$((GAS_LIMIT / 1000000))
OUT="$ROOT/results/sweep/saturation-${GAS_M}M.csv"
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo "host,gas_limit,option,mean_util,blocks_ge_90pct,blocks_total,verdict" > "$OUT"
KEY="$HOME/.ssh/rskj-automation"

rpc_util() {   # prints "mean_util n_ge90 n_total" over the last N blocks
  local n=$1 script
  script=$(cat <<PY
import json,urllib.request
def rpc(m,p=[]):
    r=urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:4444",data=json.dumps({"jsonrpc":"2.0","method":m,"params":p,"id":1}).encode(),headers={"Content-Type":"application/json"}),timeout=20)
    return json.load(r).get("result")
t=int(rpc("eth_blockNumber"),16); u=[]
for k in range(max(1,t-$n),t+1):
    b=rpc("eth_getBlockByNumber",[hex(k),False])
    gl=int(b["gasLimit"],16)
    if gl: u.append(int(b["gasUsed"],16)/gl)
print(round(sum(u)/len(u),4) if u else 0, sum(1 for x in u if x>=0.9), len(u))
PY
)
  if [ "$HOST" = "local" ]; then /usr/bin/python3 -c "${script//127.0.0.1/localhost}" 2>/dev/null
  else ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" "python3 - <<'PYEOF'
$script
PYEOF" 2>/dev/null; fi
}

echo "### saturation @ ${GAS_M}M on $HOST -- options: ${OPTS[*]}"
for OPT in "${OPTS[@]}"; do
  echo "--- option $OPT ---"
  if [ "$HOST" = "local" ]; then
    pkill -f "k6 run" 2>/dev/null; sleep 2
    ( cd "$ROOT/repos/rskj-k6-tests" && nohup ./infinite.sh "$OPT" > "/tmp/sat-${GAS_M}M-$OPT.log" 2>&1 < /dev/null & )
  else
    ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" 'pkill -f "[k]6 run" 2>/dev/null' 2>/dev/null
    sleep 2
    "$ROOT/scripts/boton/run-load.sh" "$HOST" "$OPT" "DURATION=${MINS}m" >/dev/null 2>&1
  fi
  # let setup finish and the mempool reach steady state before sampling
  sleep $(( MINS * 60 * 2 / 3 ))
  read -r MU NGE NTOT <<< "$(rpc_util 40)"
  MU="${MU:-0}"; NGE="${NGE:-0}"; NTOT="${NTOT:-0}"
  V=$(/usr/bin/python3 -c "print('SATURATES' if float('${MU:-0}')>=0.90 else ('MARGINAL' if float('${MU:-0}')>=0.80 else 'UNDER-FILLS'))")
  echo "  mean_util=$MU  >=90%: $NGE/$NTOT  -> $V"
  echo "$HOST,$GAS_LIMIT,$OPT,$MU,$NGE,$NTOT,$V" >> "$OUT"
done
if [ "$HOST" = "local" ]; then pkill -f "k6 run" 2>/dev/null
else ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25 ubuntu@"$HOST" 'pkill -f "[k]6 run" 2>/dev/null' 2>/dev/null; fi
echo "### recorded -> $OUT"
