#!/usr/bin/env bash
# Derive a Boton node config from rsk/rsk.conf, so the remote node runs the same
# consensus rules and caches as the local docker miners (rskip144=-1, rskip97=0,
# cache sizes). Only the things that must differ on a cloud box are rewritten.
#
#   scripts/boton/make-node-conf.sh <out.conf> [peer-enode-url]
#
# With no peer URL the node runs isolated: peer.active=[] and discovery off, which
# is what separate per-box experiments want. With a URL it dials that one peer
# (needs the provider firewall opened -- see docs/boton-deployment.md).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?usage: make-node-conf.sh <out.conf> [peer-enode-url]}"
PEER="${2:-}"
GAS_LIMIT="${3:-25000000}"
/usr/bin/python3 - "$ROOT/rsk/rsk.conf" "$OUT" "$PEER" "$GAS_LIMIT" <<'PY'
import re,sys
src,out,peer=sys.argv[1],sys.argv[2],sys.argv[3]
# argv[3] is the PEER url -- the gas limit is argv[4]. Getting this wrong
# silently blanks both gas settings instead of failing.
gl=sys.argv[4]
t=open(src).read()
if peer:
    t=re.sub(r"active = \[\{.*?\}\]", 'active = [{\n        url = "%s"\n    }]'%peer, t, flags=re.S)
else:
    t=re.sub(r"active = \[\{.*?\}\]", "active = []", t, flags=re.S)
    t=t.replace("discovery {\n        enabled = true\n    }",
                "discovery {\n        enabled = false\n    }")
t=t.replace('dir = "./test/local-regtest/database"','dir = "/var/lib/rsk/database"')
t=re.sub(r'hosts = \[[^\]]*\]','hosts = ["*"]',t)          # docker hostnames are meaningless here
# gas limit is passed in so stress.conf cannot drift from the -D flags
t=t.replace("gasEstimationCap = 17000000", f"gasEstimationCap = {gl}")
t=t.replace("targetgaslimit = 17000000", f"targetgaslimit = {gl}")
open(out,"w").write(t)
print(f"wrote {out} (peer={'1' if peer else 'isolated'})")
PY
