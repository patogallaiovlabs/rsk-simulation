#!/usr/bin/env bash
# Stop a labelled experiment, analyse it on the boxes, and pull the results.
#
#   scripts/boton/collect-experiment.sh <label> [threshold] [min-block]
#   scripts/boton/collect-experiment.sh keccak 0.85 20
#
# threshold defaults to 0.9. Use a lower one when a "full" block for the scenario sits
# below that -- keccak-random-writes tops out at 89.2%, because it puts one tx using
# 95% of the block gas limit into each block, so 0.9 matches nothing at all.
#
# Analysis always runs in a FRESH directory on the box: globbing a shared /tmp once
# swept in the previous run's rotated logs and silently reported that run's numbers.
#
# bash 3.2 compatible (macOS) -- no associative arrays.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="${1:?usage: collect-experiment.sh <label> [threshold] [min-block]}"
THRESH="${2:-0.9}"; MINBLOCK="${3:-20}"
OUT="$ROOT/results/boton/$LABEL"; mkdir -p "$OUT"
KEY="${BOTON_KEY:-$HOME/.ssh/rskj-automation}"
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25"
[ -f "$ROOT/docs/boton/hosts.env" ] && . "$ROOT/docs/boton/hosts.env"
HOST_A="${BOTON_HOST_A:-5.161.112.81}"
HOST_B="${BOTON_HOST_B:-91.107.194.5}"
NODES="baseline:$HOST_A tip:$HOST_B"
TIP_HOST="$HOST_B"
f() { echo "$1" | cut -d: -f"$2"; }

echo "### collecting '$LABEL' (threshold=$THRESH min-block=$MINBLOCK)"
for N in $NODES; do
  ROLE=$(f "$N" 1); H=$(f "$N" 2)
  # Ship the analyzer every time. It used to be assumed present on the box: a newly
  # provisioned instance did not have it, python3 failed with "No such file or
  # directory", the surrounding || true swallowed it, and six collected cycles
  # produced .txt files with no .json -- silently unusable.
  scp -q $SSH_OPTS "$ROOT/nmt/analyze_block_breakdown.py" "ubuntu@$H:/tmp/analyze_block_breakdown.py" 2>/dev/null \
    || { echo "  [$ROLE] FAILED to ship analyze_block_breakdown.py to $H" >&2; }
  ssh $SSH_OPTS "ubuntu@$H" "
    pkill -f '[i]nfinite.sh' 2>/dev/null || true; sleep 1
    pkill -f '[k]6 run' 2>/dev/null || true
    pkill -f 'sample[-]resources' 2>/dev/null || true
    rm -rf /tmp/an_$LABEL && mkdir -p /tmp/an_$LABEL
    sudo cp /var/log/rsk/stress/block-breakdown.log /tmp/an_$LABEL/ 2>/dev/null || true
    sudo cp /var/log/rsk/stress/block-breakdown-*.log.gz /tmp/an_$LABEL/ 2>/dev/null || true
    sudo chown ubuntu:ubuntu /tmp/an_$LABEL/* 2>/dev/null || true
    python3 /tmp/analyze_block_breakdown.py --label $ROLE --threshold $THRESH --min-block $MINBLOCK \
      --save-json /tmp/${LABEL}_${ROLE}.json /tmp/an_$LABEL/* > /tmp/${LABEL}_${ROLE}.txt 2>&1 || true
    head -2 /tmp/${LABEL}_${ROLE}.txt" | sed "s/^/  [$ROLE] /"
  scp -q $SSH_OPTS "ubuntu@$H:/tmp/${LABEL}_${ROLE}.json" "$OUT/" 2>/dev/null || true
  scp -q $SSH_OPTS "ubuntu@$H:/tmp/${LABEL}_${ROLE}.txt"  "$OUT/" 2>/dev/null || true
  scp -q $SSH_OPTS "ubuntu@$H:/home/ubuntu/results/resources.csv" "$OUT/${ROLE}_resources.csv" 2>/dev/null || true
  # k6's own metrics matter for read-path scenarios (option 16): those timings are
  # client-side and never reach block-breakdown.log, which only covers block connect.
  K6LOG=$(ssh $SSH_OPTS "ubuntu@$H" 'ls -t ~/results/k6_opt*.log 2>/dev/null | head -1' || true)
  [ -n "$K6LOG" ] && scp -q $SSH_OPTS "ubuntu@$H:$K6LOG" "$OUT/${ROLE}_k6.log" 2>/dev/null || true
done

if [ -f "$OUT/${LABEL}_baseline.json" ]; then
  scp -q $SSH_OPTS "$OUT/${LABEL}_baseline.json" "ubuntu@$TIP_HOST:/tmp/base_cmp.json"
  ssh $SSH_OPTS "ubuntu@$TIP_HOST" "
    python3 /tmp/analyze_block_breakdown.py --label tip --threshold $THRESH --min-block $MINBLOCK \
      --baseline /tmp/base_cmp.json /tmp/an_$LABEL/*" > "$OUT/comparison.txt" 2>&1 || true
  sed -n '/=== base/,$p' "$OUT/comparison.txt" | head -24
fi

python3 - "$OUT" <<'PYEOF'
import csv,sys,os,re
out=sys.argv[1]
print("\n### resources")
for role in ("baseline","tip"):
    p=os.path.join(out,f"{role}_resources.csv")
    if not os.path.exists(p): continue
    rows=list(csv.DictReader(open(p)))
    if not rows: continue
    def n(k): return [float(r[k]) for r in rows if r.get(k) not in (None,"","-1")] or [0]
    cpu,rss,db,rd,wr=n("cpu_pct"),n("rss_mb"),n("db_mb"),n("read_mb"),n("write_mb")
    print(f"  {role:8s} cpu_mean={sum(cpu)/len(cpu):5.1f}%  rss_mean={sum(rss)/len(rss):5.0f}MB  "
          f"db+{db[-1]-db[0]:6.0f}MB  read+{rd[-1]-rd[0]:7.0f}MB  write+{wr[-1]-wr[0]:7.0f}MB  (n={len(rows)})")
printed=False
for role in ("baseline","tip"):
    p=os.path.join(out,f"{role}_k6.log")
    if not os.path.exists(p): continue
    blocks=open(p,errors="replace").read().split("TOTAL RESULTS")[1:]
    if not blocks: continue
    # infinite.sh restarts the scenario, so the LAST summary is usually a run that was
    # just interrupted by collection and reports "0 out of 0". Pick the block with the
    # most samples instead of the most recent one.
    def weight(b):
        m=re.search(r"out of (\d+)", b)
        if m: return int(m.group(1))
        m=re.search(r"http_reqs[.]*:\s*(\d+)", b)
        return int(m.group(1)) if m else 0
    best=max(blocks, key=weight)
    if weight(best)==0: continue
    rows=[l.strip() for l in best.splitlines()
          if re.match(r"\s+(idx_|http_req_duration|http_req_failed|iterations)", l)]
    if not rows: continue
    if not printed:
        print(f"\n### k6 client-side metrics (richest of {len(blocks)} summaries)"); printed=True
    print(f"  --- {role} ---")
    for r in rows[:14]: print("   "+r)
PYEOF
echo "### -> $OUT"
