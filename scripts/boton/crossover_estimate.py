#!/usr/bin/env python3
"""Estimate the build effect from a counterbalanced pair of runs, cancelling the box term.

    python3 scripts/boton/crossover_estimate.py <forward_dir> <reversed_dir> [aa_dir]

  forward slot : box A = baseline, box B = tip
  reversed slot: box A = tip,      box B = baseline

Each box thus runs both builds, on its own hardware, in opposite order. That gives two
independent serial A/B estimates; averaging them cancels the *time* term as well, since
it enters the two with opposite sign.

Why this exists: a single-direction A/B across two boxes cannot separate a build effect
from a box effect. An A/A control here measured the boxes differing by +95.7% on
txExecutionMs with identical jars, which invalidated several earlier conclusions.

NAMING TRAP: collect-experiment.sh names its output files by BOX ROLE, not by build --
`<label>_baseline.json` is always box A and `<label>_tip.json` is always box B. So in
the REVERSED directory, the file called `_baseline.json` contains the TIP's numbers.
This script accounts for that; do not compare those files by filename.
"""
import json, sys, glob, os

# preambleMs is emitted only by builds carrying b4a13038d. A build without it simply
# reports no value, which is the point: comparing it at all requires the probe to exist
# on both sides of the crossover.
METRICS = ("totalMs", "preambleMs", "executeMs", "txExecutionMs", "statePersistMs", "saveReceiptsMs")

def load(d, role):
    hits = [p for p in glob.glob(os.path.join(d, f"*_{role}.json"))]
    if not hits:
        sys.exit(f"no *_{role}.json in {d}")
    return json.load(open(hits[0]))

def stat(js, metric, key):
    e = js.get("per_block", {}).get(metric)
    return e.get(key) if e else None

def pct(new, old):
    if old in (None, 0) or new is None:
        return None
    return 100.0 * (new - old) / old

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    fwd, rev = sys.argv[1], sys.argv[2]
    aa = sys.argv[3] if len(sys.argv) > 3 else None

    A_base = load(fwd, "baseline")   # box A, baseline build
    B_tip  = load(fwd, "tip")        # box B, tip build
    A_tip  = load(rev, "baseline")   # box A, TIP build   (see NAMING TRAP)
    B_base = load(rev, "tip")        # box B, BASELINE build

    print(f"qualifying blocks — fwd: A={A_base['qualifying_blocks']} B={B_tip['qualifying_blocks']}"
          f" | rev: A={A_tip['qualifying_blocks']} B={B_base['qualifying_blocks']}")
    if aa:
        aaA, aaB = load(aa, "baseline"), load(aa, "tip")

    for key in ("p50", "p95"):
        print(f"\n=== {key}: build effect (tip vs baseline), box term cancelled ===")
        hdr = f"{'metric':<18}{'boxA serial':>13}{'boxB serial':>13}{'COMBINED':>12}"
        if aa: hdr += f"{'A/A box term':>14}"
        print(hdr)
        for m in METRICS:
            a = pct(stat(A_tip, m, key), stat(A_base, m, key))
            b = pct(stat(B_tip, m, key), stat(B_base, m, key))
            vals = [v for v in (a, b) if v is not None]
            comb = sum(vals) / len(vals) if vals else None
            row = (f"{m:<18}"
                   f"{('%+.1f%%' % a) if a is not None else '-':>13}"
                   f"{('%+.1f%%' % b) if b is not None else '-':>13}"
                   f"{('%+.1f%%' % comb) if comb is not None else '-':>12}")
            if aa:
                t = pct(stat(aaB, m, key), stat(aaA, m, key))
                row += f"{('%+.1f%%' % t) if t is not None else '-':>14}"
            print(row)
        if a is not None and b is not None:
            spread = abs(a - b)
            print(f"\n  boxA vs boxB disagreement on {METRICS[2]} {key}: "
                  f"{abs(pct(stat(A_tip,METRICS[2],key), stat(A_base,METRICS[2],key)) - pct(stat(B_tip,METRICS[2],key), stat(B_base,METRICS[2],key))):.1f} points"
                  " (large disagreement = a term neither box nor time explains)")

if __name__ == "__main__":
    main()
