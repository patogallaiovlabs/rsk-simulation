# Commit sweep comparison — 3 runs consolidated (1158-block replay)

Range: commit 1 (`47a2eb63a`, feat: add block-connect timing breakdown instrumentation and JMX exposure) through tip (`b4a13038d`, feat: expose the preamble, post-execute-validation and process-best timings) on `block-processing-perf`, 3 independent runs per commit (54 replays total, all passed the 1158-block sanity check).

Per README guidance: `executeMs`/`txExecutionMs`/`statePersistMs` are the trustworthy steady-state metrics; `totalMs`/`initialValidationMs` are dominated by cold-cache signature verification and shouldn't be used to judge real block-processing changes.

## Focus metrics: mean across 3 runs ± stdev (ms)

| # | commit | subject | executeMs | txExecutionMs | statePersistMs |
|---|---|---|---|---|---|
| 01 | 47a2eb63a | feat: add block-connect timing breakdown instru... | 32.2 ± 0.9 | 18.2 ± 0.1 | 13.6 ± 0.8 |
| 02 | 06841e483 | fix: count true-negative block lookups, drop de... | 31.9 ± 3.9 | 18.1 ± 2.1 | 13.2 ± 1.8 |
| 03 | 35d600ebd | fix: bound DataSourceWithCache's async flush qu... | 32.6 ± 3.4 | 18.4 ± 1.7 | 13.7 ± 1.7 |
| 04 | 680fe563e | perf: reuse per-thread Keccak digest instances ... | 29.6 ± 2.7 | 17.1 ± 1.8 | 11.9 ± 0.9 |
| 05 | 03ad04e49 | perf: memoize RskSystemProperties.getVmConfig() | 28.5 ± 1.8 | 16.7 ± 1.6 | 11.3 ± 0.2 |
| 06 | acfb136d6 | fix: stale value left in MutableTrieCache after... | 28.3 ± 1.7 | 16.4 ± 1.5 | 11.3 ± 0.2 |
| 07 | 89d4b8c22 | perf: skip re-saving an already-saved trie, avo... | 27.2 ± 2.3 | 16.0 ± 1.2 | 10.7 ± 1.1 |
| 08 | 36eff3fdc | perf: batch ReceiptStoreImplV2 writes into a si... | 27.1 ± 2.0 | 16.2 ± 1.5 | 10.4 ± 0.5 |
| 09 | d8d74bd2d | perf: remove two redundant per-transaction re-c... | 26.4 ± 2.1 | 15.4 ± 1.1 | 10.5 ± 0.9 |
| 10 | 536047aa5 | perf: memoize Transaction.nonZeroDataBytes() | 27.2 ± 1.1 | 16.2 ± 1.2 | 10.4 ± 0.5 |
| 11 | 2a38446c3 | perf: run BlockChainFlusher's 5 store flushes c... | 27.9 ± 1.5 | 16.6 ± 1.6 | 10.8 ± 0.2 |
| 12 | 61a5fcd22 | perf: add RocksDB bloom filter scoped to the re... | 27.8 ± 1.0 | 16.1 ± 0.3 | 11.2 ± 0.8 |
| 13 | 16e5ea021 | perf: add KeyValueDataSource.multiGet() and use... | 27.0 ± 1.8 | 15.7 ± 1.0 | 10.8 ± 0.8 |
| 14 | c1bdf95fe | perf: avoid array copy in TrieKeySlice.encode() | 27.8 ± 0.6 | 16.2 ± 0.3 | 11.1 ± 0.3 |
| 15 | b16e962c6 | perf: merge ancestor and used-uncles walks into... | 27.4 ± 1.6 | 15.9 ± 0.8 | 11.0 ± 0.8 |
| 16 | 956f5f5f8 | perf: only populate the block caches on an actu... | 29.5 ± 1.1 | 17.4 ± 0.2 | 11.5 ± 1.2 |
| 17 | 697ac822e | perf: extend the RocksDB bloom filter to the bl... | 28.2 ± 2.8 | 16.3 ± 1.5 | 11.3 ± 1.3 |
| 18 | b4a13038d | feat: expose the preamble, post-execute-validat... | 28.6 ± 2.4 | 16.9 ± 1.5 | 11.1 ± 1.4 |

## Focus metrics: per-run raw means (ms) — run1 / run2 / run3

| # | commit | executeMs (r1/r2/r3) | txExecutionMs (r1/r2/r3) | statePersistMs (r1/r2/r3) |
|---|---|---|---|---|
| 01 | 47a2eb63a | 33.1/32.2/31.4 | 18.2/18.2/18.1 | 14.4/13.5/12.8 |
| 02 | 06841e483 | 36.4/29.1/30.2 | 20.6/16.8/17.0 | 15.3/11.8/12.6 |
| 03 | 35d600ebd | 34.3/34.8/28.7 | 19.5/19.2/16.4 | 14.3/15.0/11.7 |
| 04 | 680fe563e | 32.4/27.0/29.4 | 19.0/15.4/17.0 | 12.9/11.0/11.9 |
| 05 | 03ad04e49 | 30.6/27.3/27.7 | 18.5/15.7/16.0 | 11.5/11.1/11.2 |
| 06 | acfb136d6 | 30.2/27.6/27.0 | 18.1/15.8/15.4 | 11.6/11.3/11.1 |
| 07 | 89d4b8c22 | 29.8/25.4/26.4 | 17.3/15.1/15.6 | 12.0/9.9/10.2 |
| 08 | 36eff3fdc | 29.4/26.1/25.8 | 18.0/15.3/15.3 | 10.9/10.3/10.0 |
| 09 | d8d74bd2d | 28.6/24.4/26.3 | 16.6/14.3/15.2 | 11.5/9.6/10.6 |
| 10 | 536047aa5 | 28.1/26.0/27.5 | 17.5/15.2/16.0 | 10.0/10.2/11.0 |
| 11 | 2a38446c3 | 29.6/27.3/26.6 | 18.4/15.8/15.6 | 10.7/11.0/10.6 |
| 12 | 61a5fcd22 | 28.8/26.8/27.9 | 16.2/15.7/16.3 | 12.1/10.6/11.1 |
| 13 | 16e5ea021 | 26.3/29.1/25.6 | 15.2/16.9/15.0 | 10.6/11.7/10.1 |
| 14 | c1bdf95fe | 27.8/28.5/27.2 | 16.2/16.5/15.9 | 11.0/11.4/10.8 |
| 15 | b16e962c6 | 27.4/29.1/25.8 | 15.9/16.8/15.1 | 10.9/11.8/10.2 |
| 16 | 956f5f5f8 | 30.2/30.1/28.2 | 17.2/17.5/17.5 | 12.4/12.1/10.1 |
| 17 | 697ac822e | 31.2/25.8/27.4 | 18.0/15.1/15.8 | 12.7/10.2/11.1 |
| 18 | b4a13038d | 31.2/26.5/27.9 | 18.1/15.2/17.5 | 12.6/10.8/9.9 |

## % change vs commit 1 baseline (using 3-run mean)

| # | commit | totalMs | executeMs | initialValidationMs | txExecutionMs | statePersistMs | saveReceiptsMs | onBestBlockMs | switchChainMs |
|---|---|---|---|---|---|---|---|---|---|
| 01 | 47a2eb63a | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% |
| 02 | 06841e483 | -3.2% | -1.0% | +0.8% | -0.1% | -2.4% | -7.1% | -10.5% | -24.4% |
| 03 | 35d600ebd | -6.3% | +1.2% | +2.0% | +1.2% | +1.0% | +3.1% | -70.9% | -6.5% |
| 04 | 680fe563e | -15.6% | -8.1% | -2.4% | -5.6% | -12.0% | -9.6% | -72.0% | -49.0% |
| 05 | 03ad04e49 | -17.1% | -11.4% | +2.7% | -7.8% | -16.8% | -17.8% | -71.2% | -56.3% |
| 06 | acfb136d6 | -18.2% | -12.2% | +0.6% | -9.5% | -16.3% | -22.2% | -73.9% | -52.1% |
| 07 | 89d4b8c22 | -21.0% | -15.5% | -6.7% | -11.8% | -21.2% | -18.9% | -71.5% | -49.7% |
| 08 | 36eff3fdc | -20.7% | -15.9% | +1.5% | -10.9% | -23.4% | -28.0% | -74.5% | -57.8% |
| 09 | d8d74bd2d | -22.7% | -18.0% | -7.6% | -15.3% | -22.2% | -19.0% | -72.9% | -52.0% |
| 10 | 536047aa5 | -19.3% | -15.7% | +2.2% | -10.6% | -23.2% | -20.3% | -71.4% | -54.9% |
| 11 | 2a38446c3 | -18.1% | -13.5% | +3.9% | -8.7% | -20.6% | -9.8% | -81.0% | -53.0% |
| 12 | 61a5fcd22 | -21.4% | -13.6% | -6.8% | -11.5% | -17.1% | -26.4% | -79.7% | -54.9% |
| 13 | 16e5ea021 | -22.4% | -16.1% | -7.0% | -13.4% | -20.3% | -22.5% | -79.1% | -51.9% |
| 14 | c1bdf95fe | -20.3% | -13.7% | -4.6% | -10.7% | -18.3% | -35.4% | -79.7% | -41.3% |
| 15 | b16e962c6 | -21.9% | -14.9% | -6.8% | -12.2% | -19.1% | -36.3% | -81.3% | -45.8% |
| 16 | 956f5f5f8 | -13.1% | -8.5% | +12.4% | -4.1% | -14.8% | -30.1% | -81.6% | -37.3% |
| 17 | 697ac822e | -22.1% | -12.6% | -4.4% | -10.2% | -16.3% | -35.5% | -80.0% | -55.0% |
| 18 | b4a13038d | -19.9% | -11.3% | +3.4% | -6.8% | -17.9% | -44.0% | -80.2% | -54.4% |

## Notes
- 3 runs per commit (54 total replays) instead of the single-run sweep from the first pass — stdev columns above show run-to-run spread per commit.
- Per the README's noise-floor findings (~10-20% run-to-run on executeMs/statePersistMs/txExecutionMs even for identical code), treat any 3-run-mean delta smaller than that band as unproven.
- All 54 replays passed the `1158 blocks IMPORTED_BEST` sanity check (0 failures across all 3 sweeps).
