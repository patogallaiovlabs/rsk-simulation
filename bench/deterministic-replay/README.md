# Deterministic block-replay benchmark

A reusable, reproducible way to measure RSKj block-processing time — same blocks, same
transactions, same gas, every single run, regardless of machine or which code change in
`repos/rskj` is under test. Built while investigating "optimize RSKj block processing
time" (see git history / conversation context around 2026-08-13 for the full story); this
directory is what's needed to resume that work in a new session or on a new machine.

## Why this exists (read this before re-deriving it)

Benchmarking block-processing time by running real miners + k6 load (`infinite.sh 14`)
and mining fresh blocks has three confounds that repeatedly produced misleading results:

1. **Workload randomness.** k6's `mainnet-simulation-test.js` picks a random tx mix per
   iteration, so no two runs process the same transactions, same gas, or even the same
   number of transactions per block. Comparing "before" vs "after" runs is comparing two
   different workloads, not two versions of the code.
2. **JIT-warmup asymmetry.** A JVM that's been mining for an hour has hot-compiled code
   that a freshly-started JVM does not. Two runs of different *duration* are not
   comparable even with identical code — this alone produced an apparent 40%+ "regression"
   from a genuinely neutral change (see Findings below).
3. **Environmental drift.** Across a very long session (many Docker builds, containers,
   profiling runs), host-level noise (build cache growth, disk pressure) can make later
   rounds look worse than earlier ones for reasons that have nothing to do with the code
   change being tested. We caught this by reverting to the original code and reproducing
   the same "regression" — proof it was the environment, not the diff.

The fix: stop generating new blocks. Take one fixed, already-mined sequence of blocks and
**replay it** — every round starts from the identical starting state and processes the
identical transactions in the identical order. The only thing that can differ between
rounds is the code in `repos/rskj`.

### Why replay via `ConnectBlocks`, not `ExecuteBlocks`

RSKj ships several experimental CLI tools under `co.rsk.cli.tools` (`ExportBlocks`,
`ImportBlocks`, `ConnectBlocks`, `ExecuteBlocks`, `RewindBlocks`, ...). `ExecuteBlocks`
calls `BlockExecutor.execute()` directly, bypassing `BlockChainImpl` entirely — it skips
validation, chain-switching, receipt saving, and the `onBestBlock`/flush listener. That's
too narrow: it silently drops most of what "block processing" actually means.
`ConnectBlocks` calls `blockchain.tryToConnect(block)` — the exact same entry point a
block takes whether it's self-mined or received from a peer — so it exercises the full
pipeline this project's own instrumentation measures (see `block connect breakdown`
below). Always prefer `ConnectBlocks` unless you specifically want to isolate
`BlockExecutor` from everything around it.

### Why we don't just start from a fresh genesis

The obvious approach — start a brand new node, let it create genesis, then
`ConnectBlocks` the exported chain on top — **does not work**. We measured genesis
producing a *different hash* (and even a different effective difficulty: `0x10000000` vs
`1`) across two fresh initializations that should have been identical (same
`genesis_25M.json`, same image, same config). We did not fully root-cause this — it may be
related to how `RskContext`/regtest difficulty bootstrapping interacts with the very first
block, or something else entirely. Rather than chase it, we sidestepped it: **clone the
already-correct reference chain, then `RewindBlocks --block 1` to reset the tip back to
block 1**, whose state (genesis + block 1, already known-good) is still present in the
trie store (tries are immutable/content-addressed — rewinding the block index doesn't
delete any of it). Replaying blocks 2+ with `ConnectBlocks` on top of that is 100%
reproducible because it never touches genesis construction at all.

## What's in this directory

- `seed-genesis-block1.tar.gz` (22MB) — a full RSKj data directory (`/var/lib/rsk`
  contents: RocksDB stores for `unitrie`, `stateRoots`, `blocks`, `receipts`, `blooms`,
  `wallet`, plus the MapDB block index) already rewound to block 1. This is the known-good
  starting point every replay extracts into a fresh scratch volume.
- `blocks_2_to_92.txt.gz` (1.7MB) — 91 blocks (block 2 through block 92) exported via
  `ExportBlocks`, in the `blockNumber,hash,totalDifficulty,encodedBlockHex` format
  `ConnectBlocks` expects. This is the mainnet-simulation workload: a realistic mix of
  storage-stress (random SSTORE), ERC20 transfer/approve, native transfers, and
  calldata-heavy "rollup" transactions, ~150-230 txs per block, ~60-98% of the 25M block
  gas limit once the test ramps up (roughly block 20 onward — see Known caveats).
- `run_replay.sh <label>` — does the whole cycle: extract seed → stage blocks file →
  `ConnectBlocks` → pull `block-breakdown.log` → analyze. Produces
  `results/<label>_block-breakdown.log` and `results/<label>_summary.json`.
- `results/baseline_*` — reference output from the current (bug-fixed, un-optimized)
  `repos/rskj` state. Compare new candidate changes against this.

There is also a **much larger sample** (1158 blocks, 1027 of them qualifying at ≥90% gas
utilization) for higher-confidence percentiles — see "Large sample (blocks 2-1159)" below.
It uses its own seed/blocks files and its own run script (`run_replay_1159.sh`); the small
91-block sample above is left in place unchanged for quick iteration.

## Prerequisites

- Docker running, `rsk-nodes-rskj-miner1` image built from the `repos/rskj` checkout you
  want to test: `docker compose -f docker-compose.rskj.yml build rskj-miner1` (from repo
  root). Rebuild this every time you change code in `repos/rskj`.
- Python 3 (for `nmt/analyze_block_breakdown.py`, stdlib only, no dependencies).
- The main `rsk-simulation` containers do **not** need to be running — this benchmark
  spins up its own throwaway containers via `docker run` against a scratch volume, and
  never touches the `rsk-nodes_rskj-data-miner1`/`miner2` volumes used by
  `docker-compose.rskj.yml`.

## Running a benchmark round

```bash
# 1. Make your code change in repos/rskj, then rebuild the image:
docker compose -f docker-compose.rskj.yml build rskj-miner1

# 2. Run the replay (from repo root):
./bench/deterministic-replay/run_replay.sh my_candidate_change

# 3. Compare against the baseline (or any previous round):
python3 nmt/analyze_block_breakdown.py --gas-limit 25000000 --threshold 0.5 \
  --label my_candidate_change \
  --baseline bench/deterministic-replay/results/baseline_summary.json \
  bench/deterministic-replay/results/my_candidate_change_block-breakdown.log
```

The script also prints this comparison command with the right paths filled in at the end
of its own run.

**Sanity check before trusting any result:** the script greps for
`result IMPORTED_BEST` and reports the count — it must be **91**. If it's lower, some
block failed to connect (check `results/<label>_raw.log` for `ERROR`/`Invalid state
root`/`NO_PARENT`) and the run's timing numbers are meaningless.

## Manual step-by-step (if the script needs debugging)

```bash
cd /path/to/rsk-simulation

# Fresh scratch volume from the seed archive
docker volume create rsk-bench-scratch
docker run --rm -v rsk-bench-scratch:/to alpine sh -c 'rm -rf /to/* /to/..?* /to/.[!.]* 2>/dev/null; true'
docker run --rm -v "$(pwd)/bench/deterministic-replay/seed-genesis-block1.tar.gz":/seed.tar.gz:ro \
  -v rsk-bench-scratch:/to alpine sh -c 'tar xzf /seed.tar.gz -C /to'

# Stage the blocks file
gunzip -c bench/deterministic-replay/blocks_2_to_92.txt.gz > /tmp/blocks_replay.txt
docker run --rm -v /tmp:/from:ro -v rsk-bench-scratch:/to alpine cp /from/blocks_replay.txt /to/blocks_replay.txt

# Replay through the full connect pipeline
docker run --rm \
  -v rsk-bench-scratch:/var/lib/rsk \
  -v "$(pwd)/rsk/genesis:/var/lib/rsk/genesis" \
  -v "$(pwd)/rsk/rsk.conf:/var/lib/rsk/rsk.conf" \
  -v "$(pwd)/rsk/logback.xml:/var/lib/rsk/logback.xml" \
  -e MINER_ID=1 -e IS_MINER=false -e BLOCK_GAS_LIMIT=25000000 \
  -e GENESIS_FILE=/var/lib/rsk/genesis/genesis_25M.json -e FLUSH_BLOCKS=10 \
  -e DEFAULT_JVM_OPTS="-Xms2G -Xmx4G -XX:NativeMemoryTracking=summary" \
  -e RSKJ_SYS_PROPS="-Drsk.conf.file=/var/lib/rsk/rsk.conf -Dlogging.dir=test/local-regtest/" \
  -e RSKJ_LOG_PROPS="-Dlogback.configurationFile=/var/lib/rsk/logback.xml -Dlogging.stdout=INFO -Dlogging.file=INFO -Dlogging=INFO" \
  -e RSKJ_CLASS=co.rsk.cli.tools.ConnectBlocks \
  -e RSKJ_OPTS="--regtest --file /var/lib/rsk/blocks_replay.txt" \
  rsk-nodes-rskj-miner1

# Pull the log and analyze
docker run --rm -v rsk-bench-scratch:/from:ro -v "$(pwd)/bench/deterministic-replay/results":/to alpine \
  cp /from/test/local-regtest/block-breakdown.log /to/my_label_block-breakdown.log
python3 nmt/analyze_block_breakdown.py --gas-limit 25000000 --threshold 0.5 --label my_label \
  --save-json bench/deterministic-replay/results/my_label_summary.json \
  bench/deterministic-replay/results/my_label_block-breakdown.log
```

Note: `IS_MINER=false` here isn't optional — it just avoids irrelevant mining setup for a
tool that never mines. `ConnectBlocks` itself is what does all the work.

## Fixed 2026-08-18: `onBestBlockMs` read as 0 because the periodic flush never ran

Investigating why `onBestBlockMs` (periodic flush cost) always read 0 in this harness
(regardless of sample size — 67 or 1027 qualifying blocks made no difference) found a real
bug in the harness, not a sensitivity limitation as originally guessed:

`co.rsk.cli.tools.ConnectBlocks` builds its `Blockchain`/`TrieStore`/etc. straight from
`RskContext` getters and never calls `RskContext.buildInternalServices()` — the method a
real node boot (`Start.java`) uses to start every `InternalService`, including
`BlockChainFlusher`. `BlockChainFlusher.start()` is what registers its listener on the
shared `CompositeEthereumListener` emitter; without it, the `onBestBlock()` fan-out that
normally triggers `flush()` every `flushNumberOfBlocks` blocks (10, in this harness) never
fires. The old `ConnectBlocks` instead did one manual
`blockStore.flush(); trieStore.flush(); receiptStore.flush();` after the *entire* replay
loop finished — completely different from live-mining behavior, and it also skipped
`stateRootsStore`/`blocksBloomStore` that a real flush includes.

Fixed in `repos/rskj`'s `ConnectBlocks.java`: it now calls
`ctx.getBlockChainFlusher().start()` before the loop and `.stop()` (which flushes
everything and matches node shutdown) after — so periodic flushes fire during replay just
like they do in a live node. Both baselines were re-run after rebuilding the image; the old
(broken) results are kept as `*_preflushfix_*` for reference, and `baseline_*`/
`baseline1159_*` now refer to the corrected run.

Effect on the numbers (1159-block sample, mean ms):

| metric | before fix | after fix | live mining |
|---|---|---|---|
| onBestBlockMs | 0.0 | 1.4 (p95 14.0) | 1.6 (p95 12.8) |
| switchChainMs | 0.7 | 1.5 (p95 7.0) | 0.8 (p95 2.0) |
| executeMs | 25.9 | 27.1 | 25.7 |
| txExecutionMs | 15.3 | 16.0 | 16.5 |
| statePersistMs | 10.2 | 10.6 | 8.5 |

`onBestBlockMs` now matches live mining closely. The small across-the-board bump in
`executeMs`/`statePersistMs` is expected and correct: blocks immediately following a real
flush now pay a bit more (cache repopulation after eviction), which live mining always
included and the old harness never did. **Any round measured before 2026-08-18 with this
harness is missing periodic flush cost and is not directly comparable to rounds measured
after — re-run old candidates if you need a clean comparison.**

## Running this benchmark alongside a live compose network (2026-08-19)

Normally this harness assumes the compose miners (`rskj-miner1..4`) are stopped — see
"Prerequisites" above. Asked to test a candidate *without* stopping 3 already-running
miners, here's what was tried and what was learned:

- **`docker run --cpuset-cpus` pinning the replay container to cores the miners
  weren't using made things far worse, not better** (totalMs 3.2x baseline vs 2.4x
  unpinned). Docker's `--cpuset-cpus` only restricts *your* container to a core range —
  it does nothing to keep unpinned containers (the miners) off those same cores. Pinning
  just removes your own container's ability to migrate to whatever's momentarily idle,
  without buying any real exclusivity, so it's strictly worse than not pinning at all
  unless the *other* containers are also pinned away from that range (not attempted here,
  since it would mean touching the miners' config, which defeats the point of leaving them
  alone).
- **Running unpinned (default, sharing all `docker info`-reported vCPUs with the miners)
  is the better of the two options but still ~2.4x slower than an isolated run** with 3
  miners each capped at `cpus: '2.0'` in `docker-compose.rskj.yml` actively mining.
- **A much bigger problem surfaced when comparing two builds back-to-back under this
  contention: whichever build ran *second* in a pair consistently measured faster,
  regardless of which code was in it.** Three reps run as (candidate-A first, candidate-B
  second) all showed B faster by 3-34%. A fourth rep with the order flipped
  (candidate-B first, candidate-A second) showed candidate-A — the one that lost every
  time before — win instead, by a similar margin. The gap showed up even on metrics with
  no relationship to the code difference under test (`initialValidationMs`,
  `switchChainMs`), which is the tell that it's an artifact of run order (most likely some
  form of OS/page-cache or JVM-startup warm-up from the immediately preceding container),
  not a real code effect. **Whatever this harness's absolute noise floor is when isolated
  (~10-20%, see above), it's dominated by a larger order-dependent effect once run
  alongside contending containers — large enough to fully invert a comparison's outcome.**
- **Practical takeaway:** this harness can still be run alongside a live network without
  stopping it, but a single back-to-back before/after pair is not just noisier here, it can
  be actively misleading (see above). To trust a result under these conditions: (1) alternate
  which build runs first across repeats (an ABBA design, not always A-then-B), (2) run
  enough repeats that the code effect (if real) shows up as a consistent direction across
  both orderings, not just as a bigger average, and (3) treat any effect smaller than
  roughly 20-30% as unproven unless it survives that check — which is a high bar for a
  change expected to be worth only a few percent. If you need to validate a small
  optimization with confidence, stopping the compose miners for the harness's duration
  (as in every other section of this doc) remains the more reliable option.

## Known caveats — read before drawing conclusions from a comparison

- **`initialValidationMs` is cold-cache signature-verification cost, not representative of
  steady-state mining.** `BlockChainImpl`'s `isValid(block)` calls
  `BlockTxsFieldsValidationRule`, which calls `tx.verify(signatureCache)` — full ECDSA
  recovery — for every transaction. In live mining, transactions already passed through
  the mempool (`TransactionPool` validates on submission, populating the same
  `SignatureCache`), so this is a near-free cache hit by the time a block gets connected.
  In this replay, every `ConnectBlocks` invocation is a fresh JVM with an empty
  `SignatureCache`, so **every** signature gets recovered from scratch — this inflates
  `initialValidationMs` to ~80ms (vs ~6ms in live mining) and dominates `totalMs`. This is
  a real cost (relevant to node sync speed), but a **different problem** from optimizing
  steady-state block execution. **Decision made 2026-08-13: focus optimization work on
  `executeMs` / `txExecutionMs` / `statePersistMs`, and disregard `initialValidationMs` and
  `totalMs`** unless you're specifically investigating sync/import cost. Those three
  metrics closely track the original live-mining baseline (~24-25ms / ~15-16ms / ~8ms),
  which is why they're trustworthy for this purpose despite the inflated `totalMs`.
- **`onBestBlockMs` (periodic flush cost) now tracks live mining** (fixed 2026-08-18 — see
  the dedicated section above). It used to read ~0 regardless of sample size because
  `BlockChainFlusher` was never started by `ConnectBlocks`; now it shows mean ~1.3-1.4ms /
  p95 ~12-14ms, matching live mining's ~1.6ms / ~12.8ms.
- **Blocks below ~20 are near-empty** (1-4 txs; the k6 test's ramp-up/contract-deployment
  phase) and get filtered out by `--threshold 0.5` (only ~67 of 91 blocks qualify at
  ≥50% gas utilization). This is expected and fine.
- **Absolute numbers here run somewhat slower than live mining even for the metrics we do
  trust**, likely from a combination of a smaller heap (`-Xms2G -Xmx4G` here vs the live
  node's `-Xms4G -Xmx4G`) and less JIT warmup within a single 91-block burst. Compare
  round-to-round *within this harness*, not against live-mining numbers directly.
- Every extraction is a **fresh, independent scratch volume** — rounds never contaminate
  each other, and you can run them in any order.

## Current findings (as of 2026-08-13 — check git log for anything newer)

Two real bugs were found and fixed in `repos/rskj` (uncommitted on branch `ri_fixleak` as
of this writing — check `git -C repos/rskj status`/`git -C repos/rskj diff` for current
state, this file will go stale):

1. **`MutableTrieCache.put()`** had a correctness bug: a null `put()` after
   `deleteRecursive()` could leave a stale non-null cached value if the same key was
   written and re-cleared before commit, corrupting the state root. Fixed; regression test
   added in `MutableTrieCacheTest`.
2. **`DataSourceWithCache`'s async flush** (added in a previous session, wired on for
   receipts/blooms/states/stateRoots in `RskContext`) had no queue depth cap — a real OOM
   risk under sustained load — and a stale-read window where a key evicted from the
   bounded `committedCache` while still only in the pending queue would read through to
   `base` and return a stale value. Bounded with backpressure + a pending-flush index;
   2 new tests added in `DataSourceWithCacheTest`.

Two optimization ideas were (re-)tested 2026-08-18 against the flush-fixed, 1158-block
harness and both came back **neutral** — no meaningful win, and not committed:

- **Reusing `Keccak256`/`KeccakDigest` instances via `ThreadLocal`** in `HashUtil` and
  `Keccak256Helper` instead of allocating a fresh digest per call. Profiling showed Keccak
  hashing as the largest single CPU category in genuine block-connect activity (~30%,
  once mempool-rebuild noise was filtered out), so this looked like a strong candidate.
  First tested under the (then-broken) 91-block harness: `executeMs` +4%, `txExecutionMs`
  +7%, `statePersistMs` 0% — noise, not a real effect either direction. Re-tested combined
  with the flush-parallelization idea below, against the larger 1158-block sample: see
  below, still no real effect. Best explanation: these digest objects are small and
  short-lived within a single stack frame, which HotSpot's escape analysis and TLAB
  bump-pointer allocation already handle close to optimally — `ThreadLocal` reuse trades a
  likely-already-cheap allocation for a guaranteed hash-map lookup, roughly canceling out.
  **Lesson: allocation-reduction is not automatically a win in modern HotSpot — measure,
  don't assume.**
- **Parallelizing `BlockChainFlusher.flushAll()`'s 5 sequential store-flush calls**
  (`trieStore`, `stateRootsStore`, `receiptStore`, `blockStore`, `blocksBloomStore`) via a
  small daemon-thread pool (`CompletableFuture.runAsync` + `allOf(...).join()`), since
  `blockStore` is the only one of the five not already async-enqueued and does a real
  synchronous RocksDB flush. Tested together with the Keccak change against the 1158-block
  sample, 3 repeated clean runs (see below for why repeats were needed) averaged against
  `baseline1159`: `totalMs` +6.8%, `executeMs` +3.1%, `txExecutionMs` +7.5%,
  `statePersistMs` -3.5%, `onBestBlockMs` -21% (1.1ms vs 1.4ms, but only ~103 flush events
  in 1158 blocks at `FLUSH_BLOCKS=10` — too few samples to trust a percentage on this one).
  Net: statistically indistinguishable from baseline given the run-to-run noise observed
  (see below) — not a win, not committed. Both changes are still present in the working
  tree as of this writing for reference; revert if picking a different candidate next.

A third idea was implemented 2026-08-19 (also kept in the working tree; **not reverted per
explicit instruction**) but its performance impact could not be reliably measured:

- **Caching `RskSystemProperties.getVmConfig()`** (`RskSystemProperties.java`). Found via
  code search that `TransactionExecutorFactory.newInstance()` called `config.getVmConfig()`
  fresh on every single transaction (both the sequential and parallel execution paths),
  and `getVmConfig()` performed 5 separate uncached `com.typesafe.config` tree traversals
  (`vm.structured.trace`, `vm.structured.traceOptions`, `vm.structured.initStorageLimit`,
  `dump.block`, `dump.style`) — none of which can change without a JVM restart. Fixed by
  memoizing the result in a field, same lazy-init pattern already used elsewhere in the
  class for `getActivationConfig()`/`getNetworkConstants()`. Targeted tests
  (`RskSystemPropertiesTest`, `BlockExecutorTest`) pass. **Performance impact: not
  reliably measured** — this was tested while 3 compose miners were left running per
  explicit request (see "Running this benchmark alongside a live compose network" above),
  and the order-dependent artifact discovered there was large enough to make the
  before/after comparison untrustworthy (an apparent 20%+ win reversed direction when the
  run order was flipped). Given the fix only removes a handful of nanosecond-scale
  Config-tree lookups per transaction, its real effect is expected to be small (likely
  low-single-digit percent on `txExecutionMs` at most) — plausible and safe, but currently
  unproven. Kept in the working tree since it's a correct, low-risk simplification
  regardless; revalidate with the miners stopped if a confirmed number is needed.

A fourth idea, found via `jfr` analysis of an old CPU-sampling profile
(`round0/profile2.jfr`) rather than blind code search, **is a confirmed small win**:

- **Removing a literal duplicate `tx.transactionCost(...)` call** in
  `TransactionExecutor.go()` (`TransactionExecutor.java`). `nonZeroDataBytes()` — which
  `transactionCost()` calls to compute intrinsic gas — scans the transaction's entire
  calldata and showed up as the 5th-hottest method in the CPU profile (214 samples), high
  enough to investigate given this benchmark's workload leans on calldata-heavy "rollup"
  transactions. Root cause: `TransactionExecutor.init()` already computes this exact value
  once and stores it in the `basicTxCost` field (used correctly everywhere else in the
  class), but `go()` recomputed it from scratch via a second identical call
  (`tx.transactionCost(constants, activations, signatureCache)`, same tx, same immutable
  fields, nothing in between that could change the inputs) instead of reusing
  `basicTxCost`. Fixed by replacing the redundant call with the field. Targeted tests
  (`co.rsk.core.bc.transactionexecutor.TransactionExecutorTest`, `TransactionTest`,
  `BlockExecutorTest`) pass. **Measured** with the compose miners stopped (clean
  environment), 2 runs with the before/after order flipped between them (no order-effect
  pattern observed this time — good sign the environment really was clean):
  `executeMs` -1.8%, `txExecutionMs` -3.0%, `totalMs` -1.3%, `statePersistMs` ~0%. Small
  but real and directionally consistent across both orderings — a legitimate, if modest,
  win. Kept in the working tree.

- **Follow-up (scope explicitly widened to include mempool/pool validation, 2026-08-19):**
  `TxValidatorIntrinsicGasLimitValidator`, `TxPendingValidator`, and
  `TransactionPoolImpl.getTxBaseCost()` also call `transactionCost()` — initially left out of
  scope as "tx pool validation, not block processing" (see earlier decision), but revisited
  on request. Within a single `TxPendingValidator.isValid()` call, `transactionCost()` runs
  **twice** for the same tx (once directly at `TxPendingValidator.java:82` for the
  `basicTxCost`/`isFreeTx` check, again inside `TxValidatorIntrinsicGasLimitValidator.validate()`
  since the shared `TxValidatorStep` interface only passes the derived `boolean isFreeTx`, not
  the actual value) — same duplicate-call shape as the `TransactionExecutor.go()` case. Worse,
  `TransactionPoolImpl.getTxBaseCost()` calls it once **per already-queued transaction, on
  every new transaction admission from the same sender** — a tx sitting in the pool for many
  blocks gets its calldata re-scanned repeatedly, once per sibling admission, for as long as
  it's queued.
  Rather than restructure the `TxValidatorStep` interface (9 implementers, only 2 of which
  even use the existing `isFreeTx` boolean — a broader, riskier change for a path this
  harness can't validate), fixed at the root: `nonZeroDataBytes()` depends **only** on
  `this.data` (a `private final byte[]`, immutable after construction) — a pure function of
  already-immutable state, regardless of which block/activation context calls it in. Added a
  memoized field (`nonZeroDataBytesCache`, sentinel `-1`) directly on `Transaction`
  (`Transaction.java`), unsynchronized like the codebase's existing lazy-init getters — a
  benign race just recomputes the same deterministic value once more, never a correctness
  issue. This one change fixes every call site above *and* the already-fixed
  `TransactionExecutor.go()` case, without touching `transactionCost()` itself (which does
  legitimately depend on volatile per-call context — `constants`/`activations`/
  `signatureCache` — so memoizing it whole would be wrong; only the calldata-scan portion is
  safe to cache). Tests pass across all affected packages
  (`org.ethereum.core.TransactionTest`, `co.rsk.net.handler.TxPendingValidatorTest`,
  `co.rsk.net.handler.txvalidator.TxValidatorIntrinsicGasLimitValidatorTest`,
  `co.rsk.core.bc.TransactionPoolImplTest`, full `co.rsk.net.handler.*` package).
  **Not benchmarked**: `ConnectBlocks` (this harness) calls `blockchain.tryToConnect()`
  directly and never goes through the mempool at all, so there is no way to measure this
  specific improvement with the tooling in this directory — confirmed by the requester as an
  accepted tradeoff ("no easy way to prove improvement there"). Expected to help most under
  sustained mempool pressure with many queued transactions per sender (exactly
  `TransactionPoolImpl.getTxBaseCost()`'s pattern), which is closer to steady-state live
  mining than to this replay's single-shot connect pass.

**Methodological finding: even this "deterministic" harness has real run-to-run timing
noise from host contention, not just from the code under test.** The first attempt to
re-test these two candidates showed an apparent ~55-60% regression across *every* metric,
including ones with no relationship to either change (`saveReceiptsMs` alone spiked from
1.6ms to 21.6ms). Root cause: `rskj-miner1`/`rskj-miner2` had been started and were
actively mining (~120% CPU each) on the same host during that run — the "isolated"
`ConnectBlocks` container was never actually isolated from the rest of the machine, it was
competing for CPU the whole time. After stopping those containers, three repeat runs of
the *identical* candidate build still varied by ~10-20% run-to-run on `executeMs`/
`statePersistMs`/`txExecutionMs` (`saveReceiptsMs` swung 1.2-10.8ms across "clean" runs
alone) — same code, same blocks, same state, different wall-clock. **Before trusting any
single-run comparison against this harness: (1) check `docker ps` for the compose miners
and stop them, and (2) run at least 2-3 repeats and look at the spread, not just one
number** — a single run landing outside baseline by less than ~20% is not yet evidence of
a real effect either direction.

`DataSourceWithCache`'s `committedCache` (`Collections.synchronizedMap` wrapping a
`MaxSizeHashMap`/`LinkedHashMap`) was investigated as a possible lower-contention-structure
candidate and **ruled out**: that map is only ever accessed concurrently under RSKIP144
(parallel transaction execution), which this repo's `rsk/rsk.conf` explicitly disables
(`blockchain.config.consensusRules.rskip144 = -1`) — every block-breakdown log line here
has always said `pre-RSKIP144`, confirming the sequential path is what actually runs. In
that path exactly one thread ever touches `committedCache`, so there's no real contention
to relieve. A follow-up look at `MutableRepository`/`TrieKeyMapper` (also fully
`synchronized`, also only ever exercised sequentially here) found the opposite problem:
`BlockExecutor.executeParallel()` genuinely does share a single parent `Repository` track
across multiple sublist threads (each sublist's own sub-track is thread-exclusive, but a
cache-miss read falls through to the shared parent), so removing that locking would
introduce a real data race in consensus-critical code for any deployment that *does*
activate RSKIP144 — correctly identified as out of scope and not touched.

Deeper VM/trie changes remain unscoped.

## Receipts read/write optimizations (2026-08-20) — confirmed win

Found via live mining (3 miners under k6 load), not this replay harness initially: sampling
100 real connected blocks showed `saveReceiptsMs` running ~55x higher live (89ms mean) than
in this replay (1.6ms). Traced to `ReceiptStoreImplV2.saveMultiple()`'s per-transaction
`receiptsDS.get(txHash)` existence check (needed to correctly append to that tx's
block-hash index) — for this workload's overwhelmingly-novel transaction hashes, that's a
guaranteed synchronous RocksDB miss on the connect thread, ~260 times per block. Confirmed
via a live async-flush trace (added a dedicated `ASYNC-FLUSH` logback appender, see below)
that the async-flush backpressure mechanism from the earlier `DataSourceWithCache` fix was
*not* the cause — `queueDepth` never exceeded 1 across 140 observed flush events, ruling
that out directly rather than by assumption.

Three changes, all landing on `saveMultiple()`'s hot path:

1. **RocksDB bloom filter, scoped to the `receipts` table only** (`RocksDbDataSource.java`).
   No `FilterPolicy` was configured anywhere before this — meaning every "does this key
   exist" read had to consult on-disk index/data structures to conclude "not found,"
   instead of a fast in-memory probabilistic check. First attempt applied this to *every*
   RocksDB-backed table via the same shared static filter as `sharedBlockCache` — measured
   via this harness (2 flip-order runs): `saveReceiptsMs` improved ~27% as hoped, but
   `statePersistMs` regressed ~7-8%, consistently, in both reps. Root cause: a bloom filter
   isn't free on the write side (RocksDB computes and stores filter bits for every key), and
   the trie/state store doesn't have a true-negative-heavy read pattern the way receipts
   does — it paid the write cost for zero read benefit. Fixed by scoping
   `tableOptions.setFilterPolicy(...)` to only apply when `"receipts".equals(name)`.
   Re-measured (2 more flip-order runs): `saveReceiptsMs` -28.9%, `statePersistMs` **-3.8%**
   (no longer regressed), everything else flat or slightly better. Only applies to SST files
   written/compacted after the change takes effect, same non-retroactive caveat as the
   `compressionType` note elsewhere in this repo's `CLAUDE.md`.
2. **`KeyValueDataSource.multiGet()`** (new default method, batches the interface's existing
   `get()`) — implemented properly in `DataSourceWithCache` (checks committed/uncommitted/
   pending-flush caches for each key first, batches only the real misses into one
   `base.multiGet()` call) and `RocksDbDataSource` (one real `db.multiGetAsList()` call
   instead of N sequential `db.get()` calls). `ReceiptStoreImplV2.saveMultiple()` now issues
   one batched read instead of ~260 sequential ones per block.
3. **`TrieKeySlice.encode()` array-copy elimination** (`PathEncoder.java`) — unrelated to
   receipts, found by re-checking the earlier JFR profile for still-unaddressed hot spots.
   `encode()` did `Arrays.copyOfRange()` just to hand a throwaway array to
   `PathEncoder.encode()`; added an `encode(path, offset, limit)` overload reading directly
   from the shared underlying array (same bit-packing algorithm, byte-identical output).
   There was already a `// TODO(mc) avoid copying` comment marking this. **Not yet
   benchmarked in isolation** — bundled into the same image build as the receipts changes
   above, so its individual contribution isn't separated out in the numbers reported here.

All three are committed as commits 12-14 (see "Committed changes" below), tested
(`co.rsk.trie.*`, `org.ethereum.datasource.*`, `org.ethereum.db.ReceiptStoreImplTest`,
`co.rsk.db.*`, `BlockExecutorTest` — all pass except the one pre-existing, unrelated
`RocksDbDataSourceTest.getWithException()` failure that also fails on a clean `ri_fixleak`
checkout). The bloom filter and `multiGet()` were split into separate commits (12 and 13)
despite being measured together, same reasoning as commits 4/11 earlier — each is a
logically distinct, independently revertable fix even when validated as a pair; commit 12's
message carries the full before/after numbers for both, since 13's contribution wasn't
isolated from 12's.

**Methodological note:** the live-mining re-comparison after deploying the first version of
this fix was badly confounded and had to be discarded — not by CPU contention this time, but
by memory pressure. The 3 miner containers had been running for many hours under continuous
stress and were sitting at 94-99% of their 6GB limit (heap alone commits the full fixed 5GB
regardless of code), enough to swamp any signal from the change. The clean comparison that
actually produced the numbers above came from this replay harness instead — same lesson as
the CPU-contention findings earlier in this document, just a different mechanism.

## Committed changes

The changes above are split into **18 commits** on `repos/rskj`'s `ri_fixleak` branch (local
only, not pushed), one per distinct fix/candidate so each can be reviewed, reverted, or
cherry-picked independently. Hashes are current as of 2026-08-25, and the numbering is the
same one used by the per-commit sweep below and by the `results/perfsweep_*` labels.

> **Hashes move when the branch is refolded.** `ri_fixleak` has been rewritten twice — a
> squash on 2026-08-21 and a fold on 2026-08-25 — so any hash quoted *elsewhere* in this
> document may already be dead. Re-derive the list with
> `git -C repos/rskj log --oneline 47a2eb63a~1..ri_fixleak` rather than trusting a hash
> you read in prose. `master..ri_fixleak` also carries 16 older memory-leak/mining commits
> *below* commit 1; those predate this investigation and are not listed here (the newest of
> them, `83552e44b` "fix: honor the addToCache flag in `IndexedBlockStore.getBlockByHash`",
> is commit 1's parent).

| # | Commit | Subject | Files |
|---|---|---|---|
| 1 | `47a2eb63a` | feat: add block-connect timing breakdown instrumentation and JMX exposure | `ConnectBlocks.java`, `BlockChainImpl.java`, `BlockExecutor.java`, `logback.xml`, `InvalidTxMiningEvictionTest.java`, `co.rsk.metrics.BlockProcessingStats(MBean)` (+test); plus two folded-in build/correctness fixes — `rskj-core/build.gradle` + `gradle/verification-metadata.xml` (resolve `co.rsk:native` from mavenLocal, bump to `1.4.0-SNAPSHOT`) and `Constants.java` (restore the `minimumDifficulty`/`fallbackMiningDifficulty` param order) |
| 2 | `06841e483` | fix: count true-negative block lookups, drop dead per-block string building | `IndexedBlockStore.java`, `IndexedBlockStoreStats.java`, `BlockChainImpl.java` |
| 3 | `35d600ebd` | fix: bound DataSourceWithCache's async flush queue and close its stale-read window | `DataSourceWithCache.java` (+test), `RskContext.java` |
| 4 | `680fe563e` | perf: reuse per-thread Keccak digest instances instead of allocating fresh ones | `HashUtil.java`, `Keccak256Helper.java` |
| 5 | `03ad04e49` | perf: memoize RskSystemProperties.getVmConfig() | `RskSystemProperties.java` |
| 6 | `acfb136d6` | fix: stale value left in MutableTrieCache after recursive delete + re-put + clear | `MutableTrieCache.java` (+test) |
| 7 | `89d4b8c22` | perf: skip re-saving an already-saved trie, avoid unnecessary trace-string work | `TrieStoreImpl.java` |
| 8 | `36eff3fdc` | perf: batch ReceiptStoreImplV2 writes into a single updateBatch() call | `ReceiptStoreImplV2.java` (+test) |
| 9 | `d8d74bd2d` | perf: remove two redundant per-transaction re-computations in TransactionExecutor | `TransactionExecutor.java` |
| 10 | `536047aa5` | perf: memoize Transaction.nonZeroDataBytes() | `Transaction.java` |
| 11 | `2a38446c3` | perf: run BlockChainFlusher's 5 store flushes concurrently | `BlockChainFlusher.java` |
| 12 | `61a5fcd22` | perf: add RocksDB bloom filter scoped to the receipts table | `RocksDbDataSource.java` |
| 13 | `16e5ea021` | perf: add KeyValueDataSource.multiGet() and use it in receipt saving | `KeyValueDataSource.java`, `RocksDbDataSource.java`, `DataSourceWithCache.java` (+test), `ReceiptStoreImplV2.java`, `KeyValueDataSourceTest.java` |
| 14 | `c1bdf95fe` | perf: avoid array copy in TrieKeySlice.encode() | `PathEncoder.java` (+test), `TrieKeySlice.java` |
| 15 | `b16e962c6` | perf: merge ancestor and used-uncles walks into a single chain traversal | `FamilyUtils.java`, `BlockUnclesValidationRule.java` |
| 16 | `956f5f5f8` | perf: only populate the block caches on an actual store load | `IndexedBlockStore.java` |
| 17 | `697ac822e` | perf: extend the RocksDB bloom filter to the blocks store | `RocksDbDataSource.java` |
| 18 | `b4a13038d` | feat: expose the preamble, post-execute-validation and process-best timings | `BlockChainImpl.java`, `BlockProcessingStats(MBean)` (+test) |

What each commit is, and what it's worth:

- **1-2** — instrumentation and lookup accounting that this benchmark itself depends on.
  Commit 1 originally landed as two commits (the log-line breakdown and its live
  JMX/Prometheus exposure), squashed on 2026-08-21 since they're one feature with no
  meaningful boundary; on 2026-08-25 the native-crypto build wiring and the `Constants`
  param-order fix were folded in too, so that **every image built from commit 1 onward is
  consistent** (native secp256k1/altbn128 on arm64 rather than a silent Bouncy Castle
  fallback). That fold is why the "true baseline" hash moved — see below. Commit 2 also
  removes an O(n²) per-connect string build whose result was never actually logged.
- **3, 7, 8** — pre-existing fixes/dedups this work inherited.
- **4-5, 11** — candidates measured as neutral; kept as safe, tested simplifications, not
  because they moved a number.
- **6** — a correctness bug fix, not a performance candidate.
- **9** — the one confirmed small measured win (~1-3%). **10** extends the same fix to
  mempool/pool code paths this harness cannot benchmark.
- **12-13** — the confirmed `saveReceiptsMs` win (-28.9%); see "Receipts read/write
  optimizations" above for the full before/after and the global-vs-scoped bloom-filter
  finding. **17** extends the same filter to the blocks store, where
  `BlockChainImpl.tryToConnect`'s "does this block already exist" probe is a guaranteed
  miss for every new block. Deliberately an explicit allow-list rather than a global
  setting: an earlier measurement showed a filter on the trie/state stores regressed
  `statePersistMs` ~7%, since they pay the write-side cost with no true-negative read
  pattern to gain from. As with receipts, it only applies to SST files written or
  compacted after it takes effect.
- **14** — untested in isolation, bundled into the same build as 12-13.
- **15** — a real, low-risk dedup in uncle-list validation that is **unmeasurable** in both
  this harness and current live-mining metrics: it only executes when a block has a
  non-empty uncle list, and uncles essentially never occur in this environment (near-zero
  network delay, timed mining).
- **16** — drops a siblings-map recomputation (stream + `groupingBy` + `HashMap`) that ran
  on *every* `IndexedBlockStore.getBlockByHash` call, cache hits included; a profile of a
  miner under load showed ~6.8k calls per block. The `blockCache` re-put it also removes
  was a no-op for LRU ordering anyway, since `BlockCache` is access-ordered.
- **18** — closes an attribution gap rather than optimizing anything: on a node with a
  large database ~22% of `TotalMs` was unaccounted for (the sub-metrics summed to ~52ms
  against a ~68ms total), because nothing measured the work before validation starts — the
  existence probe, the `accessLock` acquisition and the parent/total-difficulty lookups.
  `PreambleMs` covers it at no extra `nanoTime()` cost. It also pushes
  `postExecuteValidationMs`/`processBestMs` to the MBean; both were already in
  `block-breakdown.log` but invisible in Grafana. Both read 0 in this replay harness, which
  cannot distinguish "genuinely free" from "not measured" — they're there for live runs,
  where the mempool isn't empty.

Each commit message states what was measured for that specific change, or why it couldn't
be, so `git log -p` on this branch doubles as a changelog of what was tried and what came
of it.

### Per-commit cumulative sweep (`scripts/replay_commit_sweep.sh`, 2026-08-25)

Every number elsewhere in this document compares two hand-picked working-tree states. To
get the whole branch measured on one axis instead, `scripts/replay_commit_sweep.sh
<from> <to> [label-prefix]` walks `repos/rskj` commit by commit and, for each one,
checks it out (detached), rebuilds `rskj-miner1`'s image, and runs the full 1158-block
`run_replay_1159.sh`. Results land as `results/<prefix>_<NN>_<shorthash>_*`, so the
numbering in the table above *is* the sweep's numbering. It stashes/restores uncommitted
changes in the submodule, restores the original branch on exit (`trap`), skips any label
that already has a `_summary.json` (so an interrupted sweep resumes by re-running it), and
does **not** use `set -e` — one commit's build failure doesn't kill the run. Progress goes
to `results/sweep_progress.log`. Expect one Gradle build plus one full replay per commit:
roughly 2-3 minutes per commit here, many hours for a large range.

```bash
./scripts/replay_commit_sweep.sh 47a2eb63a b4a13038d perfsweep
```

Run 1 (all 18 commits) is in `results/perfsweep_comparison.md` — absolute means plus
percent change vs. commit 1 for every metric. Read it with the caveats that apply, in this
order:

1. **One run per commit.** That's below the 2-3 repeats this document recommends
   everywhere else, so anything under the harness's documented ~15-20% noise band is
   unproven. Repeat sweeps (`perfsweep_run2`, `perfsweep_run3`) were running when this was
   written; compare them before treating any single-commit step as real.
2. **Use `executeMs`/`txExecutionMs`/`statePersistMs`.** `totalMs` and
   `initialValidationMs` are dominated by this harness's cold-cache signature verification
   (see "Known caveats"), so they don't speak to real block-processing changes.
3. **`onBestBlockMs`/`switchChainMs` swing wildly** between commits because they're driven
   by how many flush/reorg events happen to land in the 1158-block window (~103 flush
   events at `FLUSH_BLOCKS=10`) — small counts, not necessarily code.

Read that way, run 1 shows a monotone-ish improvement from commit 1 to commits 13-15
(`executeMs` -20.5% at 13, `statePersistMs` -26.4%, `saveReceiptsMs` -27.8%) and then a
partial give-back at 16-18 (`executeMs` -5.7% at the tip vs -20.5% at 13). Whether that
give-back is real or just single-run noise on top of a 26-31ms mean is exactly what the
repeat sweeps are for — **do not** conclude from run 1 alone that commits 16-18 regressed
anything.

### True baseline: commit 1 only (`094de32e0`, refolded on 2026-08-25 as `47a2eb63a`)

> **Superseded 2026-08-25 by the native-crypto fix — see "Re-measured with native
> crypto" immediately below.** The numbers in this section were collected on an image
> where secp256k1 fell back to Bouncy Castle on arm64 (`WARN [secp256k1] Signature
> Service native is not available`) and altbn128 failed to load. They remain valid as
> a Bouncy-Castle reference point, but must not be compared against any run made
> after the fix.

Every "before"/baseline number in this document up to 2026-08-19 was actually collected
against whatever the working tree happened to be at the time — never against a specific,
reproducible commit. To get a real fixed point, checked out commit 1 alone (at the time,
`git checkout 2f2ff25d6` in `repos/rskj` — detached HEAD; that hash died in the 2026-08-21
squash and became `094de32e0`, which in turn was superseded by the 2026-08-25 fold —
**commit 1 on `ri_fixleak` is now `47a2eb63a`**, and `094de32e0` survives only as the base
of the `commit1-native` branch, which is what the runs in this section and the next were
built from), which has *only* the replay instrumentation/`ConnectBlocks` flush fix and none
of commits 2-18 (no bug fixes, no dedup optimizations, no candidates), rebuilt the image,
and replayed the 1159-block sample twice:

| metric | r1 mean | r2 mean | avg mean | r1 p50 | r2 p50 |
|---|---|---|---|---|---|
| totalMs | 126.1 | 125.5 | 125.8 | 119.0 | 122.0 |
| executeMs | 25.8 | 26.7 | 26.2 | 25.0 | 26.0 |
| initialValidationMs | 87.5 | 88.4 | 88.0 | 83.0 | 87.0 |
| txExecutionMs | 14.9 | 15.4 | 15.1 | 14.0 | 15.0 |
| statePersistMs | 10.3 | 10.8 | 10.6 | 10.0 | 10.0 |
| saveReceiptsMs | 4.1 | 2.3 | 3.2 | 2.0 | 2.0 |
| onBestBlockMs | 4.3 | 4.2 | 4.2 | 0.0 | 0.0 |
| switchChainMs | 1.4 | 1.1 | 1.3 | 1.0 | 1.0 |

Both reps landed within ~1-2% of each other (1027 qualifying blocks both times) — saved as
`results/commit1_baseline_r{1,2}_summary.json`. `trie_cache_commit`/`trie_cache_save`/
`trie_store_save` global metrics don't exist in this run at all (correctly — that logging
was added together with commits 6 and 7, which aren't present at commit 1).

### Re-measured with native crypto (2026-08-25)

Same commit, same 1158-block sample, same methodology (load stopped, all compose
miners stopped), same qualifying set (1027 blocks, mean utilization 98.2%). The only
difference is that `co.rsk:native:1.4.0-SNAPSHOT` now provides `Linux/aarch64`
secp256k1 and a genuine aarch64 altbn128, so RSKj uses native crypto instead of
falling back to Bouncy Castle. Image: `rskj-baseline:commit1` rebuilt from branch
`commit1-native` (= `094de32e0` + the mavenLocal/native-wiring commit + the `Constants`
param-order fix — both of which were later folded into commit 1 itself, `47a2eb63a`, so
the current commit 1 and `commit1-native`'s tip are content-equivalent).

| metric | BC r1 | BC r2 | BC avg | native r1 | native r2 | native avg | delta |
|---|---|---|---|---|---|---|---|
| totalMs | 126.1 | 125.5 | 125.8 | 58.9 | 54.6 | **56.7** | **-54.9%** |
| initialValidationMs | 87.5 | 88.4 | 88.0 | 18.6 | 16.6 | **17.6** | **-80.0%** |
| executeMs | 25.8 | 26.7 | 26.2 | 28.8 | 27.5 | 28.2 | +7.3% |
| txExecutionMs | 14.9 | 15.4 | 15.1 | 17.6 | 16.3 | 16.9 | +11.8% |
| statePersistMs | 10.3 | 10.8 | 10.6 | 10.7 | 10.7 | 10.7 | +1.5% |
| saveReceiptsMs | 4.1 | 2.3 | 3.2 | 1.4 | 1.6 | 1.5 | -52.7% |
| onBestBlockMs | 4.3 | 4.2 | 4.2 | 5.2 | 4.7 | 5.0 | +16.5% |
| switchChainMs | 1.4 | 1.1 | 1.3 | 2.0 | 1.3 | 1.6 | +30.3% |

Results: `results/commit1_native_r{1,2}_summary.json`.

**Reading this correctly:**

- `initialValidationMs` -80% is the real, expected effect and lands exactly where
  predicted. Per "Known caveats" above, that metric *is* cold-cache signature
  verification — `BlockChainImpl.isValid(block)` re-verifies every transaction
  signature — so it is precisely what routing ECRECOVER through native secp256k1
  instead of Bouncy Castle changes. It was 70% of `totalMs` at this commit, which is
  why `totalMs` more than halves.
- **This inflates every historical "before" number in this document**, not just this
  section. Any optimization measured against a Bouncy-Castle baseline was competing
  against an 88ms signature-verification cost that no longer exists, so previously
  reported *percentage* deltas on `totalMs` are now understated relative to the real
  ~57ms block. Per-metric deltas that never touched `initialValidationMs` are
  unaffected.
- The small regressions (`executeMs` +7%, `txExecutionMs` +12%, `switchChainMs` +30%)
  are **not** established as real. They are well inside the noise this harness is
  documented to have, and `switchChainMs`'s absolute change is 0.3ms on a p50 of 0.
  Per the contention guidance above, treat anything under ~20-30% as unproven without
  ABBA-ordered repeats. No attempt was made to attribute them.

**Comparing this against `baseline1159`** (commits 1+3+6+7+8 — i.e. + the two bug fixes and
the two pre-existing dedup optimizations, still without any of 4/5/9/10/11) isolates what
those four combined changes are worth: `totalMs` p50 -0.8%, `executeMs` p50 0%,
`txExecutionMs` p50 -6.2%, `statePersistMs` p50 0% — all within this harness's established
noise band, so no clear win *or* regression is visible from commits 3+6+7+8 together on
this workload. That's a legitimate result, not a null result: the two bug fixes
(`MutableTrieCache`, `DataSourceWithCache`) were about correctness/OOM-safety, not speed, and
the two dedup optimizations (`TrieStoreImpl`, `ReceiptStoreImplV2`) may simply be small
enough on this particular 1158-block workload to not clear the noise floor.

**Important caveat for comparing this baseline against the candidate results elsewhere in
this document:** the `txcost_before/after`, `vmconfig_before/after`, and
`keccak_flushpar_*` result sets were all measured as *incremental* deltas against
progressively later working-tree states (e.g. `txcost_before` already included Keccak reuse
+ flush-parallelization + VmConfig caching baked in) — never against this literal commit-1
point. Their reported percentage deltas remain valid (each isolates exactly the one change
named), but their *absolute* millisecond values are not directly comparable to this
commit-1 baseline's absolute values without accounting for everything cumulatively included
at that point. Use this section when you want a stable, reproducible, git-pinned reference
to check out and re-run from scratch; use the per-candidate before/after pairs elsewhere in
this doc when you want a specific change's isolated effect.

## Large sample (blocks 2-1159)

Built 2026-08-13 on explicit request for a statistically stronger sample: **1000+ blocks
at ≥90% gas utilization** (vs. the original 91-block sample, of which only ~46-67 blocks
qualified depending on threshold).

- `seed-genesis-block1-1159.tar.gz` (439MB) — genesis+block1 seed for this chain, same
  construction as the small sample (clone → `RewindBlocks --block 1` → truncate logs →
  strip mount-point stubs → `tar czf`). **Much larger than the 22MB small-sample seed**
  even though it's logically still just genesis+block1: this chain ran under real
  `infinite.sh 14` load for 1159 blocks before being rewound, so RocksDB's SST files still
  contain the (now-unreferenced) trie nodes written during blocks 2-1159 — the unitrie is
  content-addressed/immutable, so rewinding the block index doesn't touch existing SST
  data, and RocksDB doesn't reclaim it without a manual compaction. This is harmless for
  replay determinism (extra inert data, not stale/live data) but means this seed is not a
  minimal genesis+block1 image the way the small one is.
- `blocks_2_to_1159.txt.gz` (31MB compressed from 2.08GB raw) — 1158 blocks (2 through
  1159) exported via `ExportBlocks`, same `mainnet-simulation-test.js` (k6 option 14)
  workload as the small sample, just run for much longer (~2.4h of stress, monitored via a
  qualifying-block counter that accounted for logback's `block-breakdown.log` rotating at
  100MB partway through the run).
- `run_replay_1159.sh <label>` — same shape as `run_replay.sh`, pointed at these files,
  using its own scratch volume (`rsk-bench-scratch-1159`) so it never collides with the
  small-sample script. Analysis defaults to `--threshold 0.9` (matching how this sample was
  sized) instead of the small sample's `0.5`. Also pulls any rotated
  `block-breakdown-*.log.gz` archives, not just the active log, since a run of this size
  can exceed the 100MB rotation threshold.
- **Sanity check:** `result IMPORTED_BEST` count must be **1158**.
- `results/baseline1159_*` — reference output from the current (bug-fixed, un-optimized)
  `repos/rskj` state, verified 2026-08-13: **1027 qualifying blocks** (98.2% mean gas
  utilization). Key percentiles (mean/p50/p95 ms):

  | metric | mean | p50 | p95 |
  |---|---|---|---|
  | totalMs | 118.5 | 117.0 | 147.0 |
  | executeMs | 25.9 | 26.0 | 33.0 |
  | initialValidationMs | 87.7 | 86.0 | 110.0 |
  | txExecutionMs | 15.3 | 15.0 | 20.0 |
  | statePersistMs | 10.2 | 10.0 | 14.0 |
  | saveReceiptsMs | 1.5 | 1.0 | 3.0 |

  These closely track the small-sample baseline (`executeMs` p50 24 vs 26,
  `txExecutionMs` p50 15-16 vs 15, `statePersistMs` p50 8 vs 10) — consistent with the
  small sample's numbers being real signal and not a small-N artifact, now with ~15-20x
  more qualifying blocks behind the percentiles. All caveats in "Known caveats" above
  (especially the `initialValidationMs` cold-cache one) apply equally here.

## Regenerating or extending the seed data

If you need a different/larger workload:

1. Start miners fresh (`docker compose -f docker-compose.rskj.yml down -v && up -d`,
   default profile = miner1 + miner2 only).
2. Run the stress test: `cd repos/rskj-k6-tests && ./infinite.sh 14` (mainnet-sim; see
   root `CLAUDE.md` for other options). Let it build up as many blocks as you want —
   watch `docker exec rskj-miner1 grep -c "block connect breakdown best:"
   test/local-regtest/block-breakdown.log` (requires the debug loggers enabled in
   `rsk/logback.xml`, see root `CLAUDE.md`).
3. Stop the load, then `docker stop rskj-miner1 rskj-miner2` (don't wipe the volume).
4. Export the new range and rebuild the seed archive using the same
   clone → `RewindBlocks --block 1` → truncate logs → `tar czf` sequence documented above
   (see the manual steps, substituting `ExportBlocks --fromBlock <N> --toBlock <M>` for
   whatever range you want, and rewinding the *reference* clone to block 1 same as
   before). Re-export starting from block 2 (block 1 must come from the rewound-to-1
   state, not be re-included in the exported file) unless you deliberately want a
   different starting point.

## Live metrics in Grafana (2026-08-20)

The same per-block timing breakdown used throughout this investigation is now also
available as live JMX gauges on the compose miners (`rskj-miner1..4`), not just as
log lines you have to parse — no debug logging needs to be enabled for this; see
`co.rsk.metrics.BlockProcessingStats` in `repos/rskj` and the `rsk_block_*` rule added to
`rsk/jmx_exporter_config.yaml`. Each gauge reflects the most recently connected block
(sample-on-scrape, same semantics as JVM/GC JMX metrics) and is already flowing through the
existing pipeline: JVM MBean → JMX-Prometheus javaagent (port 8080 in-container, 9501-9504
on the host for miner1-4) → Prometheus (`rsk-tools` stack, already scraping those ports) →
Grafana (`http://localhost:3002`).

Metric names (Prometheus): `rsk_block_BlockNumber`, `rsk_block_GasUsed`,
`rsk_block_TxCount`, `rsk_block_TotalMs`, `rsk_block_InitialValidationMs`,
`rsk_block_ExecuteMs`, `rsk_block_TxExecutionMs`, `rsk_block_StatePersistMs`,
`rsk_block_StateRootRegisterMs`, `rsk_block_SaveReceiptsMs`, `rsk_block_OnBestBlockMs`,
`rsk_block_OnBlockMs`, `rsk_block_SwitchChainMs` — exactly the metrics compared throughout
this document, minus the parallel-execution-only ones (`parallelCompletionMs`, `mergeMs`,
etc.), which aren't wired since RSKIP144 is disabled in this environment (see "Remaining
bottlenecks" in the root `CLAUDE.md`).

Each series is per-instance, labeled by `instance`/`name` (e.g. `rskj-miner1:8080`), so a
Grafana panel comparing nodes just needs one query per metric with no `instance` filter,
e.g. `rsk_block_ExecuteMs` (all miners) or `rsk_block_ExecuteMs{name="rskj-miner1"}` (one
node). Since these are instantaneous gauges sampled once per Prometheus scrape interval —
not aggregated over the interval — a busy chain with sub-scrape-interval block times will
alias/skip some blocks in the graph; lower `docker-compose.tools.yml`'s scrape interval for
this job if you need closer to every-block resolution, or use log-based analysis
(`nmt/analyze_block_breakdown.py`) instead for exhaustive per-block coverage.

Disable if needed with `-Dblockprocessingstats.enabled=false` in a service's
`RSKJ_SYS_PROPS` (also skips the underlying `System.nanoTime()` captures entirely, not just
the MBean updates — though that cost is a handful of nanoTime() calls per block, negligible
next to a block taking tens of milliseconds).

## Live-mining vs. replay: where the residual gap actually is (2026-08-21)

With `rskj-miner2`/`rskj-miner3` stopped (removing the inter-miner CPU/disk contention
documented earlier in this doc) and `miner1` left running alone under `infinite.sh 14`
load, its `rsk_block_*` gauges can be compared directly against the latest replay
(`receipts_v2`, i.e. with the bloom filter + `multiGet` + `PathEncoder` fixes all in
place) metric-by-metric instead of just eyeballing database sizes:

| metric | live (miner1 alone) | replay (v2) | live − replay | ratio |
|---|---|---|---|---|
| **SaveReceiptsMs** | 41.8 | 2.3 | **+39.5** | **18.2x** |
| StatePersistMs | 12.6 | 10.6 | +2.0 | 1.19x |
| ExecuteMs | 32.8 | 29.5 | +3.3 | 1.11x |
| TxExecutionMs | 19.7 | 18.3 | +1.4 | 1.08x |
| InitialValidationMs | 8.6 | 109.5 | −100.9 | 0.08x |
| TotalMs | 107.5 | 148.5 | −41.0 | 0.72x |

The gap is not spread evenly across block processing — it is almost entirely
`SaveReceiptsMs`. `ExecuteMs`/`TxExecutionMs`/`StatePersistMs` are all within ~10-20% of
the replay (close enough to be mostly run-to-run noise). `InitialValidationMs` is *lower*
live (the already-documented warm-vs-cold `SignatureCache` effect), which is also why
`TotalMs` looks lower live overall — that inversion dominates the total and isn't a real
"live is faster" signal.

**First explanation attempted, and retracted:** a live node's RocksDB instance is ~12x
larger than the replay's seed (26GB vs 2.1GB total; receipts specifically 15x larger, 27
SST files vs 3), sharing the same fixed 256MB `sharedBlockCacheSize` — so a much smaller
fraction of the live database fits in cache. This is a real difference in the two
environments, but it does **not** explain the timing gap: it predicts `SaveReceiptsMs`
should *increase* as the live database keeps growing, and measuring the actual trend over
15+ hours showed the opposite — see `bench/live-mining/README.md`'s "Known
non-stationarity" section for the full data. Retracted as the explanation; kept here as a
real (measured) environmental difference that just isn't the one driving this particular
number.

**Actual explanation, confirmed by the trend direction:** RocksDB bloom filters only apply
to SST files written or compacted *after* `setFilterPolicy(...)` takes effect — receipts'
pre-existing SST files at deploy time mostly predated the filter, and only gain it as
normal compaction naturally rewrites them over the following hours. `SaveReceiptsMs` is
the *only* `rsk_block_*` metric that moved during that window (dropping from ~40ms to
~13ms as more of the table gained the filter); everything else the fix didn't touch stayed
flat over the same 15 hours. A theory that only explains the one metric that actually
changed, and predicts the correct direction, beats one that doesn't — see
`bench/live-mining/` for the full baseline and hourly breakdown this is based on.

## Follow-up multiGet search + a non-multiGet dedup fix (2026-08-21)

With the receipts-path `multiGet` win confirmed above, searched the rest of the
block-processing path for other batchable-read opportunities. Found none live (one match
was dead code with zero callers).

Found instead a different redundancy: `BlockUnclesValidationRule.isValid()` called
`FamilyUtils.getAncestors(blockStore, block, uncleGenerationLimit)` and
`FamilyUtils.getUsedUncles(blockStore, block, uncleGenerationLimit)` as two separate calls,
each independently walking the same parent-hash chain via the `synchronized`,
cache-backed-but-not-free `BlockStore.getBlockByHash()`. Added
`FamilyUtils.getAncestorsAndUsedUncles(...)`, which computes both results in a single walk,
and wired it into `BlockUnclesValidationRule.isValid()` (commit 15 in the table above).
Existing tests (`FamilyUtilsTest`, `BlockUnclesValidationRuleTest`) pass unchanged.

**Unmeasurable here, by design of the fix's own trigger condition:** both old calls (and
the new combined one) are only reached when `!uncles.isEmpty()` — a short-circuit `&&` gate
in `isValid()`. This simulation's near-zero network delay and timed mining mean uncle
blocks essentially never occur, so this path isn't exercised by either the deterministic
replay harness or the current live-mining setup. The fix is real and safe (halves a
per-validated-block cost on mainnet, where uncles occur more often), just not something
this project's benchmarking can currently put a number on.
