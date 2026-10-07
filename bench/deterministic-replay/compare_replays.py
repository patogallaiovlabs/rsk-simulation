#!/usr/bin/env python3
"""Paired comparison of deterministic replay runs.

    python3 bench/deterministic-replay/compare_replays.py <baseline-glob> <tip-glob>
    python3 .../compare_replays.py 'results/cb-baseline*_block-breakdown.log' 'results/cb-tip*_block-breakdown.log'

Why paired: replay feeds BOTH builds the identical block sequence, so block N is
directly comparable across arms. Comparing per-block deltas removes block-to-block
variance (some blocks are simply heavier) and leaves the build effect plus run noise.
Comparing two distributions, as the standard analyzer does, throws that pairing away.

Why multiple runs: with the same build, two replay runs drifted -9% and +10% on
totalMs p50 -- a noise floor larger than the effect being measured. Each arm is
therefore reduced to a per-block MEDIAN ACROSS RUNS first, then paired.

Reports the median per-block delta with an interquartile range, and the share of blocks
that improved. An effect whose IQR spans zero is not resolved by this data.
"""
import gzip, re, sys, glob, statistics, math
from collections import defaultdict

# Two record types carry different metrics, both keyed by block number:
#   connect  -> totalMs, executeMs, saveReceiptsMs, onBestBlockMs ...
#   execute  -> txExecutionMs, statePersistMs
# Parse both and merge per block, or half the metrics silently go missing.
MARK = re.compile(r"block (?:connect|execute) breakdown ")
KV = re.compile(r"(\w+)=(\S+)")
METRICS = ("totalMs", "executeMs", "txExecutionMs", "statePersistMs", "saveReceiptsMs")
GAS_LIMIT, THRESH = 25_000_000, 0.9

def load(path):
    """block number -> {metric: value} for qualifying (>=90% full) blocks."""
    out = {}
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt", errors="replace") as fh:
        for line in fh:
            if not MARK.search(line):
                continue
            kv = dict(KV.findall(line))
            try:
                if int(kv.get("gasUsed", 0)) / GAS_LIMIT < THRESH:
                    continue
                blk = int(kv["block"])
                out.setdefault(blk, {}).update({m: float(kv[m]) for m in METRICS if m in kv})
            except (ValueError, KeyError, ZeroDivisionError):
                continue
    return out

def median_across_runs(paths):
    per_block = defaultdict(lambda: defaultdict(list))
    for p in paths:
        for blk, vals in load(p).items():
            for m, v in vals.items():
                per_block[blk][m].append(v)
    return {blk: {m: statistics.median(vs) for m, vs in ms.items()} for blk, ms in per_block.items()}

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    base_paths = sorted(glob.glob(sys.argv[1]))
    tip_paths = sorted(glob.glob(sys.argv[2]))
    if not base_paths or not tip_paths:
        sys.exit(f"no files matched (baseline={len(base_paths)}, tip={len(tip_paths)})")
    print(f"baseline runs: {len(base_paths)}   tip runs: {len(tip_paths)}")
    b, t = median_across_runs(base_paths), median_across_runs(tip_paths)
    common = sorted(set(b) & set(t))
    print(f"blocks present in both, qualifying: {len(common)}\n")
    print(f"{'metric':<18}{'baseline':>10}{'tip':>10}{'delta':>10}{'median Δ%':>22}{'IQR':>14}{'improved':>17}{'sign test':>22}")
    for m in METRICS:
        pairs = [(b[k][m], t[k][m]) for k in common if m in b[k] and m in t[k]]
        if not pairs:
            continue
        bm = statistics.median([p[0] for p in pairs])
        tm = statistics.median([p[1] for p in pairs])
        deltas = [100.0 * (y - x) / x for x, y in pairs if x > 0]
        if not deltas:
            continue
        deltas.sort()
        q1 = deltas[len(deltas)//4]; q3 = deltas[(3*len(deltas))//4]
        better = sum(1 for x, y in pairs if y < x)
        # Sign test on the paired blocks: under "no effect" the share improving is 50%.
        # This, not the IQR, is the decision statistic -- the IQR describes how much
        # blocks differ from each other, which stays wide even for a real effect.
        n_dec = sum(1 for x, y in pairs if y != x)
        z = (abs(better - n_dec / 2) - 0.5) / math.sqrt(n_dec / 4) if n_dec else 0.0
        verdict = "RESOLVED" if z >= 3 else ("weak" if z >= 2 else "not resolved")
        print(f"{m:<18}{bm:>10.1f}{tm:>10.1f}{tm-bm:>+10.1f}"
              f"{statistics.median(deltas):>21.1f}%"
              f"{('[%+.0f,%+.0f]' % (q1, q3)):>14}"
              f"{('%d/%d (%.0f%%)' % (better, n_dec, 100.0*better/n_dec if n_dec else 0)):>17}"
              f"{('z=%.1f %s' % (z, verdict)):>22}")

if __name__ == "__main__":
    main()
