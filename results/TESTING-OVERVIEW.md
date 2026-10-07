# RSKj `47a2eb63a` (baseline) vs `392ae5506` (tip) — testing overview

Updated 2026-09-23 16:05 UTC. 22 commits separate the two builds.

## Infrastructure

| id | host | region / AZ | spec | status |
|---|---|---|---|---|
| **box A** | `boton-01` · 5.161.112.81 | **us-east / ash-dc1** | 2 vCPU EPYC-Milan, 8 GB, 200 G SSD | active |
| **box D** | `boton-02` · 178.156.204.38 | **us-east / ash-dc1** | 2 vCPU EPYC-Milan, 8 GB, 300 G SSD | active |
| box B | destroyed | eu-central / fsn1-dc8 | same spec | **deleted — was 2× slow** |
| box C | destroyed | eu-central / nbg1-dc3 | same spec | **deleted — also 2× slow** |
| **local** | MacBook (Apple Silicon) | — | 14 cores, 36 GB, arm64 | active |

All boxes: JDK `17.0.20.1`, k6 `2.3.0`, node `v20.20.2`, Ubuntu 22.04.5 — verified matched.

## Phase 1 — INVALID: single-direction A/B across two regions

Reference always on box A, candidate always on box B. **Cannot separate a build effect
from a box effect**, and the box effect was huge.

| run | scenario | reported | verdict |
|---|---|---|---|
| 1 | mainnet-sim, 65 h | totalMs −51 % | invalid |
| 2 | keccak, 3 h | txExecutionMs **+96 %** | invalid |
| 3 | ecdsa "control" | +3.4 % | invalid (gave false assurance) |
| 4 | indexer | −16.9 % | invalid |
| 5 | keccak lean | +95.7 % (reproduced run 2) | invalid |
| 6 | deep backlog | no data — design unsound | discarded |
| 7 | mainnet-sim clean, 1 h | −8.3 % | invalid |

Quarantined in `results/boton/_invalidated/`.

## Phase 2 — Forensics: isolating the cause

| test | result | eliminated |
|---|---|---|
| A/A, identical jars, box A vs B | 23 vs **45 ms** | the build |
| Crossover (builds swapped) | txExecutionMs **+0.0 %** | the build, confirmed |
| JDK aligned to `17.0.20.1` | still 24 vs 43 | the JVM |
| Box B destroyed → box C (eu-central) | 23 vs **47 ms** | the instance |
| MINER_ID swapped between boxes | slowness stayed with the box | our configuration |
| **Box D provisioned in us-east** | **23 vs 23 ms** | → **REGION was the cause** |

Guest-visible CPU specs are byte-identical across regions and cannot predict this.
Details: `results/boton/ROOT-CAUSE-region-asymmetry.md`.

## Phase 3 — Deterministic replay (local, fresh chain from block 1)

6 runs per arm, paired sign test over 1,027 blocks. Noise floor measured at **12–14 %**.

| metric | effect | strength |
|---|---|---|
| statePersistMs | **−5.9 %** (85 % of blocks) | resolved |
| saveReceiptsMs | improved on **92 %** of blocks, sub-ms | resolved |
| executeMs | −1.7 % | resolved, small |
| txExecutionMs | +2.7 % | resolved, small |
| totalMs | −1.0 % | **not resolved** |

`bench/deterministic-replay/results/RESULT-cb-baseline-vs-tip.md`

## Phase 4 — Seeded live mining (CURRENT)

Every run restores the same **pre-loaded 2.2 GB database** (chain at block ~1159) then
runs real k6 mining load. This is what makes the receipt path expensive enough to measure.

### 4a. Boton — counterbalanced, 3 cycles per scenario — **COMPLETE**

Each scenario run both directions (A=baseline/D=tip, then swapped), so the box term cancels.

| scenario | metric | mean Δ | spread | boxes agree | verdict |
|---|---|---|---|---|---|
| **mainnet-sim** | **saveReceiptsMs** | **−94.1 %** | [−94.5, −93.7] | yes | **solid** |
| | **totalMs** | **−48.8 %** | [−52.0, −46.7] | yes | **solid** |
| | executeMs | −6.7 % | [−9.2, −3.4] | yes | likely |
| | txExecutionMs | −0.2 % | [−1.2, +0.8] | no (±12) | no effect |
| | statePersistMs | +1.1 % | [−2.3, +2.9] | yes | no effect |
| **ecdsa** | **saveReceiptsMs** | **−96.9 %** | [−97.6, −95.9] | yes | **solid** |
| | **totalMs** | **−10.8 %** | [−11.1, −10.5] | yes | **solid** (tightest) |
| | executeMs | +0.2 % | [−0.9, +1.9] | yes | no effect |
| | txExecutionMs | +0.3 % | [−0.8, +1.8] | yes | no effect |
| **indexer** | **saveReceiptsMs** | **−93.0 %** | [−93.2, −92.7] | yes | **solid** |
| | totalMs | −65.0 % | [−70.9, −61.0] | no (±13) | directional |
| | executeMs / txExecutionMs | +18 % / +58 % | ±61 / ±69 | **no** | **discarded** |

### 4b. Local — serial A/B on one machine — **IN PROGRESS** (cycle 2 of ~3)

Both builds run back to back on the same hardware, so the box term is removed entirely.

| scenario | metric | cycle 1 | note |
|---|---|---|---|
| mainnet-sim | totalMs | −5.1 % | 101/105 blocks |
| | saveReceiptsMs | 2.0 → 0.0 ms | tiny absolute value |
| | statePersistMs | −11.1 % | opposite sign to Boton |
| | txExecutionMs | 0.0 % | agrees with Boton |
| ecdsa | totalMs | −3.6 % | 88/92 blocks |
| | txExecutionMs | −1.2 % | agrees with Boton |
| indexer | — | n=24/18 | **unusable — old config** |

## The central finding so far

**Receipt saving improves by 93–97 %, on every workload, on every cycle.** That is the
one large, repeatedly-confirmed effect of this branch.

Its *absolute* value depends entirely on how slow the storage is:

| platform | baseline saveReceiptsMs | tip | block time impact |
|---|---|---|---|
| Boton (2 vCPU, cloud SSD) | **64 ms** | 5 ms | totalMs −48.8 % |
| Local (14-core, NVMe) | **2 ms** | ~0 ms | totalMs −5.1 % |
| Replay (fresh chain) | **1–2 ms** | ~1 ms | not resolved |

Same commits, same seeded database. Fast local I/O leaves nothing to reclaim; modest
production-like hardware sees it dominate. **Transaction execution is unchanged
everywhere** (−0.2 % / +0.3 % / 0.0 %) — the metric that read +96 % for two days.

## Queued / remaining

| item | status |
|---|---|
| Local cycles 2–3 (mainnet, ecdsa, indexer) | running to 20:50 UTC |
| Indexer re-analysis at `--threshold 0.9` | after the run — raw logs are saved |
| Indexer on Boton with the retuned scenario | not yet run |
| Long-duration seeded run (DB growth over hours) | not scheduled |
| Per-commit bisect of the receipt win | not started |

## Scenario configuration notes

| scenario | opt | saturation | analysis threshold |
|---|---|---|---|
| mainnet-sim | 14 | ~98 % | 0.9 |
| ecdsa | 7 | ~99 % | 0.9 |
| keccak | 2 | 89.2 % (one huge tx/block) | **0.85** |
| indexer | 16 | was 60 % → **now 91 %** after retune | 0.9 (was 0.3) |
