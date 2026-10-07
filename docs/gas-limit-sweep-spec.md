# Gas-limit sweep — run spec

Goal: one curve per scenario, block processing time vs gas limit, on the **mitigated
build only**. This is not a build A/B — the build is held constant and the gas limit is
the variable.

Feeds §3.1 and §3.2 of `reports/DRAFT-25M-feasibility.md`.

## Matrix

| axis | values |
|---|---|
| gas limit | 7M, 10M, 17M, 25M (no 6.8M genesis exists; 7M is the stand-in — say so) |
| scenario | mainnet-sim (14), calldata (11), indexer (16), ecdsa (7) |
| cycles | 6 per cell (a unanimous sign test cannot reach p<0.05 below 6) |
| duration | 30 min per run |

Full matrix is 4 x 4 x 6 = 96 runs ~= 48 h. If that is too long, cut scenarios before
cutting cycles: **mainnet-sim + indexer at 6 cycles beats four scenarios at 3.**

## The trap that invalidates the whole sweep

**Load must be scaled with the gas limit.** A k6 option tuned to saturate a 7M block
fills roughly a quarter of a 25M block. Comparing a full 7M block against a quarter-full
25M block measures the load generator, not the node — and it will produce a
believable-looking flat curve.

Before every cell, verify saturation and record it:

- target: mean gas utilization >= 0.90 at every gas limit
- if a scenario cannot reach 0.90 at 25M, raise VUs / tx count until it does
- if it still cannot, **the cell is not comparable** — record the utilization actually
  reached and exclude the cell from the curve rather than plotting it

Utilization per cell goes in the results JSON next to the timings. A cell without a
recorded utilization is unusable.

## Per gas limit, before the first run

Gas limit and genesis must change together, and the chain must be rebuilt:

```
BLOCK_GAS_LIMIT=25000000
GENESIS_FILE=/var/lib/rsk/genesis/genesis_25M.json
```

- A seeded database built at one gas limit **cannot** be reused at another — different
  chain, different state size. Start each gas limit from a fresh chain, and seed it to a
  comparable height before measuring.
- Confirm the limit actually took effect by reading the gas limit off a mined block, not
  by trusting the env var.

## What to record per run

- per-block: `totalMs`, `executeMs`, `txExecutionMs`, `statePersistMs`, `saveReceiptsMs`
- distribution, not just the mean: **p50, p95 and max** for `totalMs` (the tail is Gate B
  of the report — a mean alone cannot answer it)
- mean gas utilization, qualifying block count, gas limit, build commit
- block height range covered

## Output

One row per (scenario, gas limit, cycle) in the same shape the report pack already
consumes, so `scripts/build_report_pack.py` picks it up without a code change.

Report back: the curve per scenario, whether it is linear or super-linear, and at which
gas limit p95 crosses a meaningful fraction of the block interval.
