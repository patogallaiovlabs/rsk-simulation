# RSKj Native Memory Optimization Report

## Summary

Under sustained heavy load, RSKj nodes were being shut down without warning — not by a crash in the application itself, but by the operating system, for using more memory than they were allowed. Nothing was wrong with the Java side of the node; the memory that kept growing lived in a part of the system that ordinary monitoring doesn't see: the native database engine (RocksDB) that stores the blockchain on disk, and the lower-level system component that manages memory for it.

The investigation identified two contributing factors:

- **RocksDB was allowed to use memory without any limit.** A part of its memory usage was tied to the size of the blockchain itself, so the longer a node ran and the more data it stored, the more memory it used — with no ceiling. It has now been given a fixed, tunable memory budget, so it stops growing once it reaches that limit instead of climbing indefinitely.
- **The system's memory manager was "leaking" usable memory as waste.** Even memory the node had genuinely finished using was not being returned to the operating system — it was left behind in unusable fragments, the same way a hard drive can become fragmented over time. Replacing that component with a more efficient one lets memory that's no longer needed actually be handed back.

With both fixes in place, a node's memory usage now levels off and stays flat instead of climbing without bound, removing the wall that previously limited how long a node could stay up and how much load it could handle before crashing.

The rest of this report is written for a technical audience. It walks through how the cause was diagnosed, exactly what was changed and why, how to configure it, and what to consider when deploying it — for anyone who wants the full picture behind the summary above.

## Problem Statement

Under sustained high load, RSKj nodes were being killed by the operating system with Out-Of-Memory (OOM) errors. The failure was silent from the JVM's perspective: there was no `OutOfMemoryError` and no Java stack trace, only the container being terminated by the kernel.

What made this hard to diagnose is that the **Java heap was healthy**. Garbage collection kept it stable and well below its configured `-Xmx` limit, and heap dumps showed nothing alarming. The memory that grew without bound was **native (non-JVM) memory**: the container's resident memory climbed steadily until it crossed its limit and triggered the OOM killer.

The problem is not tied to any particular gas limit. It is a **rate-of-growth** problem: higher transaction throughput and larger blocks make native memory grow faster, turning what might take days in production into hours under stress testing. Stress testing does not create the issue — it only exposes a latent one on a laptop timescale.

Because this memory lives outside the JVM, it is almost certainly allocated by a **native library reached through JNI**. Two components dominate RSKj's native allocations and were the two main suspects:

- **RocksDB** — the embedded key-value store used for blockchain state and the other node databases.
- **secp256k1** — the native elliptic-curve cryptography library used to verify transaction and block signatures.

The rest of this report follows the investigation that narrowed these suspects down to the real cause, and the changes that ultimately fixed it.

## Identifying the Cause of the OOM

With native memory as the culprit and two prime suspects, the investigation proceeded by elimination: rule out the candidates that could be cleared quickly, then follow the remaining growth to its source.

### Isolating the secp256k1 library

The first suspect was the native signature-verification path. Every transaction and block validation calls into `secp256k1` through JNI, and that native code allocates off-heap buffers that the JVM's own tools cannot see — exactly the kind of allocation that could hide an unbounded leak.

To test it in isolation, a standalone probe ([Secp256k1NativeMemoryProbe](https://github.com/patogallaiovlabs/rskj/blob/rats-blocksize-stress/rskj-core/src/main/java/co/rsk/cli/tools/Secp256k1NativeMemoryProbe.java)) was built. It hammers `NativeSecp256k1` sign/verify from many worker threads, with a deliberate mix of valid and intentionally invalid signatures, while Native Memory Tracking is enabled and **no other node services are running**. This exercises only the crypto path.

The result cleared secp256k1: the native footprint **plateaus** rather than growing without bound. Resident memory climbed from ~0.55 GB to about ~2.5 GB as per-thread buffers were allocated and then **flattened**, with the estimated off-heap memory beyond NMT staying near zero (resident memory never exceeded committed memory). The per-thread native buffers are real, but they are **bounded** — they do not match the continuous, unbounded climb seen in production. **secp256k1 was ruled out.**

### Ruling out a RocksDB-specific cause: rolling back to LevelDB

With crypto cleared, attention turned to the database layer. RocksDB is a fork of LevelDB, and its more elaborate memory management could plausibly have introduced a regression. To test whether the problem was specific to RocksDB or predated it, the DB backend was rolled back from RocksDB to LevelDB.

The leak did not go away — it was the **same, if not worse**: native memory grew even faster on LevelDB. This ruled out a RocksDB-specific defect and pointed instead at something **inherent to the native database layer** and how the node drives it, independent of which backend is used.

### Checking for unclosed RocksDB iterators

A well-documented way to leak native memory from an embedded key-value store is to open database iterators and never close them — each open iterator pins native resources. This is exactly the failure described in Expedia's write-up of a native memory leak ([*Solving a Native Memory Leak*](https://medium.com/expedia-group-tech/solving-a-native-memory-leak-71fe4b6f9463)), so RSKj's iterator usage was audited.

The audit came back clean for both backends:

- `RocksIterator` is created in `RocksDbKeyIterator`, and `DBIterator` in `LevelDbKeyIterator`; both expose `close()`.
- The `keys()` paths wrap their iterators in try-with-resources in both `RocksDbDataSource` and `LevelDbDataSource`.
- Call sites of `keyIterator()` also use try-with-resources (notably `DbMigrate`, plus tests).

On top of that, `RocksDbKeyIterator` has a `finalize()` safety net that logs a warning and closes the iterator if one is ever leaked. **Unclosed iterators were ruled out.**

### Following the leak with Native Memory Tracking

With the quick suspects eliminated, the remaining approach was to stop guessing and measure. Native Memory Tracking (`-XX:NativeMemoryTracking`) itemizes the JVM's own off-heap categories (threads, code cache, GC structures, metaspace, internal), and sampling those alongside the container's resident memory made the gap explicit: **the JVM-attributed categories stayed flat while the unaccounted, non-JVM portion was the entire growth.**

That pointed back at RocksDB — not as a leak of unclosed handles, but as **memory it was allocating by design and never bounding**. Inspecting `RocksDbDataSource.createOptions()` showed the node opened each database with almost no memory configuration: no explicit block cache, and — critically — **index and filter blocks left unbounded**, growing with the chain. A first fix that put a bounded cache in place reduced the growth sharply but did not fully flatten it, which revealed a second contributor underneath: allocator fragmentation.

### Root cause: allocator fragmentation

The residual growth came from the C allocator itself. The default `glibc` allocator (ptmalloc) fragments badly under a workload of many small, short-lived native allocations — the exact pattern RocksDB produces. Freed memory is not returned to the OS but left as "holes" trapped between still-live allocations, so the process's resident size keeps climbing even though the application has logically freed the memory.

This explained the two observations that had been puzzling: why the leak persisted even after bounding the cache, and why switching to LevelDB made things *worse* rather than better — both backends hammer the same fragmenting allocator. Together, the **unbounded RocksDB cache** and **allocator fragmentation** are the two root causes the fixes in the next section address.

## Implemented Solutions

The investigation pointed at two independent contributors, and the fixes address them in order of impact. First and most important, RocksDB is given a **bounded, shared block cache** so the native memory it manages can no longer grow with the chain — this is where the unbounded growth actually came from. Second, the C allocator is switched from glibc to **jemalloc** to reclaim the residual fragmentation that a bounded cache alone cannot remove. The cache fix caps the memory; the allocator fix keeps what is freed from being stranded.

### Configuring a bounded RocksDB LRU cache

On the upstream `master` baseline, each database is opened with almost no memory configuration. [`createOptions()` on master](https://github.com/rsksmart/rskj/blob/master/rskj-core/src/main/java/org/ethereum/datasource/RocksDbDataSource.java) sets only create-if-missing, `NO_COMPRESSION`, the arena and write-buffer sizes, and paranoid checks — it configures **no block cache** and leaves `cacheIndexAndFilterBlocks` at its default. This is the crux of the problem: RocksDB caches every table's index and filter blocks in native memory to serve reads, and with no bound and no cache to charge them against, that memory grows with the number and size of SST files — i.e. with the chain. Every DB instance the node opens (blocks, receipts, unitrie, and the rest) does this independently, so the growth is effectively multiplied across datasources.

The fix reworks `createOptions()` to attach a **single, bounded LRU block cache shared across every DB instance** and to force index and filter blocks into it:

```java
    private Options createOptions() {
        Options options = new Options();
        options.setCreateIfMissing(true);
        options.setCompressionType(CompressionType.NO_COMPRESSION);
        options.setArenaBlockSize(GENERAL_SIZE);
        options.setWriteBufferSize(GENERAL_SIZE);
        options.setParanoidChecks(true);

        int maxOpenFiles = config.getRocksDbMaxOpenFiles();
        logger.info("Setting RocksDB maxOpenFiles to {}", maxOpenFiles);
        options.setMaxOpenFiles(maxOpenFiles);

        BlockBasedTableConfig tableOptions = new BlockBasedTableConfig();
        // Force index and filter blocks into a bounded SHARED LRU cache
        // to prevent native OOMs and linear memory growth with many DBs
        tableOptions.setBlockCache(getSharedBlockCache(config));
        tableOptions.setCacheIndexAndFilterBlocks(true);
        tableOptions.setPinL0FilterAndIndexBlocksInCache(true);
        options.setTableFormatConfig(tableOptions);

        return options;
    }
```

Three decisions make this a hard bound rather than another soft cache:

- **One shared cache for all databases.** The `LRUCache` is a `static` instance created once and handed to every `RocksDbDataSource`, so all datasources draw from the *same* fixed budget instead of each accumulating its own. Its size comes from the new `database.rocksdb.sharedBlockCacheSize` property, so the ceiling is a deliberate, tunable number rather than an emergent one:

```java
    private static synchronized Cache getSharedBlockCache(SystemProperties config) {
        if (sharedBlockCache == null) {
            long cacheSize = config.getRocksDbSharedBlockCacheSize();
            logger.info("Initializing RocksDB shared block cache with size {} bytes", cacheSize);
            sharedBlockCache = new LRUCache(cacheSize);
        }
        return sharedBlockCache;
    }
```

- **`cacheIndexAndFilterBlocks = true`.** This is what closes the actual leak. It moves index and filter blocks — the component that was growing unbounded — *into* the LRU cache, so they are charged against the fixed budget and evicted under LRU pressure instead of pinned in native memory forever.
- **`pinL0FilterAndIndexBlocksInCache = true`.** A performance safeguard that keeps the hottest (L0) index/filter blocks resident within the cache, so bounding memory does not cost a disproportionate hit on read latency.

The result is that the block cache — previously the source of the unbounded climb — becomes a flat line at a size the operator chooses. Because the size is now a runtime property rather than a compiled-in constant, it can be tuned per node to the available RAM.

### Jemalloc: the precision allocator

Bounding the cache stops native memory from *growing with the chain*, but it does not undo the fragmentation the root-cause analysis identified: freed memory left trapped as holes in glibc's `ptmalloc` heap. Removing that residual overhead requires changing the allocator itself, which is the second (and optional) fix.

RSKj is run with **jemalloc** preloaded in place of glibc `malloc`. Jemalloc is purpose-built for exactly the workload RocksDB produces — many small, concurrent, short-lived native allocations:

- **Arenas and size-class binning.** Jemalloc segregates allocations into per-arena, size-classed bins, so similarly sized objects are grouped together and freed slots are readily reused. This is the direct antidote to the fragmentation that stranded memory under `ptmalloc`, and it also reduces cross-thread contention.
- **Decay-based purging via `madvise(MADV_DONTNEED)`.** When memory is freed, jemalloc does not merely mark it reusable in-process; on a configurable decay schedule it calls `madvise(MADV_DONTNEED)` to hand the underlying physical pages back to the kernel. The virtual address is retained for future reuse, but the RAM is reclaimed. This is what makes the process's resident size actually *fall* after a burst of activity, instead of ratcheting only upward as it did with glibc.

Because the allocator is swapped in via `LD_PRELOAD`, it transparently intercepts every `malloc`/`free` from both the JVM and RocksDB with no source changes. Its decay timing, arena count, and thread-cache behavior are all tuned through a single `MALLOC_CONF` string, detailed in the configuration deep-dive below.

## Configuration Deep-Dive

This section documents the exact knobs behind the two fixes above, so they can be reproduced or re-tuned without re-reading the source.

### RocksDB Optimization

The shared block cache is configured in `rsk/rsk.conf`, the config file mounted into every node:

```hocon
database {
    dir = "./test/local-regtest/database"

    rocksdb {
        maxOpenFiles = 1000
        sharedBlockCacheSize = 256M
    }
}
```

`sharedBlockCacheSize = 256M` is the strict bound described in the Configuring a bounded RocksDB LRU cache section: because `getSharedBlockCache()` creates the `LRUCache` exactly once per process (`static`, `synchronized`), this single 256 MB budget is shared across **every** RocksDB instance the node opens — blocks, receipts, `unitrie`, `stateRoots`, `blooms`, wallet — not 256 MB *per* database. `maxOpenFiles = 1000` sits alongside it as a related bound: it caps how many SST file handles RocksDB keeps open per database, which in turn caps the native "table reader" memory associated with those handles.

256 MB was chosen against the current container profile: the miners run with a 6 GB cgroup memory limit and a 4 GB JVM heap (`-Xms4G -Xmx4G`), leaving roughly 2 GB for everything outside the heap. A fixed 256 MB cache uses an eighth of that headroom while still giving RocksDB enough room to keep hot index/filter blocks resident, and leaves the rest for thread stacks, metaspace, code cache, and the residual native overhead the jemalloc fix targets. The Recommendations for Deployment section generalizes this ratio across other RAM/heap combinations.

**What `maxOpenFiles` actually bounds.** Unlike `sharedBlockCacheSize`, this is not a limit on how many SST files a database may *have* on disk — it sizes RocksDB's internal **table cache**, an LRU cache of open file handles/readers. RocksDB reserves roughly 10 handles internally for other uses (WAL, MANIFEST, `LOCK`, `LOG`) and sizes the table cache at `maxOpenFiles - 10` entries, so `1000` really means **~990 SST readers** can stay open before the least-recently-used one is closed and transparently reopened on its next access — an extra `open()` and footer/metadata read, i.e. a latency cost on a cold read, not a hard failure. It is also, unlike the block cache, set **per RocksDB instance**: each of the up to six logical databases a node opens (`blocks`, `receipts`, `unitrie`, `stateRoots`, `blooms`, `wallet`) gets its own independent `Options` object and therefore its own 1000-file table cache, rather than sharing one.

Pulling real numbers off ~48 hours into a continuous 25M-gas-limit stress run:

| Database | SST files on disk | Size on disk | Avg. file size |
|---|---|---|---|
| `blocks` | 272 | 15 GB | ~57 MB |
| `unitrie` | 94 | 5.7 GB | ~62 MB |
| `receipts` | 22 | 1.2 GB | ~56 MB |
| `blooms` / `stateRoots` / `wallet` | 0 | ~16 MB / ~16 MB / ~4 MB | memtable-only so far |

Individual files cluster tightly around **64–70 MB**, with a handful of outliers up to ~99 MB from larger compactions — consistent with RocksDB's compiled-in `target_file_size_base` default of 64 MiB (67,108,864 bytes), which RSKj does not override. The per-database *averages* above sit a bit lower because they also include smaller, still-forming files from in-flight compactions and recent flushes, which pull the mean down from the ~64–70 MB "full-size" mode.

`blocks` is both the largest database and the fastest-growing — every new block, plus the ancestors retained for reorg handling, adds data — so it's the one to watch against the 990-entry ceiling. At 272 files over ~48 hours, it accumulates SSTs at roughly **5.7 files/hour**. Projecting that rate forward, `blocks` alone would need **~176 hours (~7.3 days)** of continuous 25M-gas-block load to reach the table-cache limit and start evicting/reopening file handles under LRU pressure — not a concern at the timescale of a multi-day stress test, but a number worth knowing before a multi-week soak run.

On the memory side, because `cacheIndexAndFilterBlocks = true` moves each file's index and filter blocks into the shared 256 MB LRU cache rather than pinning them per-reader, the residual cost of each open table-cache *entry* is small — footer, table properties, comparator name, and similar bookkeeping, typically on the order of ~1 KB rather than the hundreds of KB to low single-digit MB per file it would be if index/filter blocks were pinned outside the cache. Even a worst case across the three currently-active databases (990 × 3 ≈ 2,970 entries) works out to roughly 3 MB of table-cache bookkeeping — negligible next to the 256 MB block cache it sits alongside.

On file descriptors specifically, this deployment has essentially no exposure: the container's open-files limit (`ulimit -n`) is 1,048,576, and the RSKj process currently holds 507 open FDs in total (sockets, JMX, and the ~388 open SST readers across the three active databases combined). Even the theoretical worst case — all six databases simultaneously maxed at 1000 files each — would use under 1% of the available descriptor budget. In this deployment, `maxOpenFiles` is purely an internal RocksDB memory/latency knob, not a guard against `EMFILE`.

### OS-Level Tunables (OPTIONAL)

To make this string take effect, three pieces need to be in place:

- **`LD_PRELOAD`** — the mechanism that activates jemalloc in the first place. Setting `LD_PRELOAD=/usr/lib/<arch>/libjemalloc.so.2` (after `apt-get install libjemalloc2` in the image) tells the dynamic linker to resolve every `malloc`/`free`/`realloc` symbol against jemalloc before glibc, for both the JVM and RocksDB's JNI calls, with zero source changes on either side. Without this variable, `MALLOC_CONF` has no effect at all — glibc doesn't read it, so setting it alone is a no-op until `LD_PRELOAD` is added.
- **`MALLOC_ARENA_MAX`** — a glibc-specific fallback, relevant only if jemalloc is *not* preloaded. glibc can create up to 8 arenas per core by default; each arena duplicates free-list metadata and can independently fragment, so a many-threaded process on a multi-core host can multiply its worst-case fragmentation. Setting `MALLOC_ARENA_MAX=4` bounds that blast radius as a "belt and suspenders" measure. Once jemalloc is active via `LD_PRELOAD`, this variable is superseded by jemalloc's own `narenas` setting below.
- **`MALLOC_CONF`** — jemalloc's own tuning string, read once at process start. Option by option, for the string above:
  - **`dirty_decay_ms:5000`** — freed pages are held "dirty" (immediately reusable, not yet returned to the OS) for 5000 ms before jemalloc considers purging them. This absorbs short-lived allocation bursts (e.g. a batch of RocksDB compactions) without needless `madvise` churn, while still bounding how long freed memory can sit idle.
  - **`muzzy_decay_ms:5000`** — an intermediate decay stage (lazily released via `MADV_FREE`, cheaper than a full purge) before pages reach the `dirty_decay_ms` fate of a hard `MADV_DONTNEED`. Keeping it equal to `dirty_decay_ms` here means the two stages decay together rather than staggering the purge schedule.
  - **`tcache:true`** — enables per-thread caching of small allocations, giving RSKj's many worker/networking threads a lock-free fast path instead of contending on shared arena locks. This trades a small amount of memory held per thread for materially lower allocation latency and contention.
  - **`background_thread:true`** — moves the decay/purge sweep itself to a dedicated background thread instead of running it inline on whichever thread happens to trigger it, so purging RAM back to the OS doesn't show up as latency on the request/validation path.
  - **`narenas:4`** — bounds jemalloc to 4 arenas, matched to the `cpus: '2.0'` limit each node container is given in `docker-compose.rskj.yml` (2x the CPU quota gives enough parallelism to avoid arena-lock contention without paying for arenas the container can't actually use concurrently).

Rolling this out means: install `libjemalloc2` in `Dockerfile`, add the arch-aware `LD_PRELOAD` (and optionally `MALLOC_ARENA_MAX`) as image `ENV` defaults, and copy the existing `MALLOC_CONF` string.

```
MALLOC_CONF=dirty_decay_ms:5000,muzzy_decay_ms:5000,tcache:true,background_thread:true,narenas:4
```

## Future Work: CPU and Database Contention as the Next Bottleneck

The fixes documented in this report remove native memory as a source of node crashes: RocksDB's footprint is bounded rather than scaling with the chain, and the residual allocator fragmentation is addressed by the recommended jemalloc change. With that wall gone, the working hypothesis is that the next limiting factor for faster, larger blocks is no longer purely computational — it is a combination of **CPU** and **contention on the database itself**.

The CPU side is the more obvious candidate: signature verification, transaction execution, and state trie operations all scale with the volume of work per block, in a way memory no longer does now that it is capped. But RocksDB is a **single point of access** to the node's state, shared concurrently by block execution, mining, sync, and RPC read paths — under enough concurrent pressure, waiting on that shared access, not raw CPU cycles, could be the actual limiter. 

This is a hypothesis, not a conclusion: nothing in this report profiles CPU usage or database access patterns directly, and no data has been collected yet on where the next ceiling actually sits, which processes are blocking each other, or how the cache layers interact under concurrent load. The natural next step is to profile database access under the same kind of sustained, high-gas-limit stress testing used throughout this investigation — identifying which concurrent processes contend for the database, where they lock each other out, and whether the independent cache layers should be consolidated or coordinated rather than left to compete.

## References and Technical Sources

### Project Implementation and Tests

- [rsk-simulation](https://github.com/patogallaiovlabs/rsk-simulation) — the project used to run all the stress testing and monitoring behind this report: the Dockerized RSKj network, the k6 stress-test suite, and the Prometheus/Grafana/Loki monitoring stack used to capture the Native Memory Tracking and `cgroup` data cited throughout.
- [RocksDbDataSource: bounded shared block cache](https://github.com/patogallaiovlabs/rskj/blob/ri_fixleak/rskj-core/src/main/java/org/ethereum/datasource/RocksDbDataSource.java#L400) — the actual code change behind the RocksDB fix documented in Implemented Solutions and Configuration Deep-Dive.
- [rsk-simulation Dockerfile: jemalloc / `MALLOC_CONF` example](https://github.com/patogallaiovlabs/rsk-simulation/blob/master/rsk/Dockerfile) — a working example of wiring up the allocator change described in OS-Level Tunables.

### RocksDB Memory Management

- [RocksDB Wiki: Memory usage in RocksDB](https://github.com/facebook/rocksdb/wiki/Memory-usage-in-RocksDB) — how block cache, index/filter blocks, memtables, and the table cache each contribute to a database's native memory footprint.
- [RocksDB Wiki: Block Cache](https://github.com/facebook/rocksdb/wiki/Block-Cache) — the LRU block cache mechanics behind `sharedBlockCacheSize` and `cacheIndexAndFilterBlocks`.
- [RocksDB Wiki: Setup Options and Basic Tuning](https://github.com/facebook/rocksdb/wiki/Setup-Options-and-Basic-Tuning) — general guidance on `max_open_files`, table cache sizing, and the tradeoffs behind them.
- [RocksDB Wiki: Partitioned Index Filters](https://github.com/facebook/rocksdb/wiki/Partitioned-Index-Filters) — explains why large per-SST index/filter blocks compete with data blocks for space in the shared block cache, and how partitioning them into smaller pieces (not used in the fix documented here) can reduce that competition further as a possible follow-up refinement.
- [RocksDB Issue #12579: High Memory Usage / LRU cache size is not being respected](https://github.com/facebook/rocksdb/issues/12579) — a real-world report of a configured LRU block cache limit being exceeded in production, with knock-on CPU pressure from the resulting backpressure — the same class of failure the bounded shared cache in this report is meant to prevent.
- [RocksDB Issue #3216: RocksDB massively exceeds memory limits](https://github.com/facebook/rocksdb/issues/3216) — RSS far exceeding the documented worst-case memory budget under a read-heavy, iterator-driven workload, illustrating how RocksDB's actual native memory use can diverge from the numbers implied by its own memory-usage documentation.
- [RocksDB Issue #4112: Memory grows without limit](https://github.com/facebook/rocksdb/issues/4112) — another reported case of unbounded RSS growth, corroborating that this is a recurring, known class of issue across RocksDB deployments generally, not something specific to RSKj's usage.
- [Mark Callaghan (smalldatum): MyRocks versus allocators, glibc malloc](https://smalldatum.blogspot.com/2015/10/myrocks-versus-allocators-glibc.html) — a direct benchmark of glibc `malloc` against jemalloc/tcmalloc under a RocksDB-based workload, showing the same allocator-driven fragmentation and RSS growth pattern that motivated the jemalloc fix in this report.

### Jemalloc and Native Memory

- [jemalloc(3) man page](https://jemalloc.net/jemalloc.3.html) — authoritative reference for the `MALLOC_CONF` options used in this report (`dirty_decay_ms`, `muzzy_decay_ms`, `tcache`, `background_thread`, `narenas`).
- [jemalloc GitHub Wiki](https://github.com/jemalloc/jemalloc/wiki) — background on arenas, size-class binning, and decay-based purging.
- [Facebook Engineering: Scalable memory allocation using jemalloc](https://engineering.fb.com/2011/01/03/core-data/scalable-memory-allocation-using-jemalloc/) — the original case for jemalloc over glibc `malloc` under fragmentation-prone, multi-threaded native workloads, the same pattern RocksDB produces here.

### Linux Runtime Configuration

- [`ld.so(8)` man page](https://man7.org/linux/man-pages/man8/ld.so.8.html) — the `LD_PRELOAD` mechanism used to activate jemalloc ahead of glibc without source changes.
- [`mallopt(3)` man page](https://man7.org/linux/man-pages/man3/mallopt.3.html) — glibc's own tunables, including the arena-count behavior that `MALLOC_ARENA_MAX` bounds.
- [GNU C Library Manual: Malloc Tunable Parameters](https://www.gnu.org/software/libc/manual/html_node/Malloc-Tunable-Parameters.html) — background on glibc's per-thread arena allocation and why it can inflate memory usage in multi-threaded processes like RSKj.

