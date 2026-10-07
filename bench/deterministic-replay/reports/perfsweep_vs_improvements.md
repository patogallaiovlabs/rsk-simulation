# Full branch tip vs. improvements-only branch (both vs. commit-1 baseline)

All three: 3 independent 1158-block replay runs, all passed the sanity check.

- **baseline** = commit 1 (`47a2eb63a`) — instrumentation only
- **full tip** = `block-processing-perf` tip (`b4a13038d`) — all 18 commits, improvements and regressions both included, in original order
- **improvements-only** = `ri_fixleak-improvements-only` — commit 1 + the 11 commits that individually measured as improvements + `35d600ebd` (required compile dependency, not a perf pick)

## Mean ± stdev across 3 runs (ms)

| metric | baseline | full tip (18 commits) | improvements-only (12 commits) |
|---|---|---|---|
| totalMs | 65.19 ± 2.08 | 52.20 ± 4.16 | 52.34 ± 3.09 |
| executeMs **†** | 32.21 ± 0.85 | 28.56 ± 2.39 | 28.00 ± 0.96 |
| initialValidationMs | 16.28 ± 0.06 | 16.84 ± 2.29 | 16.89 ± 2.77 |
| txExecutionMs **†** | 18.16 ± 0.08 | 16.92 ± 1.51 | 16.61 ± 0.94 |
| statePersistMs **†** | 13.55 ± 0.77 | 11.12 ± 1.36 | 10.88 ± 0.07 |
| saveReceiptsMs | 2.58 ± 0.39 | 1.45 ± 0.25 | 1.46 ± 0.35 |
| onBestBlockMs | 6.65 ± 0.83 | 1.32 ± 0.11 | 1.91 ± 0.14 |
| switchChainMs | 3.88 ± 0.99 | 1.77 ± 0.96 | 1.82 ± 0.54 |

† trustworthy metrics per README (totalMs/initialValidationMs dominated by cold-cache noise)

## % change vs. baseline

| metric | full tip Δ% | improvements-only Δ% | improvements-only vs full tip |
|---|---|---|---|
| totalMs | -19.9% | -19.7% | +0.3% |
| executeMs | -11.3% | -13.1% | -2.0% |
| initialValidationMs | +3.4% | +3.8% | +0.3% |
| txExecutionMs | -6.8% | -8.5% | -1.8% |
| statePersistMs | -17.9% | -19.7% | -2.2% |
| saveReceiptsMs | -44.0% | -43.4% | +1.1% |
| onBestBlockMs | -80.2% | -71.3% | +44.9% |
| switchChainMs | -54.4% | -53.2% | +2.7% |

## Head-to-head: improvements-only vs full tip, raw means (ms)

| metric | full tip | improvements-only | improvements-only is... |
|---|---|---|---|
| executeMs | 28.56 | 28.00 | 2.0% faster |
| txExecutionMs | 16.92 | 16.61 | 1.8% faster |
| statePersistMs | 11.12 | 10.88 | 2.2% faster |

## Notes
- 'improvements-only vs full tip' isolates the value of curating the branch (dropping the 5 step-wise regressions and keeping the true baseline dependency) versus just taking everything as one linear sequence.
- Single dependency exception: `35d600ebd` is in both branches (full tip has it in original position; improvements-only has it as a forced dependency for the multiGet commit), so it isn't a variable between the two comparisons.
