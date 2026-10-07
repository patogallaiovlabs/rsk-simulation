# Spec — eliminate the periodic flush peak in block processing

**Goal.** Remove the periodic stall that `BlockChainFlusher` imposes on the block-processing
thread, so `onBestBlockMs` p95 falls to approximately its p50 (currently 0 ms) instead of
sitting 6–9× above the mean.

**Repo.** `repos/rskj`. Current tip `392ae5506` (branch `block-processing-perf`) is the **baseline for
this work** — the async-datasource and concurrent-flush changes are already in it.

---

## 1. Current state — what has already been done

Two changes landed between `47a2eb63a` and `392ae5506`:

- `35d600ebd` — `DataSourceWithCache` gained `asyncFlushEnabled`. `flush()` enqueues a
  `PendingBatch` onto a single background writer rather than writing inline. Four of the
  five stores are wired async in `RskContext` (blooms `:1382`, receipts `:1462`, states
  `:1507`, stateRoots `:1535`). Queue depth is capped at 4
  (`datasourcewithcache.asyncFlush.maxQueueDepth`); a `pendingFlushIndex` closes the
  stale-read window where a key evicted from `committedCache` but still only in the pending
  queue would fall through to `base.get()`.
- `2a38446c3` — `BlockChainFlusher.flushAll()` runs the five store flushes on a 5-thread
  pool via `CompletableFuture`.

Measured effect (cloud track, median across cycles): mainnet `onBestBlockMs` p95 144 → 60 ms,
blockfiller 103 → 59 ms. **The peak halved. It did not disappear.**

## 2. Why the peak survives — three causes, all must be addressed

**(a) `flushAll()` joins.** `CompletableFuture.allOf(...).join()` blocks the calling thread
until all five stores finish.

**(b) The caller is the block-processing thread.**
`CompositeEthereumListener.scheduleListenerCallbacks` is, despite its name, **synchronous** —
it iterates listeners and invokes them inline. So
`onBestBlock` → `BlockChainFlusher.flush()` → `flushAll()` → `join()` all runs on the thread
that processes blocks.

**(c) `blockStore` flushes synchronously *and under the store's own monitor*.** This is the
one that makes a naive fix useless:

```java
// IndexedBlockStore.java:187
public synchronized void flush() {
    index.flush();      // MapDBBlocksIndex.flush() -> indexDB.commit()
    blocks.flush();
}
```

`IndexedBlockStore` is not backed by an async `DataSourceWithCache`, so this is a real
synchronous commit — and it is `synchronized` on the **same monitor as every `saveBlock` and
every block lookup on that store**. Simply moving `flushAll()` onto a background thread
relocates the stall from "block thread waits on `join()`" to "block thread waits to enter a
`synchronized` method". **Threading changes alone will not remove the peak.**

There is also a fourth, intentional stall path: once the async queue hits its cap of 4, the
enqueuing thread blocks by design to throttle producers to DB write throughput. That one is
correct behaviour under sustained overload and should be preserved, not removed — but it must
not be reachable during normal operation.

## 3. Required approach

Address (a), (b) and (c). A change that fixes only (a) and (b) will measure as no improvement,
and that outcome is a signal the lock was not addressed — not a signal the idea failed.

**Suggested shape** (deviate if you find something better, but justify it):

1. **A single dedicated flusher thread with coalescing.** `flush()` signals a background
   flusher and returns immediately. If a flush is requested while one is running, set a dirty
   flag rather than queueing — flushes must coalesce, never accumulate.
2. **Bounded back-pressure.** If the flusher falls more than a configurable number of flush
   intervals behind, the caller blocks. Unbounded deferral is an OOM path. Follow the pattern
   and reasoning already in `DataSourceWithCache` (`MAX_PENDING_FLUSH_BATCHES`).
3. **Decouple `IndexedBlockStore`'s flush from its access monitor.** Options to evaluate:
   back `blocks` with an async `DataSourceWithCache` like the other four stores; narrow the
   `synchronized` scope so the durable commit happens outside the monitor; or give the index a
   separate lock from block reads/writes. Whichever is chosen, block reads must not be able to
   miss a block that has been saved but not yet committed — the same invariant
   `pendingFlushIndex` provides for `DataSourceWithCache`.

## 4. Correctness constraints — non-negotiable

- **`forceFlush()` stays synchronous.** It backs the `rsk_flush` RPC; callers expect data on
  disk when it returns. It must wait for any in-flight flush *and* the one it triggers.
- **`stop()` must not lose data.** It currently calls `flushAll()` inline. It must now drain:
  wait for in-flight work, perform a final flush, then shut the executor down.
- **No stale or missing reads, ever.** A block, receipt, state node or state root that has
  been written must be readable immediately, whether or not it has reached disk. This is the
  invariant most likely to be broken by this change and the one least likely to show up in a
  short test.
- **Background failures must surface.** `DataSourceWithCache` keeps an `asyncFlushFailure`
  `AtomicReference` for this reason. A flush that fails silently on a background thread is
  data loss presented as success. Follow the same pattern; do not swallow.
- **Crash consistency.** Cross-store flush ordering is *already* unguaranteed (they run
  concurrently today), but full asynchrony widens the window. Read `5a2bfa291` ("Mitigated db
  inconsistency issue after improper node shutdown") before changing anything here, and state
  explicitly in your report whether the window widened and why that is acceptable.
- **No consensus change.** Nothing in this work may alter block validity, execution results,
  or state roots.

## 5. Acceptance criteria

Primary, from instrumentation that already exists — no new metrics needed:

- **`onBestBlockMs` p95 approaches its p50.** Today p50 is 0 ms and p95 is 40–60 ms on the tip
  build. Target: p95 within single-digit ms. The `p95/mean` ratio (currently 6–9×) collapsing
  toward 1 is the signal that the periodic spike is gone.
- **`totalMs` p95 improves**, most visibly on light workloads where flush is a large share:
  `storagereads` (`onBestBlockMs` is ~40% of `totalMs`) and `indexer` (~13%).
- **No regression in `totalMs` mean** on any scenario.

Secondary:

- Node survives `kill -9` under sustained load and restarts to a consistent chain at the
  expected height. Run this more than once; it is the test that catches the constraint in §4.
- Sustained load does not grow heap without bound — confirm the back-pressure path engages
  rather than the queue growing.

## 6. How to measure

Use the existing harness; do not build a new one.

- A/B `392ae5506` (baseline) against your branch (tip), **≥6 cycles** — a unanimous sign test
  cannot reach p<0.05 below six.
- Both tracks: `scripts/local-sequence.sh` for local, the counterbalanced crossover for cloud.
- **Run at two flush intervals.** The sim uses `FLUSH_BLOCKS=10`; `reference.conf` defaults to
  **1000**. At 10, flushes are 100× more frequent than default, which amplifies the mean and
  makes the effect easy to see; at 1000 the spike is rarer but each one is larger. Report both
  — a fix that only works at one interval is not a fix.
- Scenarios: at minimum `storagereads` and `indexer` (largest flush share of `totalMs`), plus
  `mainnet` as the reference and `blockfiller` as the write-heavy case.
- Collected results must record the threshold; `results/report-pack/` conventions apply, and
  `runs.csv` needs `threshold == 0.9` filtering before aggregation.

## 7. Report back

- The three causes: which you addressed and how.
- Before/after `onBestBlockMs` mean, p50, p95 and p95/mean per scenario, at both flush intervals.
- Whether the crash-consistency window widened, and the argument that it is acceptable.
- Anything you found that contradicts this spec. §2(c) in particular is read from the code,
  not from a profile — if a profile disagrees, trust the profile and say so.
