# Top-up cycles for ecdsa and mainnet-sim — run spec

**Goal:** take `ecdsa` and `mainnet-sim` from 4 cycles to 7 on both tracks, so their
results become claimable instead of "direction only".

## Why

A unanimous sign test over 4 cycles reaches p=0.125 and cannot clear p<0.05 no matter how
consistent the result is. Six cycles is the minimum (p=0.031). Today 25 of the 45 pooled
results are "direction only", and two of the most striking numbers in the whole dataset
sit in that group:

- mainnet-sim `totalMs` **−49.4%** (4 cycles)
- ecdsa `saveReceiptsMs` **−97.25%** (4 cycles)

Both look like headline findings and neither can currently be quoted as one.

## What to run

| track | scenario | cycles now | add | target |
|---|---|---|---|---|
| Boton | ecdsa (opt 7) | 4 | 3 | 7 |
| Boton | mainnet-sim (opt 14) | 4 | 3 | 7 |
| local | ecdsa (opt 7) | 4 | 3 | 7 |
| local | mainnet-sim (opt 14) | 4 | 3 | 7 |

Three rather than two, so one lost cycle still leaves six. 12 cycles total, 24 arms,
30 min each, roughly 12 h per track if run back to back.

Every other scenario is already at 6 or more. Do not re-run them.

## Settings that must match the existing cycles exactly

New cycles are pooled with the old ones, so any difference in collection makes them
unusable. This has already cost us one scenario: Boton indexer cycles 1 to 3 were
collected at a 0.3 utilisation threshold and are excluded permanently, because they select
a different population of blocks and produce a phantom regression when pooled.

- **threshold 0.9**, not 0.3. Note `scripts/local-sequence.sh` still has
  `indexer:16:0.3` in its default `SCENARIOS` string; pass `SCENARIOS` explicitly.
- 30 minute runs (`DUR_MIN=30`, the default)
- same seeded database restored before every run
- same builds: baseline `47a2eb63a`, tip `392ae5506`
- Boton: counterbalanced as before, each cycle run in both directions so the instance
  term cancels. Both instances in us-east (ash-dc1).

## Where to run from

- Repo: `repos/rskj`, branch **`ri_fixleak`**, HEAD `392ae5506`. `47a2eb63a` is an
  ancestor of it, so both arms build from this branch; do not switch branches.
- `rskj-core/build.gradle` carries an **uncommitted local change** (the `mavenLocal()`
  content filter). Leave it in place. Without it dependency verification fails on
  unrelated `~/.m2` artifacts.
- A locally built `co.rsk:native:1.4.0-SNAPSHOT` must be staged into `m2/` before any
  Docker image build (`./scripts/stage_native_snapshot.sh`). It is published nowhere else.
- Do not commit, push, or change submodule refs. This is a measurement run.

## Where the output goes

Existing conventions, so `scripts/build_report_pack.py` picks them up unchanged:

- local: `results/local-ab/seq<N>-<scenario>-<arm>/`, arm being `baseline` or `tip`
- Boton: `results/boton/bseq<N>-<scenario>-<slot>/`, slot being `fwd` or `rev`

With `CYCLE_OFFSET=11` the new directories are `seq12`, `seq13`, `seq14` and `bseq12`,
`bseq13`, `bseq14`. Each must contain a `summary.json`; the harness aborts if one comes
back empty, and that abort is deliberate. An earlier overnight sequence logged "no
block-breakdown.log recovered" on every arm and kept going for ten hours, producing 24
empty results.

## Cycle numbering

Existing runs go up to `seq11` (local) and `bseq11` (Boton). Set `CYCLE_OFFSET=11` so the
new cycles land at 12, 13 and 14 instead of overwriting `seq1-*`.

```
CYCLE_OFFSET=11 SCENARIOS="mainnet:14:0.9 ecdsa:7:0.9" \
  nohup scripts/local-sequence.sh <ISO8601 deadline> > /tmp/topup.log 2>&1 &
```

## Afterwards

Regenerate the pack and confirm the four cells moved:

```
python3 scripts/build_report_pack.py
awk -F, 'NR==1 || ($2=="ecdsa" || $2=="mainnet")' results/report-pack/pooled.csv
```

Expect `cycles` to read 7 and `claimable` to read `significant` on the rows where the
direction held. A result that was unanimous at 4 and stays unanimous at 7 reaches p=0.016.

## Report back

- New cycle count and `claimable` status per scenario and metric.
- Any cycle you discarded, and why. Exclude for an identified physical cause, never for
  being inconvenient.
- Whether `mainnet-sim totalMs` and `ecdsa saveReceiptsMs` held their direction, since
  those are the two the report wants to quote.
