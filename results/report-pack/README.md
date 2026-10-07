# Report pack — baseline `47a2eb63a` vs tip `392ae5506`

Machine-readable evidence from every A/B run in this project. Regenerate any time:

    python3 scripts/build_report_pack.py

Re-run it after the in-flight rotation finishes (see "Still running" below) — the pack
is a snapshot, not a log.

## Files

| file | one row per | use it for |
|---|---|---|
| `runs.csv` | ARM (one build, one 30-min run) | raw absolutes, block counts, utilization |

Per metric, `runs.csv` carries `<metric>_mean`, `_p50` and `_p95`. `_mean` comes from the
collector on the boton track and is computed from the per-block log on the local track.
`_p95` is boton-only: the local track's raw values are available but a p95 computed here
would use a different definition than the collector's, and two statistics under one column
name invite false cross-track comparisons.
| `cycle_deltas.csv` | scenario x metric x cycle | per-cycle deltas, spotting outliers |
| `pooled.csv` / `pooled.json` | scenario x metric | **the reportable claims, with p-values** |
| `excluded.csv` | every deliberate exclusion | what was left out and why |
| `sweep_runs.csv` | gas-limit sweep RUN | raw sweep runs, one build, gas limit varied |
| `sweep_curves.csv` | scenario x gas limit | **the curve points, linearity, Gate B** |

**`runs.csv` is unfiltered — filter `threshold == 0.9` before aggregating it.** It
deliberately contains every arm, including ones `excluded.csv` records as unusable, so the
exclusions stay auditable. A naive median over all boton indexer tip arms gives **91 ms**
`totalMs_mean`; over the threshold-matched ones it is **62 ms**. `pooled.csv` and
`cycle_deltas.csv` are already filtered — this warning applies only to `runs.csv`.

Quick queries:

    # threshold-matched arms only (see the warning above)
    awk -F, 'NR==1 || $8=="0.9"' results/report-pack/runs.csv

    # every claim that is actually significant
    awk -F, '$9=="True"' results/report-pack/pooled.csv

    # one scenario across both tracks
    grep -E "^(boton|local),calldata," results/report-pack/pooled.csv

    # per-cycle spread behind a claim
    grep "calldata,txExecutionMs" results/report-pack/cycle_deltas.csv

    # gas-limit curves, and which ones are actually claimable
    column -s, -t results/report-pack/sweep_curves.csv

## Method, in one paragraph

Two independent tracks. **Boton**: two cloud boxes, each scenario run in both directions
(box A baseline / box B tip, then swapped) so the box term cancels — mandatory, because
boxes in different regions measured the *same jar* 2x apart. **Local**: one machine,
arms back to back, so there is no box term at all. The unit of replication is the
**cycle**, not the block: blocks within an arm share a JVM, page cache and a growing
database, so pooling thousands of them manufactures a tiny, false confidence interval.
Each cycle yields one delta; the test is an exact two-sided sign test over cycles.

**A unanimous sign test cannot reach p<0.05 below 6 cycles** (2/2^6 = 0.031). The
`claimable` column says which of `significant` / `direction only` / `single cycle`
applies. Do not upgrade a "direction only" row into a finding.

## What the data supports

1. **Receipt persistence is the dominant win, and it is I/O-bound.** `saveReceiptsMs`
   collapses to ~0 on every Boton workload measured. It is absent locally because the
   local baseline is already 0.0ms on NVMe — nothing to remove. This single term
   explains why Boton `totalMs` moves 29-49% while local `totalMs` barely moves.
2. **Transaction execution improves by a workload-dependent amount.** calldata -38%
   (Boton) / -43% (local), blockfiller -15% / -21%, indexer -4.7% (Boton), mainnet and
   ecdsa flat, storagereads **exactly 0.0% on both tracks**. A general "execution is
   faster" claim is NOT supported.
3. **storagereads is the cleanest separation of the two mechanisms.** A read-heavy
   workload shows `txExecutionMs` flat at 0.0% on BOTH tracks, yet `totalMs` still
   falls (-58% Boton median, -20% local, the latter significant) purely via
   `saveReceiptsMs` -> 0. It receives the write-path win and nothing else, which is
   what makes it a control rather than just another data point.
4. **Receipt cost scales with receipt COUNT, not just presence.** blockfiller is the
   only workload where saveReceiptsMs does not collapse to ~0: -69% (Boton) / -82%
   (local), both significant. It packs ~1,191 tiny transactions per block — so ~1,191
   receipts — against one per block for storagereads. The residual cost tracks the
   number of receipts.

## Do not write these

- **Do not report a single number for indexer `txExecutionMs`.** Boton says -4.7%
  (7/7) and local says -33.3% (7/7). Both unanimous, both significant, an order of
  magnitude apart. Unexplained.
- **Do not quote `local ecdsa txExecutionMs` (+0.77%, 0/6, p=0.0312) as a regression.**
  Absolutes are 226 -> 228ms, with per-cycle deltas of +0.44% to +1.78%. Consistent
  enough to pass a sign test, far too small to mean anything. Same trap as below.
- **Do not quote `executeMs` as a regression — especially local storagereads.** That
  row is `+25.0%`, 0/7 cycles, p=0.0156: statistically significant and practically
  meaningless. The absolutes are baseline **4.0ms -> tip 5.0ms**, identical in all
  seven cycles. That is ONE integer step on millisecond-quantized log values; the
  "+25%" is an artifact of expressing a 1ms step as a percentage of a 4ms base. The
  direction may well be real, the magnitude is not measurable at this resolution.
  A perfect sign test proves CONSISTENCY, never IMPORTANCE -- always read
  `runs.csv` absolutes before quoting a percentage.
- **Do not call boton storagereads totalMs (-58.2%) significant.** It is 6/7,
  p=0.125 — one cycle dissents. A large median with a dissenting cycle is still
  "direction only".
- **Do not pool Boton indexer cycles 1-3.** Collected at a 0.3 utilization threshold:
  44-50% mean utilization over ~26 blocks, versus 91.5% over 88 at 0.9. Pooled naively
  they produce a phantom **+98% txExecutionMs regression** that is -3% to -6% against a
  matched population. They keep aggregates only and cannot be re-filtered. Excluded
  permanently; `paired_stats.py` now refuses to pool mismatched thresholds.
- **Do not read a per-slot `comparison.txt` in a `-rev` directory at face value.**
  Those files are named by BOX ROLE, not build. In the reversed slot box A ran tip, so
  the column labelled `base_cmp` IS tip. Read naively the rev slot shows tip 57%
  *slower* — the opposite of the truth. `runs.csv` has this already decoded in its
  `build` column; trust that, or `crossover_estimate.py`.
- **Do not treat local `totalMs` as a null result.** It is inconclusive, which is not
  the same thing: the effect that drives it is physically absent locally.

## Noise floor

Same-build runs varied ~8% between co-located Boton boxes and 10-14% locally. Any
single-run difference below that is noise. This is why cycles, not blocks, are counted.

## Scenario coverage

Run: mainnet (opt 14), ecdsa (7), indexer (16), calldata (11), keccak (2),
storagereads (6), blockfiller (15). The storagereads/blockfiller rotation completed
2026-09-26 with 7 cycles each (blockfiller Boton: 6).
Never run: options 1, 3, 4, 5, 8, 9, 10, 12, 13.

Three scenarios (calldata settlement, calldata random, storage reads) were found to
declare a tx gas limit unrelated to actual cost, which caps block inclusion and
silently prevents saturation. Any scenario in the "never run" list should be smoke
tested for this before its numbers are trusted.

## Keeping this pack current

Scenario names are discovered from the results directories, so new rotations need no
code change — just re-run the generator:

    python3 scripts/build_report_pack.py

Every file is overwritten, `pooled.json` carries a `generated_utc` stamp, and cycle
counts and p-values move as cycles accumulate. A claim that reads "direction only"
today can become "significant" once it reaches 6 unanimous cycles, so regenerate before
quoting anything, and cite the stamp alongside the numbers.


# ==========================================================================
# Gas-limit sweep (added 2026-09-30)
# ==========================================================================

A SEPARATE experiment from everything above. The A/B tracks hold the gas limit at 25M
and vary the BUILD; the sweep holds the build at tip `392ae5506` and varies the GAS
LIMIT. There is no baseline-vs-tip delta in `sweep_*.csv` — do not read one into it.

102 runs, 6 cycles per cell, 30 min each, cold deploy per run from the seed matching
that gas limit (a 25M-mined chain restored under a 7M node is a different chain and
measures neither).

## What the sweep supports

**Block processing time grows SUPER-LINEARLY with the gas limit.** Gas rises 3.57x
from 7M to 25M; time rises 4.3-5.7x:

| scenario | gas x | time x (p50) | cost per Mgas, 7M -> 25M |
|---|---|---|---|
| mainnet | 3.57 | **5.74** | 2429 -> 3900 us (+61%) |
| ecdsa | 3.57 | **4.46** | 16286 -> 20360 us (+25%) |
| blockfiller | 3.57 | **4.30** | 1429 -> 1720 us (+20%) |

Cost per unit of gas would be FLAT if processing were linear. It climbs on every
workload with a full curve.

**ecdsa is the binding workload (Gate B).** At 25M its p95 is 1006ms = 10.1% of the
10s block interval and its worst block 1710ms = 17.1%. Every other workload stays
under 3.5%. It is CPU-bound on signature verification, and its p95 grew 4.19x for
3.57x more gas — the margin shrinks as the limit rises, it does not hold.

## Do not write these (sweep)

- **Do not compare absolute milliseconds ACROSS scenarios.** Each curve is pinned to
  one machine because an A/A with identical jar, seed and gas limit measured 89ms
  (us-west) vs 129ms (us-east) — a 45% box term, the same order as the effects being
  measured. Within a curve that term is constant and cancels from the SHAPE; across
  curves it does not. ecdsa's 509ms and mainnet's 97.5ms are on different boxes.
  `sweep_curves.csv` carries a `box` column — check it before putting two series on
  one axis.
- **Do not report an indexer curve.** It is absent on purpose: saturation wandered
  non-monotonically with the gas limit (0.776 @7M, 0.579 @10M, 0.633 @17M, 0.915 @25M),
  leaving no stable denominator. Its A/B results stand; a gas-limit curve does not.
- **Do not report storagereads as sub-linear.** Only 1-3 cycles survived per cell and
  every one is MARGINAL (utilization 0.82-0.84, under the 0.90 bar). The row exists for
  completeness; `curve_claimable` says what it is worth.
- **Do not treat calldata's 2 points as a curve.** `curve_claimable` marks it
  "slope only (2 points)". It cannot saturate small blocks at all: the 131,072-byte
  transaction limit caps one calldata tx at ~2.23M gas, so a 7M block holds at most
  three and any declared-gas margin costs a whole slot. A property of calldata, not a
  tuning miss.
- **Check `cycles` and `mean_util` before quoting any curve point.** 17 of 102 runs
  were excluded for under-filling and 19 more flagged MARGINAL. Under-filled runs
  measure the load generator rather than the node and produce a believable flat curve —
  that is the single most dangerous failure mode in this experiment, which is why
  saturation was measured at every gas limit BEFORE the sweep (`results/sweep/
  saturation-*.csv`).

## Sweep coverage

Tip `392ae5506` — full 4-point curves: mainnet, ecdsa, blockfiller. Three points:
storagereads (7M excluded). Two points: calldata (7M and 10M excluded). No curve:
indexer.

Baseline `47a2eb63a` — full 4-point curves for ecdsa and mainnet only; the sweep was
deliberately limited to those two (the others did not produce clean curves on tip and
would have wasted the machine time).

## BOTH BUILDS ARE IN sweep_curves.csv — always filter on `build`

`392ae5506` is tip, `47a2eb63a` is baseline. The curves are keyed by build, so a query
that ignores the column silently averages the two into a meaningless middle. Filter:

    awk -F, '$3=="47a2eb63a"' results/report-pack/sweep_curves.csv

### What the two curves show

**The mitigations shifted the curve DOWN; they did NOT flatten it.** Growth over an
identical 10M -> 25M span (2.5x gas):

| scenario | baseline | tip |
|---|---|---|
| mainnet | 47 -> 172ms = **3.65x** | 26 -> 98ms = **3.79x** |
| ecdsa | 241 -> 719ms = **2.99x** | 177 -> 509ms = **2.88x** |

Near-identical slopes, with baseline consistently higher — tip is 43% faster on
mainnet and 29% faster on ecdsa at 25M. The implication for going past 25M: the same
super-linear scaling still applies, from a lower starting point. The mitigations bought
headroom, not a change in how cost grows.

Quote growth factors over the SAME gas span for both builds. The tip's published
7M->25M figures (4.46x ecdsa, 5.74x mainnet) are over 3.57x gas and are not comparable
to a baseline number measured over a shorter span.

**Gate B, baseline vs tip at 25M:** ecdsa p95 1602ms (16.0% of the 10s block interval)
against tip's 1006ms (10.1%). The baseline's worst block is 2643ms.

**Do not read mainnet baseline p95 as a clean tail.** Its 7M cell reports p50 23ms with
p95 459ms and max 1577ms — a tail two orders of magnitude above the median, unlike any
tip cell. Something is unstable there; the p50 curve is sound, the baseline p95 series
is not.


# ==========================================================================
# Top-up cycles (2026-10-02)
# ==========================================================================

ecdsa and mainnet-sim were taken from 4-5 cycles to 7 (Boton) and 8 (local), so results
that were "direction only" could clear p<0.05. Significant claims went 23 -> 28.

**The two the report wanted are now quotable, and both held direction:**

| cell | at 4 cycles | at 7 cycles |
|---|---|---|
| boton mainnet `totalMs` | -49.4% (p=0.125) | **-46.7%, 7/7, p=0.0156** |
| boton ecdsa `saveReceiptsMs` | -97.25% (p=0.125) | **-97.2%, 7/7, p=0.0156** |

Also newly significant: boton `ecdsa totalMs` -10.6%, `mainnet executeMs` -8.1%,
`mainnet saveReceiptsMs` -94.4% (all 7/7, p=0.0156); local `ecdsa saveReceiptsMs`
-100% (8/8, p=0.0078) and `mainnet txExecutionMs` -6.25% (8/8, p=0.0078).

## Methodology deviation in Boton cycles 12-14

Cycles 1-4 ran on a matched us-east pair. The box used for cycles 12-14 is **us-west**
(the us-east box it replaced died on 2026-09-28), so the pair is us-west + us-east. An
A/A with identical jar, seed and gas limit measured 89ms vs 129ms across those regions.
Counterbalancing still cancels the box term WITHIN each cycle, so each cycle's delta is
valid — but cycles 12-14 carry different variance than 1-4. Accepted deliberately.

## Cycles discarded

Six Boton cycles from the first top-up attempt. `collect-experiment.sh` invoked
`/tmp/analyze_block_breakdown.py` on each box but never shipped it; the newly
provisioned box did not have it, python3 failed, and the surrounding `|| true` swallowed
the error. All six produced `.txt` files containing only the error and no `.json`, and
the raw logs were wiped by the next cold deploy. Fixed: the analyzer now ships on every
collection and a failed copy reports loudly. Excluded for an identified physical cause.


# ==========================================================================
# `mainnetprobe` — the §4.2 block-store measurement (2026-10-06)
# ==========================================================================

A THIRD experiment, and a THIRD build. Rows with `scenario == mainnetprobe` compare
tip `392ae5506` against **baseline+probe `a0106dabd`**, which is NOT the `47a2eb63a`
baseline behind every other row in this pack.

## Why it exists

`preambleMs` — the block-store lookup cost at §4.2 — is emitted only by builds carrying
`b4a13038d`. The baseline predates it, so the main A/B could not see the metric at all:
the field is simply absent from baseline log lines. `a0106dabd` is `47a2eb63a` with that
instrumentation commit cherry-picked on, and nothing else.

**The probe is provably observational.** Its only runtime-path change is one extra field
in a log format string plus `validationStartNanos - connectStartNanos`. Both timestamps
already existed in the baseline, so it adds no `nanoTime()` call and cannot change
behaviour. It does NOT include `06841e483`, the block-store fix, which is the thing being
measured.

## Result

| metric | median | cycles | sign p |
|---|---|---|---|
| **preambleMs** | **-100.0%** | 5 | 0.0625 |
| totalMs | -42.6% | 5 | 0.0625 |
| saveReceiptsMs | -94.1% | 5 | 0.0625 |

Tip's preamble p50 is **0.0ms in all ten slots**; baseline+probe is 2-7ms and never
zero. The fix removes the cost rather than reducing it. Absolute p50 per cycle
(baseline+probe fwd/rev vs tip): 4.0/7.0, 3.0/6.0, 3.5/5.0, 2.0/6.0, 2.0/7.0 vs 0.0
throughout.

totalMs and saveReceiptsMs track the main A/B closely (-46.7% / -94.4% there), which is
the check that the probe build behaves like the baseline it came from.

## Do not write these

- **Do not pool `mainnetprobe` with `mainnet`.** Different baseline build. They are
  separate experiments that happen to share a workload.
- **Do not quote it as significant yet** unless `cycles` reads 6 or more — 5 unanimous
  cycles is p=0.0625. Two further cycles were running at the time of writing; regenerate
  and re-check the `claimable` column before quoting.
- **Do not read `totalMs` from a single slot.** The same build measured 147-153ms on one
  box and 256-261ms on the other in the same cycles. Only the box-cancelled combined
  estimate is meaningful; this is the 45% box term, not a build effect.

## Still unmeasured: §4.5 mining candidate construction

No build emits timing for it, and it runs while building the NEXT block rather than
processing the current one, so no metric in this pack covers it. It is observable
externally as `mnr_getWork` RPC latency (candidate construction happens inside
`MinerServerImpl.getWork()`), which needs a k6 probe and its own runs. Not attempted
yet — do not infer anything about §4.5 from these numbers.
