# `47a2eb63a` vs `392ae5506` — deterministic replay, 6 runs per arm

**This supersedes every earlier comparison of these builds.** Prior results in
`results/boton/` were measured with live mining across two cloud boxes and are either
withdrawn or unresolvable; see `results/boton/ROOT-CAUSE-region-asymmetry.md`.

## Method

`bench/deterministic-replay/run_replay_1159.sh` — identical seed database, identical
1,158-block sequence replayed through `ConnectBlocks` (the full `tryToConnect` pipeline),
1,027 blocks qualifying at ≥90 % gas. Six runs per arm, arms alternated so any time drift
spreads evenly. Same machine (Apple Silicon, arm64), same lean logback on both arms so
neither pays for DEBUG records the other lacks.

Analysis is **paired**: replay feeds both builds the same blocks, so block *N* is directly
comparable across arms. Each arm is reduced to a per-block median across its six runs,
then compared block by block. The decision statistic is a **sign test** on the share of
blocks that improved — not the interquartile range, which stays wide even for a real
effect because blocks genuinely differ from one another.

## Noise floor — measure this before believing any effect

Same build, six runs, spread of the per-run p50:

| metric | baseline spread | tip spread |
|---|---|---|
| totalMs | 6 ms (**12 %**) | 7 ms (**14 %**) |
| executeMs | 3 ms (11 %) | 3 ms (11 %) |
| txExecutionMs | 1 ms (6 %) | 2 ms (12 %) |
| statePersistMs | 1 ms (10 %) | 1 ms (11 %) |

**Any single-run difference below ~12 % is noise.** Deterministic input does not give
deterministic timing — JIT compilation order, GC and host scheduling still move things.
This is why the paired sign test, not a run-to-run delta, is the instrument.

## Result

| metric | baseline | tip | median Δ | blocks improved | sign test |
|---|---|---|---|---|---|
| **statePersistMs** | 10.0 | 9.5 | **−5.9 %** | 706/831 (85 %) | z=20.1 **resolved** |
| **saveReceiptsMs** | 1.0 | 1.0 | 0.0 % | 505/549 (92 %) | z=19.6 **resolved** |
| executeMs | 27.0 | 26.5 | −1.7 % | 547/924 (59 %) | z=5.6 resolved |
| **txExecutionMs** | 16.0 | 16.5 | **+2.7 %** | 347/876 (40 %) | z=6.1 **resolved, worse** |
| totalMs | 50.5 | 50.5 | −1.0 % | 531/983 (54 %) | z=2.5 not resolved |

### Reading it

- **State persistence is the clear win**: ~6 % faster, improving on 85 % of blocks.
- **Receipt saving improves on 92 % of blocks**, but the median delta is 0 % because the
  values are 1–2 ms integers — the gain is real yet below millisecond resolution at this
  database size. Consistent with the separate finding that receipt-store optimizations
  need a large database to show absolute benefit.
- **Transaction execution is marginally *worse*** — +2.7 %, improving on only 40 % of
  blocks. Small, but it survives the sign test. Worth noting this is the same metric that
  read +95.7 % for two days under the broken cross-box methodology; with a sound
  instrument the honest number is about +3 %.
- **Total connect time is not resolved.** −1.0 % against a 12 % noise floor.

**Every effect here is single-digit percent.** None of the ±30–96 % figures reported
earlier in this investigation survived.

### Caveats

1. Six runs per arm. The 5-run intermediate gave `totalMs` −2.6 % "resolved" and
   `txExecutionMs` 0.0 % "weak"; the sixth run moved both. Small effects near the
   resolution limit remain unstable — treat the two large-z results as solid and the rest
   as provisional.
2. The sign test assumes independent blocks. Neighbouring blocks share cache and JIT
   state, so the true z values are lower than printed. Directionally sound, numerically
   optimistic.
3. arm64 (Apple Silicon); Boton is amd64. The *direction* should carry; absolute
   milliseconds will not.
4. Replay exercises block connect only — no mempool, candidate building or mining. Any
   effect in those paths is invisible here.

## Reproducing

```bash
LOGBACK=$PWD/rsk/logback-lean.xml IMAGE=rskj-local:baseline SCRATCH_VOLUME=rsk-bench-cb \
  ./bench/deterministic-replay/run_replay_1159.sh cb-baseline-rN
LOGBACK=$PWD/rsk/logback-lean.xml IMAGE=rskj-local:tip SCRATCH_VOLUME=rsk-bench-cb \
  ./bench/deterministic-replay/run_replay_1159.sh cb-tip-rN

python3 bench/deterministic-replay/compare_replays.py \
  'bench/deterministic-replay/results/cb-baseline*_block-breakdown.log' \
  'bench/deterministic-replay/results/cb-tip*_block-breakdown.log'
```

`rskj-local:{baseline,tip}` are the runtime image with a verified jar swapped in
(`Dockerfile.swap`); their jars are byte-identical to the ones built from `47a2eb63a`
and `392ae5506`.
