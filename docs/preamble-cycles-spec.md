# Complete the preamble runs — run spec

**Goal:** finish cycle 6 of the instrumented-preamble mainnet-sim runs so the
`preambleMs` result becomes claimable, and explain an unrelated anomaly in the same runs.

## Part 1 — one missing arm pair

`results/boton/` has `bseq1`..`bseq5` complete (fwd and rev) plus `bseq6-mainnetprobe-fwd`.
The `rev` slot of cycle 6 is missing, so the pack counts 5 cycles.

```
results/boton/bseq6-mainnetprobe-rev/     <- run this
```

Five cycles, all five favouring the tip, gives p=0.0625 and misses p<0.05. A sixth
unanimous cycle gives p=0.031 and clears it. Run cycle 7 as well if the box is free, so
one discarded cycle does not put it back under the bar.

The result being qualified:

| | baseline | tip |
|---|---|---|
| `preambleMs` mean | 4.11 ms | 0.07 ms |
| `preambleMs` p95 | 13.0 ms | 0.0 ms |

### Settings that must match

New cycles are pooled with the existing five, so any difference in collection makes them
unusable.

- threshold **0.9**
- 30 minute runs, same seeded database restored before each
- builds `47a2eb63a` and `392ae5506`, **both carrying the preamble instrumentation** —
  this is what distinguishes these runs from the ordinary mainnet-sim set
- counterbalanced: `rev` swaps which box runs which build, same as `bseq1`..`bseq5`
- both Boton instances in us-east (ash-dc1)

## Part 2 — explain the executeMs anomaly

These runs cannot currently contribute anything except `preambleMs`, because their tip arm
is much slower than the ordinary mainnet-sim runs on the same commits:

| | mainnet-sim | preamble runs |
|---|---|---|
| tip `totalMs` | 109 ms | 162 ms |
| tip `executeMs` | **72 ms** | **106 ms** |
| tip `saveReceiptsMs` | 5.7 ms | 7.1 ms |
| utilisation | 98.4% | 98.4% |
| qualifying blocks | ~115 | ~121 |

Baseline arms are much closer (208 vs 168 ms total, 77 vs 69 ms execute). It is the tip's
execution that is 48% slower, which turns a −47% end-to-end result into −4%.

Same commits, same utilisation, same block counts, so the workload is not the difference.
Candidates worth checking, in rough order of likelihood:

- **when they ran**, and what else was on the box at the time
- **the seeded database**: same snapshot, same height, same size on disk?
- **config drift** between the two run sets, particularly `FLUSH_BLOCKS` and any JVM flags
- **instrumentation cost**: the preamble timing is debug-gated, but confirm the gate is
  actually closed in these runs and that `debugEnabled` is not forcing the other
  `System.nanoTime()` calls on the connect path

Until this is explained, only `preambleMs` is used from these runs and their `totalMs` is
excluded. That exclusion is recorded in the report's appendix B.

## Report back

- `preambleMs` cycle count and whether the direction held in cycle 6 (and 7).
- What explains the tip `executeMs` gap, or what you ruled out. If it turns out to be the
  instrumentation itself, say so plainly: that would mean the preamble measurement costs
  something, and the 4.11 to 0.07 ms figure needs re-reading.
