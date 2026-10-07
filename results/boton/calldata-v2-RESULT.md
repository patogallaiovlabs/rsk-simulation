# Calldata settlement (option 11) — counterbalanced, box term cancelled

First valid calldata run. Earlier attempts (`calldata-fwd`/`calldata-rev`, 2026-09-23
21:13/21:50) produced no data: a double `0x` prefix made every send fail with HTTP 400
at the RPC layer, so the node never saw a transaction. Two defects had to be fixed
before this workload measured anything -- see "Scenario fixes" below.

Both slots: 30 min/arm, 97% mean block utilization, 12 tx/block, 0 send failures.
Qualifying blocks (>=90% of gas limit): fwd A=122 B=126, rev A=101 B=113.

## Build effect, tip vs baseline (box term cancelled)

| metric | box A serial | box B serial | COMBINED |
|---|---|---|---|
| totalMs p50 | -22.8% | -42.2% | **-32.5%** |
| txExecutionMs p50 | -31.2% | -38.2% | **-34.7%** |
| saveReceiptsMs p50 | -100% | -100% | **-100%** |
| executeMs p50 | +17.9% | +11.1% | +14.5% |
| totalMs p95 | -6.2% | -28.2% | -17.2% |
| txExecutionMs p95 | -55.8% | -48.3% | -52.0% |
| saveReceiptsMs p95 | -84.4% | -95.6% | -90.0% |

**Tip is substantially faster on this workload.** Both boxes agree in sign on every
metric, and -32.5% is far outside the ~8% same-build noise measured between co-located
boxes, so this is a build effect rather than environment.

Absolute p50, decoded (ms):

| metric | baseline | tip |
|---|---|---|
| totalMs | 63.5 / 77.0 | 44.5 / 49.0 |
| saveReceiptsMs | 12.0 / 19.0 | 0.0 / 0.0 |
| txExecutionMs | 16.0 / 17.0 | 10.5 / 11.0 |
| executeMs | 14.0 / 13.5 | 15.0 / 16.5 |

saveReceiptsMs going 12-19ms -> 0 is the single largest contributor, consistent with
the receipts effect seen on every other Boton workload.

## The executeMs "+14.5% regression" is not one

It is +1.5ms and +2.5ms on 13.5-14.0ms medians, in logs quantized to whole
milliseconds -- one to two integer steps. The percentage makes it look like a
regression; the absolute value shows it is at the resolution floor. It is reported
here for completeness, not as a finding.

Do NOT reconcile it against txExecutionMs (-35%) by assuming one contains the other.
`executeMs` comes from `block connect breakdown` on [TimedMinerClient]; `txExecutionMs`
comes from `block execute breakdown` on [main]. Different log lines, different threads,
not necessarily the same blocks -- they are not nested measurements of the same work.

## Reading the per-slot files: the naming trap

`comparison.txt` inside `calldata-v2-rev/` is labelled by BOX ROLE, not by build. In
the reversed slot box A ran TIP, so that file's `base_cmp` column IS the tip build.
Read naively, the rev slot appears to show tip 57% SLOWER on totalMs and saveReceiptsMs
regressing from 0 to 19ms -- the exact opposite of the truth. Only the combined
crossover output (`crossover_estimate.py`, which maps the roles explicitly) is safe to
quote. The decoded absolutes above reproduce that tool's per-box percentages exactly,
which is how the decoding was verified.

## Scenario fixes required to get here

1. **Double `0x` prefix.** `encodeSettleBatch()` already returns a 0x-prefixed string
   and the caller prepended another, yielding `0x0x279b3b95...`. Rejected with HTTP 400
   before reaching the node: 14,905 failures, clean node log. Same defect fixed in
   `calldata-random-test.js`; still present in `bug/calldata-settlement-test.js`.
2. **Unreachable declared gas.** `computeBatchDataSize` clamps calldata to
   ~130,592 B (the 131,072-byte tx limit), so low-tx-count phases cannot cost their
   gas target -- but the target was declared anyway. The block builder stops once the
   next tx's DECLARED limit exceeds the remainder, so blocks capped at 7 tx / 13.2M of
   25M (53%) while each tx burned 1.89M of its declared 12.5M. Now measured per phase
   with `eth_estimateGas` and declared at measured x1.25. Result: **53% -> 97%
   utilization, 7 -> 12 tx/block.**

Inherent limit, now logged as `[size-limited]`: phases 1/2/4/8 can never fill a block
via calldata (~1.9M gas ceiling per tx; ~13 tx needed for 25M). Only phases 16 and 32
saturate. That is a property of calldata, not a defect.

## Local serial A/B (arm64, no box term at all) — 2 cycles, order alternated

4 arms x 30 min, ~98% utilization, 77-102 qualifying blocks each. Cycle 1 ran
baseline-first, cycle 2 tip-first, so night-drift cannot land preferentially on one
build.

| metric p50 | cycle 1 | cycle 2 | verdict |
|---|---|---|---|
| txExecutionMs | -42.9% | -46.7% | **same sign, large** |
| totalMs | +4.5% | -21.6% | opposite sign — inconclusive |
| executeMs | +5.6% | 0.0% | flat |
| saveReceiptsMs | 0.0 -> 0.0 ms | 0.0 -> 0.0 ms | nothing to measure |

**txExecutionMs is the finding that survives everywhere.** Four independent
measurements, two architectures (amd64 Boton, arm64 local), every one the same sign:
-31%, -38% (Boton box A/B) and -43%, -47% (local cycles 1/2). This is not an
environment artifact.

**totalMs locally is inconclusive, and that is expected rather than contradictory.**
Local baseline saveReceiptsMs is already 0.0ms on NVMe, so the change has no receipts
cost to remove -- and receipts are what drives Boton's -32.5% totalMs. With that term
absent, what remains locally is a ~5ms txExecution saving inside a ~22-26ms total,
which the +/-10-14% local run-to-run noise swallows. The two cycles landing on
opposite signs (+4.5%, -21.6%) is exactly that noise, and two cycles cannot separate a
sub-noise effect. Reporting a mean of those two numbers would be meaningless.

## Combined conclusion

The tip build improves this calldata workload through two independent mechanisms:

1. **saveReceiptsMs -> 0** (12-19ms -> 0 on Boton). I/O-bound, so its size scales with
   storage speed: large on Boton, invisible on local NVMe where the baseline already
   costs ~0. This drives the -32.5% totalMs headline.
2. **txExecutionMs -31% to -47%**, reproducible on both architectures and independent
   of storage speed.

The tracks agree where they measure the same thing and diverge only where one of them
physically cannot observe the effect.
