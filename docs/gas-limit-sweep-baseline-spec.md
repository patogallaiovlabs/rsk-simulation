# Gas-limit sweep on the BASELINE build — run spec

Second half of a sweep already run. `docs/gas-limit-sweep-spec.md` covered the **tip**
build `392ae5506`; results are in `results/sweep/` and `results/report-pack/sweep_*.csv`.
This run repeats it on the **baseline** build `47a2eb63a`, so the two curves can be
plotted together.

## Why

Section 3 of the report describes bottlenecks found in the baseline, which the
mitigations then addressed to produce the tip. It currently has no scaling curve of its
own, because the only sweep we have is of the build that already carries the fixes. The
baseline curve gives section 3 its own evidence, and lets section 5 show what the
mitigations did to the *shape* of the curve rather than only to a single point at 25M.

The interesting question is whether the mitigations flattened the curve or shifted it
down. Those are different results with different implications for going beyond 25M.

## Matrix

| axis | values |
|---|---|
| build | `47a2eb63a` only. Do not vary it. |
| gas limit | 7M, 10M, 17M, 25M (no 6.8M genesis exists; 7M is the stand-in) |
| scenario | **ecdsa (7) and mainnet-sim (14)** |
| cycles | 6 per cell |
| duration | 30 min per run |

48 runs, roughly 24 h.

**Run only those two scenarios.** They are the two that produced clean curves on the tip
build, at 0.93 to 0.96 utilisation across all four limits. The others did not and would
waste the machine time:

- `storagereads` ran at 0.63 to 0.81 utilisation and reported *sub-linear* scaling. That
  is the load generator failing to fill larger blocks, not a property of the node. It is
  excluded from the tip curves and should not be attempted again without a retuned
  scenario.
- `calldata` reached only two gas limits, both marginal.
- `blockfiller` was clean at 7M, 10M and 17M but its 25M cell reached 0.82, so its curve
  is a lower bound. Add it only if there is spare time, and only if you can saturate 25M.

## The trap that invalidates the sweep

**Load must be scaled with the gas limit.** A k6 option tuned to saturate a 7M block
fills roughly a quarter of a 25M block, and comparing a full 7M block against a
quarter-full 25M one measures the load generator. It produces a believable flat curve,
which is exactly what happened to `storagereads` on the tip run.

Per cell: target mean utilisation >= 0.90, record what was actually reached, and mark a
cell that cannot reach it rather than plotting it. The tip run's `verdict` column
(`OK` / `MARGINAL` / `EXCLUDE-UNDERFILL`) is the right convention; keep it.

**The baseline is slower than the tip**, so a k6 option that saturated a given limit on
the tip build may behave differently here. Re-verify saturation per cell rather than
copying the tip run's settings.

## Per gas limit, before the first run

Gas limit and genesis change together, and the chain must be rebuilt:

```
BLOCK_GAS_LIMIT=25000000
GENESIS_FILE=/var/lib/rsk/genesis/genesis_25M.json
```

- A seeded database built at one gas limit **cannot** be reused at another. Start each
  gas limit from a fresh chain, seeded to a comparable height.
- Confirm the limit took effect by reading it off a mined block, not from the env var.
- Match the tip run's hardware per scenario, `us-east` for ecdsa and `us-west` for
  mainnet-sim, so the two curves are comparable. A different box makes the pair
  meaningless; boxes in different regions measured the same jar 2x apart.

## What to record

Same shape as the tip run, so `scripts/build_report_pack.py` picks it up with no code
change:

- per block: `totalMs`, `executeMs`, `txExecutionMs`, `statePersistMs`, `saveReceiptsMs`
- distribution, not just the mean: **p50, p95 and max** for `totalMs`
- mean utilisation, qualifying block count, gas limit, build commit, box
- block height range covered

## Report back

- The two curves, and the growth factor across 3.57x gas for each.
- Whether the baseline curve is **steeper** than the tip's (mitigations flattened it) or
  **parallel and higher** (mitigations shifted it down). Name which.
- Utilisation per cell, and any cell you had to mark MARGINAL or EXCLUDE-UNDERFILL.
- For reference, the tip build gave 4.46x on ecdsa (114 to 509 ms p50) and 5.74x on
  mainnet-sim (17 to 97.5 ms p50).
