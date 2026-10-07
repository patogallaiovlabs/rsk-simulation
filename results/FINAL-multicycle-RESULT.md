# Multi-cycle A/B: baseline 47a2eb63a vs tip 392ae5506

Repeated counterbalanced cycles, pooled with `scripts/paired_stats.py`. One delta per
CYCLE (not per block), then an exact two-sided sign test. Blocks within an arm share a
JVM, page cache and a growing database, so they are not independent; pooling thousands
of them would produce a tiny and dishonest confidence interval. The cycle is the unit
of replication.

A unanimous sign test cannot reach p<0.05 below 6 cycles (2/2^6 = 0.031). Scenarios
below 6 cycles report direction only.

## Boton — 2 boxes, crossover, box term cancelled

| scenario | cycles | totalMs | saveReceiptsMs | txExecutionMs |
|---|---|---|---|---|
| indexer | 7 | **-28.9%** (7/7, p=0.016) | **-100%** (7/7, p=0.016) | **-4.7%** (7/7, p=0.016) |
| calldata | 6 | **-32.0%** (6/6, p=0.031) | **-100%** (6/6, p=0.031) | **-38.0%** (6/6, p=0.031) |
| mainnet | 4 | -49.4% (4/4, p=0.125) | -94.3% (4/4) | -0.7% (n.s.) |
| ecdsa | 4 | -10.6% (4/4, p=0.125) | -97.2% (4/4) | +0.4% (n.s.) |

## Local — one machine, serial arms, no box term

| scenario | cycles | totalMs | txExecutionMs |
|---|---|---|---|
| calldata | 9 | -4.2% (6/8, p=0.289 — n.s.) | **-42.9%** (9/9, p=0.004) |
| indexer | 7 | -6.2% (6/6, p=0.031) | **-33.3%** (7/7, p=0.016) |

Local `saveReceiptsMs` is 0.0ms in BOTH arms on every workload here, so no ratio exists
to report. That is the expected result on NVMe, not a missing measurement.

## What the data supports

1. **Receipt persistence is the dominant win, and it is I/O-bound.** saveReceiptsMs
   collapses to ~0 on every Boton workload, significant where enough cycles exist. It
   is invisible locally because the local baseline already costs ~0 -- there is nothing
   to remove. This single term explains why Boton totalMs improves 29-49% while local
   totalMs barely moves.

2. **Transaction execution improves, but by a workload-dependent amount.** calldata
   -38% (Boton) / -43% (local), both significant. ecdsa and mainnet: flat. The earlier
   framing of a general execution speedup came from calldata alone and does not
   generalize.

3. **Unresolved: indexer txExecutionMs disagrees across tracks** -- -4.7% on Boton
   (7/7) versus -33.3% locally (7/7). Both unanimous, both significant, an order of
   magnitude apart. Same build, same scenario, different architecture and storage. Not
   explained yet; do not quote a single number for indexer execution.

4. **executeMs shows no reliable effect.** Boton indexer is +1.6% (0/5, p=0.062) and
   calldata is mixed (2/6, p=0.688). Where it looked like a regression earlier it was
   1-2ms on millisecond-quantized values.

## Two measurement traps found along the way

**Threshold mismatch.** Boton indexer cycles 1-3 were collected at a 0.3 utilization
threshold: mean utilization 44-50% over ~26 qualifying blocks, versus 91.5% over 88 at
0.9. Pooled naively they produced an apparent **+98% txExecutionMs regression** that is
**-3% to -6%** against a matched population. Collected JSONs keep aggregates only and
cannot be re-filtered, so those cycles are excluded permanently.
`paired_stats.py` now refuses to pool cycles whose stored thresholds differ.

**Concurrent-workload contamination.** During the rotation switch an old sequencer arm
was still running when a new one started; 22 minutes of overlap inflated one indexer
tip arm to 248.5ms p50 against ~29ms elsewhere. Both overlapping cycles are quarantined
under `results/local-ab/_quarantine/` with the evidence. Excluded for an identified
physical cause, never for being inconvenient.
