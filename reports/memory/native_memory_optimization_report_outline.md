# Outline — RSKj Native Memory Optimization Report

> One sentence per section, describing what it currently covers. Use this to review/rework the structure before editing the full report.

- **Executive Summary** — States the goal (prevent OOM crashes) and frames the report as a discovery process that ended in two fixes (bounded RocksDB cache + jemalloc).

- **1. Problem Statement: Exposed Memory Pressure** — Describes the symptom: native (non-JVM) memory grows unbounded until OOM while the Java heap stays stable, accelerated by higher TPS/block size; notes that this memory is allocated outside the JVM, likely by a native JNI library, with RocksDB and the secp256k1 library as the two main suspects.

- **2. Identifying the Cause of the OOM** — Summarizes the investigation: how we narrowed the two JNI suspects, first ruling out secp256k1 and then tracing the growth to RocksDB's unbounded cache and allocator fragmentation.
  - **2.1 Isolating the secp256k1 library** — Built a standalone probe (`Secp256k1NativeMemoryProbe`) that hammers `NativeSecp256k1` sign/verify across many threads (mix of valid/invalid signatures) with NMT enabled and no other node services; the native footprint **plateaus** (RSS rises ~0.55 GB → ~2.47 GB then flattens, with the JNI/non-NMT estimate staying ≈ 0), so secp256k1 is **ruled out** as the source of unbounded growth.
  - **2.2 Ruling out a RocksDB-specific cause (LevelDB rollback)** — Rolled the DB backend back from RocksDB to LevelDB (RocksDB is a fork of LevelDB, so its memory management could have regressed) to test whether the growth predated RocksDB; the result was the **same or worse** — native memory grew even faster — so the leak is not RocksDB-specific but inherent to the native DB layer.
  - **2.3 Checking for unclosed RocksDB iterators** — Following a known native-leak pattern ([Expedia Group: *Solving a Native Memory Leak*](https://medium.com/expedia-group-tech/solving-a-native-memory-leak-71fe4b6f9463), where unclosed RocksDB iterators leaked native memory), audited RSKj's iterator usage; they are already closed correctly (try-with-resources in `RocksDbDataSource`, plus `RocksDbKeyIterator.close()` with a `finalize()` leak-warning safety net), so unclosed iterators were **ruled out**.
    - *Scan details (for report expansion):* `RocksIterator` is created in `RocksDbKeyIterator.java` and exposes `close()` (`RocksDbKeyIterator.close`); `DBIterator` is created in `LevelDbKeyIterator.java` and also exposes `close()`. In the `keys()` paths, iterators are correctly wrapped in try-with-resources in both `RocksDbDataSource.java` and `LevelDbDataSource.java`. Repository call sites of `keyIterator()` also use try-with-resources (notably `co/rsk/cli/tools/DbMigrate.java`, plus tests). Conclusion: both backends close their iterators correctly → leak ruled out.
  - **2.4 Experimental Journey** — Walks the iterative path (OOM kills → enable NMT → find RocksDB had no bounded cache → first 256MB LRU fix → leftover fragmentation) that exposed where the memory was going.
  - **2.5 Root Cause: Allocator Fragmentation** — Explains how glibc/ptmalloc fragments under many small native allocations, trapping freed memory the OS can't reclaim.

- **3. Implemented Solutions** — Introduces the fixes, most-impactful first: the RocksDB cache is where the unbounded native memory actually comes from, so it leads; the allocator change is secondary.
  - **3.1 Configuring a Bounded RocksDB LRU Cache** — The upstream/`master` baseline barely configures RocksDB ([`createOptions()` on master](https://github.com/rsksmart/rskj/blob/master/rskj-core/src/main/java/org/ethereum/datasource/RocksDbDataSource.java#L366) only sets create-if-missing, `NO_COMPRESSION`, arena/write-buffer sizes, and paranoid checks — **no block cache, no `cacheIndexAndFilterBlocks`**), so index/filter blocks grow unbounded; the fix adds a **shared, bounded LRU block cache** (with `cacheIndexAndFilterBlocks=true`) across all DB instances and exposes its size as a tunable `database.rocksdb.sharedBlockCacheSize` property. This is the primary lever.
  - **3.2 Jemalloc: The Precision Allocator** — A secondary improvement: how jemalloc's arenas/binning and `madvise(MADV_DONTNEED)` reduce fragmentation and return RAM to the OS.

- **4. Configuration Deep-Dive** — Reference of the exact knobs used, RocksDB first.
  - **4.1 RocksDB Optimization** — Documents the chosen `sharedBlockCacheSize` value as a strict bound.
  - **4.2 OS-Level Tunables (recommendation)** — Explains `LD_PRELOAD`, `MALLOC_ARENA_MAX`, and the full `MALLOC_CONF` jemalloc tuning string option-by-option; framed as a recommended supplement rather than the core fix.

- **5. Recommendations for Deployment** — Table sizing RocksDB cache against system RAM and JVM heap for different node roles.

- **6. Conclusion (Executive Summary for CTO)** — High-level wrap-up: footprint stabilized, ~1GB waste eliminated, OOM wall removed, ready to scale.

- **7. Future Work: CPU vs. Memory as the Next Bottleneck** — States the hypothesis only: now that native memory is bounded and no longer scales with block size, CPU (not memory) is the likely bottleneck for larger blocks, so future scaling work should focus on CPU. (Hypothesis to be validated; no detailed data here.)

- **8. References and Technical Sources** — External documentation backing the claims.
  - **8.1 RocksDB Memory Management** — Links on default/shared block cache behavior.
  - **8.2 Jemalloc and Native Memory** — Links on jemalloc purging and fragmentation control.
  - **8.3 Linux Runtime Configuration** — Links on `LD_PRELOAD` and `MALLOC_ARENA_MAX`.
