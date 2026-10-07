#!/usr/bin/env bash
# Ship the k6 suite to a Boton box and start it against the local node.
#
#   scripts/boton/run-load.sh <host> [test-option] [env assignments]
#   scripts/boton/run-load.sh 5.161.112.81 2 "RATE=25 DURATION=1h PRE_VUS=30"
#
# The 3rd argument is exported before infinite.sh runs, so scenario-level knobs
# (RATE/DURATION/PRE_VUS, etc.) reach k6 -- `k6 run` picks up system env vars.
#
# k6 runs ON the box against 127.0.0.1:4444 on purpose: no inbound firewall rule
# is needed, and there is no WAN latency between the load generator and the node
# (from a laptop that is ~175ms, which caps per-VU throughput and would make the
# numbers incomparable to a local docker run).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${1:?usage: run-load.sh <host> [test-option] [env]}"; OPT="${2:-14}"; K6ENV="${3:-}"
KEY="${BOTON_KEY:-$HOME/.ssh/rskj-automation}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=25)
STAMP=$(date -u +%Y%m%d_%H%M%S)

TGZ=$(mktemp -d)/k6.tgz
tar czf "$TGZ" -C "$ROOT/repos" \
    --exclude=node_modules --exclude=.git --exclude=results --exclude=reports rskj-k6-tests
scp -q "${SSH_OPTS[@]}" "$TGZ" "ubuntu@$HOST:/tmp/k6-tests.tgz"

ssh "${SSH_OPTS[@]}" "ubuntu@$HOST" "
  set -e
  rm -rf ~/rskj-k6-tests && tar xzf /tmp/k6-tests.tgz -C ~ 2>/dev/null
  cd ~/rskj-k6-tests && npm install --silent --no-audit --no-fund >/dev/null 2>&1
  mkdir -p ~/results
  echo \"resolver -> \$(node scripts/resolve-rpc-urls.js --quiet)\"
  setsid nohup env $K6ENV ./infinite.sh $OPT > ~/results/k6_opt${OPT}_$STAMP.log 2>&1 < /dev/null &
  sleep 3
  pgrep -f infinite.sh >/dev/null && echo 'load STARTED ($STAMP)' || { echo 'load FAILED'; exit 1; }
"
echo "log on box: ~/results/k6_opt${OPT}_$STAMP.log"
