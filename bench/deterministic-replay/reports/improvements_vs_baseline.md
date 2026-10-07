# Improvements-only branch vs. commit-1 baseline (1158-block replay, 3 runs each)

Branch `ri_fixleak-improvements-only`: commit 1 (`47a2eb63a`) + 12 cherry-picked commits — the 11 commits whose step-wise delta reduced executeMs/txExecutionMs/statePersistMs, plus `35d600ebd` (DataSourceWithCache async-flush bounding) included as a **required compile-time dependency** for the multiGet commit, not because it measured as an improvement on its own (it didn't).

Excluded (measured as step-wise regressions): `536047aa5`, `2a38446c3`, `c1bdf95fe`, `956f5f5f8`, `b4a13038d`.

## Mean ± stdev across 3 runs (ms)

| metric | baseline (commit 1) | improvements-only | Δ | Δ% |
|---|---|---|---|---|
| totalMs | 65.19 ± 2.08 | 52.34 ± 3.09 | -12.85 | -19.7% |
| executeMs **(trustworthy)** | 32.21 ± 0.85 | 28.00 ± 0.96 | -4.21 | -13.1% |
| initialValidationMs | 16.28 ± 0.06 | 16.89 ± 2.77 | +0.61 | +3.8% |
| txExecutionMs **(trustworthy)** | 18.16 ± 0.08 | 16.61 ± 0.94 | -1.55 | -8.5% |
| statePersistMs **(trustworthy)** | 13.55 ± 0.77 | 10.88 ± 0.07 | -2.67 | -19.7% |
| saveReceiptsMs | 2.58 ± 0.39 | 1.46 ± 0.35 | -1.12 | -43.4% |
| onBestBlockMs | 6.65 ± 0.83 | 1.91 ± 0.14 | -4.74 | -71.3% |
| switchChainMs | 3.88 ± 0.99 | 1.82 ± 0.54 | -2.07 | -53.2% |

## Per-run raw means (ms) — run1 / run2 / run3

| metric | baseline | improvements-only |
|---|---|---|
| totalMs | 66.8/66.0/62.8 | 49.8/51.4/55.8 |
| executeMs | 33.1/32.2/31.4 | 27.3/27.6/29.1 |
| initialValidationMs | 16.3/16.2/16.3 | 15.3/15.3/20.1 |
| txExecutionMs | 18.2/18.2/18.1 | 15.9/16.3/17.7 |
| statePersistMs | 14.4/13.5/12.8 | 10.9/10.8/10.9 |
| saveReceiptsMs | 2.1/2.8/2.8 | 1.2/1.9/1.3 |
| onBestBlockMs | 7.0/7.3/5.7 | 1.8/2.1/1.8 |
| switchChainMs | 4.9/3.9/2.9 | 2.0/2.2/1.2 |

## Notes
- Both sides: 3 independent replay runs of the same 1158-block sample, all passing the `1158 blocks IMPORTED_BEST` sanity check.
- `executeMs`/`txExecutionMs`/`statePersistMs` are the metrics to trust per the harness README; `totalMs`/`initialValidationMs` are dominated by cold-cache signature verification noise.
- This branch is a benchmark artifact, not a production candidate as-is: it deliberately drops 5 commits that measured as regressions, some of which may carry other value (e.g. `b4a13038d` adds timing instrumentation fields) independent of raw speed.
