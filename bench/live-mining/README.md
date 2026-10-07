# Live-mining baseline

A snapshot of `co.rsk.metrics.BlockProcessingStats`'s JMX gauges (see
`bench/deterministic-replay/README.md` → "Live metrics in Grafana"), pulled from
Prometheus and saved to disk, so a *live* node's block-processing timings can be compared
before/after a code change the same way `bench/deterministic-replay/` compares replay runs
— without needing the live window and the "after" window to be open in Grafana at the same
time, and without losing the data once Prometheus's retention window rolls past it.

## Why this exists

`bench/deterministic-replay/` is deliberately small and short-lived (a ~1.4GB seed
database, replayed once, then thrown away) so it's fast and reproducible. That's exactly
why it can't answer some questions: a real node accumulates state over days/weeks, runs a
much bigger RocksDB instance, and has other threads (mempool rebuild, JMX scraping, P2P)
competing for the same JVM. This directory captures what an actual long-running node looks
like, so a candidate change can be checked against both: "does it help the isolated,
apples-to-apples case?" (replay) and "does it actually move the needle on a real node?"
(here).

## Contents

- `fetch_prometheus_baseline.py` — pulls every `rsk_block_*` metric for one instance over a
  time range from Prometheus's `query_range` API, writes a wide-format CSV (one row per
  scrape timestamp) plus a `_summary.json` (n/mean/p50/p95/min/max per metric).
- `hourly_trend_export.py` — buckets an already-fetched CSV into hourly means, to spot
  trends over a long window at a glance.
- `results/miner1_2026-08-21_baseline.{csv,_summary.json}` — the full available history at
  the time this was captured: 2026-08-20 21:30 UTC (shortly after the receipts bloom
  filter/`multiGet` fix, commits 11-13 in `bench/deterministic-replay/README.md`, first
  reached a running miner) through 2026-08-21 12:53 UTC, ~15.5h, 15s step, 3693 samples.
- `results/miner1_2026-08-21_settled_last6h.{csv,_summary.json}` — the last 6 hours of the
  same window only. **Use this one as "the" baseline for future before/after comparisons**
  — see "Known non-stationarity" below for why the full-window one isn't representative of
  steady state.
- `results/miner1_2026-08-21_hourly_trend.csv` — hourly-bucketed means across the full
  window, the evidence behind that non-stationarity finding.

## Known non-stationarity: `SaveReceiptsMs` was still settling in this window

Don't treat `miner1_2026-08-21_baseline_summary.json` (the full-window one) as a stable
number to compare against — `SaveReceiptsMs` drops by more than half over the course of it,
purely as a side effect of the bloom filter fix's own rollout, unrelated to any load or
contention change:

| hour (UTC) | SaveReceiptsMs | ExecuteMs | TxExecutionMs | StatePersistMs | TotalMs |
|---|---|---|---|---|---|
| 08-20 21:00 | 40.4 | 31.0 | 19.3 | 11.2 | 107.1 |
| 08-20 22:00 | 37.8 | 30.3 | 19.5 | 10.3 | 119.4 |
| 08-20 23:00 | 26.9 | 27.1 | 18.0 | 8.6 | 80.6 |
| 08-21 02:00 | 23.9 | 24.0 | 15.7 | 7.9 | 72.6 |
| 08-21 05:00 | 17.7 | 26.2 | 17.1 | 8.5 | 68.0 |
| 08-21 08:00 | 15.8 | 26.2 | 17.1 | 8.5 | 68.0 |
| 08-21 10:00 | 12.6 | 26.1 | 17.0 | 8.6 | 64.8 |
| 08-21 12:00 | 13.4 | 27.7 | 18.0 | 9.1 | 67.9 |

**`SaveReceiptsMs` is the only metric with a real trend — everything else (`ExecuteMs`,
`TxExecutionMs`, `StatePersistMs`, `InitialValidationMs`) stays flat across the same 15
hours** (the 22:00 hour's across-the-board bump in every metric simultaneously is a
separate, short-lived contention/host-noise event, not part of this trend — ignore it).

This was initially misread as "a bigger database gives the shared block cache worse
coverage over time" — that theory is wrong: it predicts `SaveReceiptsMs` should *increase*
as the database keeps growing, and it does the opposite. The actual mechanism: RocksDB
bloom filters only apply to SST files written or compacted *after* `setFilterPolicy(...)`
takes effect (documented as a caveat on that commit, same non-retroactive behavior as this
repo's `compressionType` note) — receipts' existing SST files at deploy time mostly
predated the filter, and only gain it once normal compaction naturally rewrites them. Over
the following ~12 hours, enough of the receipts table got rewritten (confirmed by listing
`test/local-regtest/database/receipts/*.sst`: file numbers climbed from the low 800s to the
mid 800s, i.e. dozens of compaction/flush cycles) that most reads started hitting
filter-covered files, and `SaveReceiptsMs` settled down accordingly. Nothing else changed
in that window, which is exactly why nothing else moved. Expect a similar ramp-in period
after any change to RocksDB table options on an existing (non-empty) database — a
freshly-deployed change won't show its full effect until compaction has had time to catch
up.

## Reproducing / extending this baseline

```bash
# Same node, most recent 6 hours, matching the "settled" baseline above:
python3 fetch_prometheus_baseline.py \
  --instance rskj-miner1 --start <6h-ago RFC3339> --end <now RFC3339> \
  --step 15s --out-prefix results/miner1_<date>_settled_last6h

# Hourly trend view of any fetched CSV:
python3 hourly_trend_export.py results/<your>.csv --out results/<your>_hourly_trend.csv
```

Requires Prometheus reachable at `http://localhost:9091` (the `rsk-tools` stack) and the
target node actually running with `BlockProcessingStats.ENABLED` (default on, see
`bench/deterministic-replay/README.md`). Compare two summaries the same way
`nmt/analyze_block_breakdown.py --baseline` does for the replay harness — a manual diff of
the two `_summary.json` files is enough given there's no `--baseline` flag on
`fetch_prometheus_baseline.py` (yet; add one if this becomes a frequent comparison).

## Caveats (in addition to the non-stationarity above)

- This is one node (`miner1`), one point in its lifetime, under whatever `infinite.sh 14`
  load happened to be running. It is **not** a substitute for
  `bench/deterministic-replay/`'s controlled, code-isolated comparisons — use this to
  answer "does this look healthy on a real node," not "did this specific change help,"
  since load, database size/compaction state, and contention from other containers all
  vary independently of any code change.
- `rsk_block_*` gauges are sample-on-scrape (last value at each 15s tick), not aggregated
  over the interval — a burst of blocks between two scrapes only shows its last block, not
  a mean or max of the burst. Fine for trend-watching over hours, not for precise per-block
  accounting (use `nmt/analyze_block_breakdown.py` against `block-breakdown.log` for that).
- Whether `rskj-miner2`/`rskj-miner3` were running alongside `miner1` materially changes
  every number here (see `bench/deterministic-replay/README.md`'s live-mining sections) —
  this particular baseline was captured with `miner2`/`miner3` stopped for most of the
  window; check `docker ps` history/your own notes before comparing a future run that had
  a different set of containers running.
