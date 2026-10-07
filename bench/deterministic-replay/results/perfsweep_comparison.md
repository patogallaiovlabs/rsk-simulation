# Commit sweep comparison (1158-block replay, mean ms per qualifying block)

Range: commit 1 (`47a2eb63a`, feat: add block-connect timing breakdown instrumentation and JMX exposure) through tip (`b4a13038d`, feat: expose the preamble, post-execute-validation and process-best timings) on `block-processing-perf`, generated Tue Aug 25 17:24:02 -03 2026.

Per README guidance: `executeMs`/`txExecutionMs`/`statePersistMs` are the trustworthy steady-state metrics; `totalMs`/`initialValidationMs` are dominated by this harness's cold-cache signature verification and shouldn't be used to judge real block-processing changes.

## Absolute means (ms)

| # | commit | subject | totalMs | executeMs | initialValidationMs | txExecutionMs | statePersistMs | saveReceiptsMs | onBestBlockMs | switchChainMs |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 | 47a2eb63a | feat: add block-connect timing breakdown instrumenta... | 66.8 | 33.1 | 16.3 | 18.2 | 14.4 | 2.1 | 7.0 | 4.9 |
| 02 | 06841e483 | fix: count true-negative block lookups, drop dead pe... | 71.8 | 36.4 | 17.4 | 20.6 | 15.3 | 2.7 | 6.8 | 4.5 |
| 03 | 35d600ebd | fix: bound DataSourceWithCache's async flush queue a... | 66.2 | 34.3 | 17.4 | 19.5 | 14.3 | 3.0 | 2.1 | 5.3 |
| 04 | 680fe563e | perf: reuse per-thread Keccak digest instances inste... | 61.1 | 32.4 | 17.2 | 19.0 | 12.9 | 2.8 | 1.9 | 3.0 |
| 05 | 03ad04e49 | perf: memoize RskSystemProperties.getVmConfig() | 59.3 | 30.6 | 19.9 | 18.5 | 11.5 | 2.2 | 1.7 | 1.8 |
| 06 | acfb136d6 | fix: stale value left in MutableTrieCache after recu... | 59.1 | 30.2 | 19.1 | 18.1 | 11.6 | 2.2 | 1.7 | 2.7 |
| 07 | 89d4b8c22 | perf: skip re-saving an already-saved trie, avoid un... | 57.0 | 29.8 | 15.9 | 17.3 | 12.0 | 2.5 | 2.0 | 3.2 |
| 08 | 36eff3fdc | perf: batch ReceiptStoreImplV2 writes into a single ... | 57.6 | 29.4 | 19.8 | 18.0 | 10.9 | 2.0 | 1.7 | 1.8 |
| 09 | d8d74bd2d | perf: remove two redundant per-transaction re-comput... | 54.8 | 28.6 | 15.7 | 16.6 | 11.5 | 2.4 | 1.9 | 2.7 |
| 10 | 536047aa5 | perf: memoize Transaction.nonZeroDataBytes() | 56.5 | 28.1 | 20.0 | 17.5 | 10.0 | 2.0 | 1.7 | 1.7 |
| 11 | 2a38446c3 | perf: run BlockChainFlusher's 5 store flushes concur... | 58.1 | 29.6 | 20.3 | 18.4 | 10.7 | 2.0 | 1.3 | 1.8 |
| 12 | 61a5fcd22 | perf: add RocksDB bloom filter scoped to the receipt... | 52.8 | 28.8 | 15.5 | 16.2 | 12.1 | 1.9 | 1.3 | 2.0 |
| 13 | 16e5ea021 | perf: add KeyValueDataSource.multiGet() and use it i... | 48.7 | 26.3 | 15.1 | 15.2 | 10.6 | 1.5 | 1.3 | 1.4 |
| 14 | c1bdf95fe | perf: avoid array copy in TrieKeySlice.encode() | 52.0 | 27.8 | 15.6 | 16.2 | 11.0 | 1.5 | 1.3 | 2.4 |
| 15 | b16e962c6 | perf: merge ancestor and used-uncles walks into a si... | 50.4 | 27.4 | 15.2 | 15.9 | 10.9 | 1.5 | 1.3 | 1.8 |
| 16 | 956f5f5f8 | perf: only populate the block caches on an actual st... | 58.8 | 30.2 | 19.2 | 17.2 | 12.4 | 2.0 | 1.2 | 2.5 |
| 17 | 697ac822e | perf: extend the RocksDB bloom filter to the blocks ... | 56.5 | 31.2 | 16.6 | 18.0 | 12.7 | 2.1 | 1.4 | 2.7 |
| 18 | b4a13038d | feat: expose the preamble, post-execute-validation a... | 55.6 | 31.2 | 15.9 | 18.1 | 12.6 | 1.7 | 1.4 | 2.9 |

## % change vs commit 1 (baseline)

| # | commit | totalMs | executeMs | initialValidationMs | txExecutionMs | statePersistMs | saveReceiptsMs | onBestBlockMs | switchChainMs |
|---|---|---|---|---|---|---|---|---|---|
| 01 | 47a2eb63a | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% |
| 02 | 06841e483 | +7.5% | +9.9% | +6.9% | +12.7% | +6.4% | +28.6% | -2.0% | -6.7% |
| 03 | 35d600ebd | -0.9% | +3.7% | +6.8% | +6.8% | -0.4% | +42.8% | -69.5% | +9.4% |
| 04 | 680fe563e | -8.5% | -1.9% | +5.5% | +4.4% | -10.2% | +30.3% | -72.9% | -39.1% |
| 05 | 03ad04e49 | -11.2% | -7.6% | +22.2% | +1.7% | -19.8% | +2.5% | -76.3% | -62.1% |
| 06 | acfb136d6 | -11.5% | -8.8% | +16.9% | -0.7% | -19.3% | +2.3% | -75.2% | -43.7% |
| 07 | 89d4b8c22 | -14.6% | -10.0% | -2.6% | -5.1% | -16.7% | +18.4% | -71.0% | -33.7% |
| 08 | 36eff3fdc | -13.8% | -11.3% | +21.7% | -1.5% | -24.3% | -7.3% | -76.2% | -63.0% |
| 09 | d8d74bd2d | -17.9% | -13.7% | -3.9% | -9.1% | -20.2% | +13.0% | -73.0% | -44.4% |
| 10 | 536047aa5 | -15.4% | -15.1% | +22.4% | -3.9% | -30.2% | -5.3% | -75.1% | -64.9% |
| 11 | 2a38446c3 | -13.0% | -10.6% | +24.6% | +0.9% | -25.6% | -7.3% | -81.8% | -63.1% |
| 12 | 61a5fcd22 | -21.0% | -13.0% | -5.1% | -11.2% | -15.9% | -9.5% | -81.7% | -58.0% |
| 13 | 16e5ea021 | -27.0% | -20.5% | -7.5% | -16.4% | -26.4% | -27.8% | -80.8% | -71.8% |
| 14 | c1bdf95fe | -22.1% | -16.1% | -4.3% | -11.0% | -23.3% | -27.5% | -81.0% | -51.2% |
| 15 | b16e962c6 | -24.5% | -17.3% | -6.8% | -12.7% | -23.8% | -28.1% | -82.0% | -63.5% |
| 16 | 956f5f5f8 | -12.0% | -8.9% | +17.6% | -5.6% | -13.6% | -8.7% | -82.1% | -47.6% |
| 17 | 697ac822e | -15.4% | -5.6% | +1.6% | -1.2% | -11.5% | +0.5% | -79.2% | -44.3% |
| 18 | b4a13038d | -16.8% | -5.7% | -2.3% | -0.9% | -12.1% | -18.7% | -79.2% | -40.9% |

## Notes
- Single run per commit (not the 2-3 repeats the README recommends for noise control) — treat deltas smaller than ~15-20% as unproven per the harness's documented run-to-run noise band.
- `onBestBlockMs`/`switchChainMs` swing heavily between commits because they're driven by how many flush/reorg events land within the 1158-block window (~103 flush events at FLUSH_BLOCKS=10) — small sample counts, not necessarily code-driven.
