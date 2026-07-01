# RSKj Native Memory OOM — Investigation Report

> Status: **in progress**. This document tracks the investigation into why RSKj
> nodes consume ever-growing *native* (non-JVM) memory under load until the OS
> kills the container. It records the problem, the diagnostic path that narrowed
> the search, the cause currently under analysis, and the plan to validate the
> theory in production.

---

## 1. The Problem

Under sustained high load, RSKj nodes are **OOM-killed** even though the JVM heap
is healthy and well below `-Xmx`.

The defining symptom is a divergence between two memory views:

- **JVM heap** (`heap_used_mb` / `heap_comm_mb`): stable. Garbage collection keeps
  it inside its configured bound. A heap dump shows nothing alarming.
- **Container resident memory** (`cgrp_total_mb`, the cgroup `memory.current`
  that actually triggers the OOM killer): grows monotonically until it hits the
  limit.

The gap between those two — what `nmt/nmt.sh` records as **`non_jvm_mb`** — is the
memory that *no JVM tool accounts for*. It is allocated by native (C/C++) code
reached through JNI, plus allocator and kernel overhead. This is the memory that
grows unbounded and eventually kills the node.

### 1.1 Observed behavior

- `rskj-node1` (6 GB cgroup limit) crashed reliably after ~40–60 h of continuous
  high-load operation. NMT showed the heap flat while **`non_jvm_mb` climbed past
  1.6 GB** before the kill.
- The crash time is **not tied to a specific gas limit**. It is a *rate-of-growth*
  problem: higher TPS and larger blocks accelerate native growth, turning a
  multi-day failure into a multi-hour one. Stress testing simply makes a latent
  production issue reproducible on a laptop timescale.
- Because the JVM never throws `OutOfMemoryError` (the heap is fine), the failure
  is a **silent SIGKILL** from the kernel, with no Java stack trace — only the
  container exit and a `oom-kill` line in the host dmesg/cgroup events.

### 1.2 Why this is hard

The memory that grows is, by definition, the memory the JVM does **not** report.
Standard tooling (heap dumps, `jmap`, GC logs) is blind to it. Native memory has
several independent consumers that all land in the same `non_jvm_mb` bucket:

- RocksDB native structures (block cache, memtables, index/filter blocks, table
  readers, open-file buffers).
- The C allocator itself (`glibc`/`jemalloc`) — retained, fragmented, or
  not-yet-returned pages.
- The Linux **page cache** for SST files (reclaimable, but counted against the
  cgroup).
- **JNI libraries** that allocate off-heap buffers per call or per thread —
  notably the native `secp256k1` signature path.

Attributing growth to the right consumer is the whole game. Sections 2–3 are that
attribution.

---

## 2. The Diagnostic Path

This section is the chronological narrative of how the search space was narrowed —
including the dead ends and partial fixes, because each one ruled out a class of
cause.

### 2.1 Make the invisible visible — enable NMT

The first move was to stop guessing. We:

1. Enabled the JVM's **Native Memory Tracking** (`-XX:NativeMemoryTracking=summary`)
   so the JVM's *own* off-heap categories (threads, code cache, GC structures,
   metaspace, internal) are itemized.
2. Built `nmt/nmt.sh` to sample, per container and per interval:
   - the authoritative `cgrp_total_mb` (cgroup `memory.current`),
   - process `rss_mb` / `cache_mb`,
   - every NMT category,
   - RocksDB JMX metrics (block cache, memtables, table readers, pending
     compaction, SST size),
   - and a derived **`non_jvm_mb`** = resident memory minus everything the JVM can
     explain.

The result confirmed the hypothesis precisely: **the JVM-attributed categories
were flat; `non_jvm_mb` was the entire growth.** The leak lives outside the JVM's
own accounting.

### 2.2 Attribute the drops, not just the growth

`non_jvm_mb` does not only rise — it also drops sharply at times. Understanding the
drops is as informative as understanding the rises, so `nmt/analyze_drop.py` was
written to correlate each drop against the extended `/proc/1/smaps_rollup` and
cgroup `memory.stat` columns (anon vs file, swap, THP, swapcached) plus the
RocksDB JMX series.

Key finding that prevented a wrong turn: most `non_jvm_mb` drops are **not** a JVM
event or an explicit flush. They are dominated by:

- **allocator purges** (`jemalloc` returning dirty/muzzy pages to the OS via
  `madvise(MADV_DONTNEED)`), and
- **kernel page-cache reclassification** (anon ↔ file cache movement).

This told us a meaningful fraction of `non_jvm_mb` is *allocator/kernel noise*, and
that the RocksDB shared block cache (a single shared LRU across all DB instances)
churns independently — so we must not naively map a `non_jvm_mb` change 1:1 to any
single native consumer.

### 2.3 Eliminate the confounds

Early cross-node comparisons were muddied by variables that had nothing to do with
the real leak. These were identified and removed so later comparisons would be
clean:

- **DB backend mismatch.** Some nodes ran LevelDB, others RocksDB. LevelDB keeps
  many `.ldb` files open and lacks RocksDB's bounded shared block cache, inflating
  native memory and FD counts for reasons unrelated to the leak. All miners were
  aligned to RocksDB.
- **Allocator not actually loaded.** The `LD_PRELOAD` path was hardcoded for x86,
  so `arm64` containers silently fell back to glibc `malloc`. Made arch-aware so
  jemalloc is genuinely active everywhere it is supposed to be.
- **x86 emulation overhead** for `amd64` images on Apple Silicon. Noted and
  controlled for.

The lesson recorded here: the original "amd64 crashes, arm64 survives" observation
was **not** an architecture result — it was three confounds stacked on top of each
other.

### 2.4 First remediation — bound the obvious native consumer (RocksDB)

Inspecting `RocksDbDataSource.createOptions()` revealed the original options set
**no explicit block cache** and left **index/filter blocks unbounded** (not pinned
into a cache). With 8+ DB instances each falling back to an implicit per-instance
default, and SST indexes growing with the chain, this was a legitimate source of
unbounded native growth.

Fixes applied:

- Introduced a **single shared, bounded LRU block cache** across all DB instances,
  with `cacheIndexAndFilterBlocks=true` so index/filter blocks live *inside* the
  bound instead of growing freely.
- Promoted the size to a tunable property
  (`database.rocksdb.sharedBlockCacheSize`) instead of a hardcoded constant, and
  lowered `maxOpenFiles` to cap table-reader native memory.
- Switched the allocator to **jemalloc** with arena/decay tuning to fight glibc
  fragmentation, and verified pages are actually returned to the OS.

**Effect:** native overhead on `node1` dropped from ~1.67 GB to ~0.95 GB and the
growth *rate* fell by ~65%. The footprint went from "climbs forever" to "reaches a
plateau."

This turned out to be the **key lever** — and the follow-up insight (Section 3) is
that it is specifically the *size* of the shared block cache that matters: pushing
`sharedBlockCacheSize` to **small** values keeps native memory negligible and the
node stable under a tight cgroup. At this stage that was not yet isolated from the
allocator and architecture changes that were applied at the same time, which is
exactly what the current tests separate. Before settling on this, two other leads
were chased down — heap-side structures (2.5) and the secp256k1 path (2.6).

### 2.5 Hunt heap-adjacent unbounded structures

Even though the *resident* growth is native, several in-process structures were
either unbounded or leaking, which inflates footprint and pressure. These were
fixed and locked down with regression tests:

- **`MiningMainchainViewImpl` "jump leak."** On a large block-number jump, headers
  below the new boundary were not evicted from `blocksByHash` /
  `blockHashesByNumber`, so the maps grew without bound. Fixed so the view holds
  only the relevant window. Covered by `MiningMainchainViewImplLeakTest`.
- **`NetBlockStore` unbounded sync buffers.** The P2P pending block/header maps had
  no ceiling. Bounded to `MAX_BLOCKS=5000` / `MAX_HEADERS=10000` with secondary
  indices cleaned in lockstep. Covered by `NetBlockStoreLeakTest`.
- **Oversized critical caches** (e.g. the receipts/transaction caches) were reduced
  to sane ceilings for the simulation's working set.

These removed real growth, but again did not explain the residual **native** climb
that persisted under heavy signature-verification load.

### 2.6 A ruled-out hypothesis — the secp256k1 JNI path

One hypothesis was that the residual native growth came from the **signature
verification path**. Every transaction and block validation goes through the native
`secp256k1` library via JNI (`NativeSecp256k1` → `org_bitcoin_NativeSecp256k1.c`),
which uses off-heap direct `ByteBuffer`s and is exactly the kind of per-call /
per-thread native allocator that NMT cannot see — a plausible suspect.

To test it in isolation, a standalone reproducer was built:
`co.rsk.cli.tools.Secp256k1NativeMemoryProbe`. It drives `NativeSecp256k1.sign` /
`verify` from many worker threads (configurable `--threads`, `--ops-per-thread`,
`--invalid-rate-percent`), with a mix of valid and intentionally invalid
signatures, while sampling heap, non-heap, direct/mapped buffer pools, live thread
count, RSS, and a derived non-NMT estimate — with no other node services running.

**Outcome: this was a dead end.** The probe does show per-thread direct buffers that
scale with thread count and then **plateau** (with 200 threads, ~800 MB of
native memory invisible to NMT — see `repos/rskj/tmp/secp256k1-nmt/nmt.csv`). But:

- The footprint is **bounded** — it plateaus per thread and does not keep climbing,
  so it does not match the *unbounded* production growth.
- In the full node, toggling and stressing the crypto path did **not** change the
  `non_jvm_mb` trajectory in any meaningful way.

The secp256k1 path was therefore **excluded as the driver of the OOM**. The
useful by-product is the probe itself and the confirmation that per-thread native
buffers, while real, are not the dominant consumer. The actual lever turned out to
be the RocksDB shared block cache — see Section 3.

---

## 3. The Cause Under Analysis: the RocksDB shared block cache (and architecture)

The two changes that actually altered the node's memory behavior were:

1. **Bounding — and lowering — the RocksDB shared block cache**
   (`database.rocksdb.sharedBlockCacheSize`). With **small** cache values, the
   "extra" native memory becomes insignificant and the node stays **stable**.
2. **Running on `arm64`** instead of emulated `amd64`.

Everything else investigated (secp256k1, heap-side leaks) either was a dead end or
removed only secondary growth. The cache size is the dominant lever.

### 3.1 Why the block cache is the dominant native consumer

The RocksDB block cache is a **native (off-heap) LRU** shared across all DB
instances. It is the single largest deliberately-allocated chunk of `non_jvm_mb`,
and — critically — when index/filter blocks are pinned into it
(`cacheIndexAndFilterBlocks=true`) the cache becomes the bound that contains what
was previously unbounded SST-index growth. So the cache size doesn't just set a
cache footprint; it sets the **ceiling** for a whole class of native allocation.

Because it is native, it is **invisible to JVM heap tooling** and lands squarely in
the `non_jvm_mb` bucket that drives the OOM. Sizing it is therefore the most direct
control over the failure.

### 3.2 The evidence: low cache → stable native memory

The current simulation runs an explicit **cache-size sweep** across otherwise
similar `arm64` miners (see `docker-compose.rskj.yml`):

| Node | Arch | `SHARED_BLOCK_CACHE_SIZE` | `MALLOC_CONF` | Role |
|---|---|---|---|---|
| `rskj-miner1` | arm64 | **1M** | tuned | low-cache |
| `rskj-miner2` | arm64 | **10M** | tuned | mid-cache |
| `rskj-miner3` | arm64 | **100M** | tuned | high-cache |
| `rskj-miner4` | arm64 | default (~1M) | **none** | clean baseline (no tuning) |
| `rskj-node1` | **amd64** | 1M | tuned | architecture control |
| `rskj-node2` | arm64 | 1M | tuned | secondary low-cache |

Observed behavior: with **low** cache values, the additional native memory is
negligible and `non_jvm_mb` / `cgrp_total_mb` stay flat and bounded — the node is
stable. As the cache is raised, native usage rises accordingly. This is the
opposite of the earlier intuition that a *bigger* cache would help: under a tight
cgroup, a small native cache is what keeps the node alive (RocksDB falls back to the
OS page cache, which is reclaimable, rather than holding unreclaimable native LRU
memory). Live data is in `nmt/results/nmt/nmt_history.csv` and the breakdown plots.

### 3.3 The architecture effect

The original "amd64 crashes / arm64 survives" observation (Section 2.3) was
initially dismissed as a pile of confounds. With those confounds removed, a genuine
architecture difference remains under test: `amd64` images run under **emulation**
on the Apple-Silicon host, which adds memory/allocator overhead, while `arm64`
images run natively. `rskj-node1` (amd64) is kept in the matrix specifically as the
architecture control against the otherwise-identical `rskj-node2`/`miner1` (arm64,
1M cache).

### 3.4 What is being worked right now

The open question is **how much of the stabilization is the cache size versus the
architecture versus the allocator (`MALLOC_CONF`)** — and whether `arm64` + the
jemalloc `MALLOC_CONF` tuning
(`dirty_decay_ms:5000,muzzy_decay_ms:5000,tcache:true,background_thread:true,narenas:4`)
contributes on top of the cache bound. The running tests are designed to separate
these:

- **Cache size** is isolated by the 1M / 10M / 100M sweep across identical arm64
  miners.
- **Allocator tuning** is isolated by `rskj-miner4`, the clean baseline with **no**
  `MALLOC_CONF` and the default cache, versus the tuned low-cache miners.
- **Architecture** is isolated by `rskj-node1` (amd64) versus its arm64 twin at the
  same 1M cache.

The goal is a clear attribution: confirm that **small `sharedBlockCacheSize` is the
primary stabilizer**, and quantify the **incremental** effect (if any) of arm64 and
of the `MALLOC_CONF` decay/arena settings.

---

## 4. Future Work: Validating the Theory in Production

The simulation shows that a **small RocksDB shared block cache keeps native memory
stable** (with the allocator and architecture changes applied alongside it). The
remaining work is twofold: (a) finish the **attribution** currently running in the
sim — how much is the cache size versus arm64 versus `MALLOC_CONF` — and then (b)
prove the recommended configuration holds under a **real node on a real network**
over the multi-day timescale where the original OOM appeared.

### 4.1 Hypotheses to confirm or falsify

- **H1 (cache size is primary):** Lowering `database.rocksdb.sharedBlockCacheSize`
  flattens `non_jvm_mb` / `cgrp_total_mb` growth and prevents the OOM, with the
  effect monotonic across the 1M → 10M → 100M sweep.
- **H2 (architecture is secondary):** Native `arm64` uses less/steadier native
  memory than emulated `amd64` at the *same* cache size — a real but smaller effect
  than H1.
- **H3 (allocator is secondary):** The jemalloc `MALLOC_CONF`
  (`dirty_decay_ms`/`muzzy_decay_ms`/`narenas`/`background_thread`) reduces retained
  native pages versus the untuned baseline (`rskj-miner4`), again on top of, not
  instead of, the cache bound.
- **H4 (no functional cost):** A small cache trades native RAM for OS page cache /
  CPU (decompression) without unacceptable throughput or block-processing
  regression.

### 4.2 Experimental design

Two layers.

**Layer A — finish the sim attribution (running now).** A one-factor-at-a-time
matrix on otherwise identical nodes (current `docker-compose.rskj.yml`):

- Cache sweep: `miner1`=1M, `miner2`=10M, `miner3`=100M (arm64, tuned).
- Allocator: `miner4` (arm64, **no** `MALLOC_CONF`, default cache) vs. tuned
  low-cache miners.
- Architecture: `node1` (**amd64**, 1M) vs. `node2`/`miner1` (arm64, 1M).
- Hold constant otherwise: image, DB backend (RocksDB), `maxOpenFiles`, heap `-Xmx`,
  JVM/GC flags, gas limit/genesis, cgroup limit, peer topology, workload.

**Layer B — production validation.** Promote the winning config and A/B it against
the current production config:

1. **Testnet canary:** run the low-cache config on a subset of nodes alongside
   current-config nodes on the same network (same real traffic and peer churn).
2. **Mainnet canary (non-miner first):** a read/validation node mirroring
   production traffic, run for **≥ several days** (the original crash needed
   ~40–60 h to surface) before any miner/critical node.

### 4.3 Parameters to control (inputs)

| Parameter | Why it matters |
|---|---|
| `database.rocksdb.sharedBlockCacheSize` | **Primary variable** — the lever under test (1M / 10M / 100M / default). |
| CPU architecture (arm64 vs amd64/emulated) | Suspected secondary effect on native footprint. |
| `MALLOC_CONF` (decay ms, narenas, tcache, background_thread) | Suspected secondary effect via retained pages. |
| `maxOpenFiles` | Bounds table-reader native memory; keep fixed between arms. |
| TPS / block gas used | Drives I/O and cache pressure; sets the rate of growth. |
| Heap `-Xmx`, cgroup memory limit | Defines headroom and time-to-OOM. |
| Run duration (≥ several days) | The original failure needed ~40–60 h to surface. |

### 4.4 Metrics to validate (outputs / acceptance)

Primary (the thing we claim):

- **`non_jvm_mb` growth rate (MB/min)** and **steady-state plateau** — must be low
  and flat at small cache sizes. Headline acceptance criterion.
- **`cgrp_total_mb` vs. limit / headroom over time**, and **time-to-OOM** (or
  absence of OOM over the full window).
- **RocksDB native block cache** (`rdb_block_cache_mb` / JMX
  `BlockCacheUsageBytes`) staying within the configured bound, confirming the cache
  is the controlled quantity.

Attribution (separate cache from arch and allocator):

- Compare the cache sweep to quantify the cache effect; compare `miner4` vs. tuned
  to quantify the allocator effect; compare `node1` (amd64) vs. arm64 twin to
  quantify the architecture effect.
- Native breakdown to confirm the trade-off: as native block cache shrinks, watch
  **page cache** (`cache_mb`) absorb the slack and **CPU** rise from decompression
  — the expected "two-tier cache" behavior, not a regression.
- Allocator-retained pages via `analyze_drop.py` columns to see whether
  `MALLOC_CONF` decay actually returns pages to the OS.

Guardrails (config must not hurt the node):

- **Correctness/consensus:** identical block acceptance, no validation divergence.
- **Throughput/latency:** TPS and block processing time within an agreed threshold
  (a tiny cache can raise read latency / CPU).
- **CPU:** quantify the decompression cost of a smaller block cache.

### 4.5 Definition of done

The theory is considered validated when, on identical real workloads over a
multi-day window:

1. A **small `sharedBlockCacheSize`** keeps `non_jvm_mb` flat and the node clear of
   the cgroup limit, while a large cache reproduces the climb toward OOM;
2. The contributions of **architecture** and **`MALLOC_CONF`** are quantified as
   secondary to the cache-size effect; and
3. There is **no** consensus regression and any throughput/CPU cost of the small
   cache is measured and acceptable.

---

## 5. Status Summary

| Stage | State |
|---|---|
| Problem characterized (heap flat, `non_jvm_mb` unbounded → OOM) | Done |
| NMT instrumentation + drop attribution tooling | Done |
| Confounds removed (DB backend, jemalloc load, arch emulation) | Done |
| secp256k1 JNI path investigated | Done — **ruled out** (bounded per-thread plateau, no node effect) |
| Heap-side leaks fixed (`MiningMainchainViewImpl`, `NetBlockStore`, caches) | Done — removed secondary growth only |
| **Small RocksDB shared block cache stabilizes native memory** | Done — **the key lever** |
| Attribution: cache size vs. arm64 vs. `MALLOC_CONF` | **In progress** (sim sweep running) |
| Production validation (testnet/mainnet canary) | Planned — Section 4 |
