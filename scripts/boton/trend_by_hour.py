#!/usr/bin/env python3
"""Bin block-breakdown metrics by hour, to see how a metric moves as the database grows.

The plain analyzer aggregates a whole run into one number, which hides the effect that
matters most in this series: several optimizations only pay off once the database is
large. Run 1 (65h) showed saveReceiptsMs 141.9ms on the baseline; run 7 (1h) showed
1.0ms on the same build. Binning by hour shows where the curve turns.

    python3 scripts/boton/trend_by_hour.py <label> results/boton/<label>/*.log*

Pairs with the resource CSV's db_mb column to read metric-vs-database-size.
"""
import gzip, re, sys, statistics
from collections import defaultdict

# Two DIFFERENT record types, deliberately kept apart:
#   connect = one per block actually connected  (~200/hour) -- carries saveReceiptsMs,
#             onBestBlockMs, and the totalMs that "block connect time" refers to.
#   execute = one per block execution INCLUDING candidate rebuilds (~18k/hour under a
#             deep mempool) -- carries txExecutionMs and statePersistMs.
# Averaging them together would drown the few real blocks in candidate-build noise.
CONNECT = re.compile(r"block connect breakdown [^:]*:")
EXEC = re.compile(r"block execute breakdown [^:]*:")
KV = re.compile(r"(\w+)=(\S+)")
TS = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d{2}):")
CONNECT_METRICS = ("totalMs", "saveReceiptsMs", "onBestBlockMs", "executeMs")
EXEC_METRICS = ("totalMs", "txExecutionMs", "statePersistMs")

def rows(paths):
    for p in paths:
        op = gzip.open if p.endswith(".gz") else open
        try:
            with op(p, "rt", errors="replace") as fh:
                for line in fh:
                    kind = ("connect" if CONNECT.search(line)
                            else "execute" if EXEC.search(line) else None)
                    if kind is None:
                        continue
                    m = TS.match(line)
                    if not m:
                        continue
                    yield kind, f"{m.group(1)} {m.group(2)}:00", dict(KV.findall(line))
        except OSError:
            continue

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    label, paths = sys.argv[1], sys.argv[2:]
    buckets = {"connect": defaultdict(lambda: defaultdict(list)),
               "execute": defaultdict(lambda: defaultdict(list))}
    wanted = {"connect": CONNECT_METRICS, "execute": EXEC_METRICS}
    for kind, hour, kv in rows(paths):
        for k in wanted[kind]:
            v = kv.get(k)
            if v is None:
                continue
            try:
                buckets[kind][hour][k].append(float(v))
            except ValueError:
                pass
    if not any(buckets[k] for k in buckets):
        sys.exit(f"{label}: no breakdown records found in {len(paths)} file(s)")
    for kind in ("connect", "execute"):
        b_all = buckets[kind]
        if not b_all:
            continue
        cols = wanted[kind]
        note = ("real blocks" if kind == "connect" else "incl. candidate rebuilds")
        print(f"\n=== {label} / {kind} records ({note}): per-hour medians ===")
        print(f"{'hour':<17}{'n':>8}" + "".join(f"{m:>16}" for m in cols))
        for hour in sorted(b_all):
            b = b_all[hour]
            n = max((len(v) for v in b.values()), default=0)
            cells = "".join(f"{statistics.median(b[m]):>16.1f}" if b.get(m) else f"{'-':>16}"
                            for m in cols)
            print(f"{hour:<17}{n:>8}{cells}")

if __name__ == "__main__":
    main()
