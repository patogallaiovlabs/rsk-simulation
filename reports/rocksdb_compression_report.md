# RSKj RocksDB Compression Report

## TL;DR

This is a low-effort, high-leverage change: enable RocksDB compactation, off by default, with a documented ~20% real-world storage reduction and up to ~80% for calldata-heavy data. The main open question before wider adoption is performance — how much CPU and latency overhead compression adds under live read/write load rather than a one-off compaction.

## Open Pull Request

- [rsksmart/rskj#3606 — RocksDB Compression Feature](https://github.com/rsksmart/rskj/pull/3606)

## Summary

RSKj's RocksDB datasources are currently opened with compression hardcoded off (`CompressionType.NO_COMPRESSION` in `RocksDbDataSource.createOptions()`), so every database on disk — `blocks`, `blooms`, `receipts`, `stateRoots`, `unitrie`, `wallet` — stores raw, uncompressed SST files. This PR makes that a configurable, opt-in property instead of a hardcoded constant, and adds a maintenance tool to compact existing databases into the new codec.

Tested on a mainnet snapshot (~9M blocks), enabling compression cut total database size by **~19.6%** (199.9 GB → 160.7 GB), with much larger gains on some individual databases (`blooms` −86.1%, `stateRoots` −79.7%, `receipts` −70.4%) and up to **~80%** on synthetic calldata-heavy workloads. The default behavior is unchanged — compression stays off unless explicitly enabled — so no existing node is affected until an operator opts in.

## What Changed

- **A new configuration property**, `database.rocksdb.compressionType` (default `no_compression`), replacing the hardcoded `NO_COMPRESSION` in `RocksDbDataSource`. Accepted values are RocksDB's compression codecs — `no_compression`, `snappy`, `zlib`, `bzlib2`, `lz4`, `lz4hc`, `xpress`, `zstd` — parsed case-insensitively and tolerant of either short (`lz4`) or full enum-style (`lz4_compression`) spelling via a new `RocksDbDataSource.parseCompressionType()` helper.
- **The chosen codec applies to both the main and bottommost compaction levels** (`setCompressionType` and the newly-added `setBottommostCompressionType`), so the largest, coldest data at the bottom of the LSM tree is compressed the same way as everything above it.
- **The property is a single, flat setting** — one codec for the whole node, not configurable per individual database (`blocks` vs `receipts` vs `unitrie`, etc.). `RskContext` resolves it once and threads it through every datasource it builds (block store, blooms, receipts, trie/state store, state roots, wallet), as well as through `DbMigrate` and `ImportState`.
- **A new CLI maintenance command, `compact-rocksdb`** (`co.rsk.cli.tools.CompactRocksDb`), that walks every subdirectory under `database.dir`, opens each as a RocksDB datasource, and forces a full-range compaction (including the bottommost level) so existing SST files are rewritten with the configured codec. It accepts an optional `-c/--compressionType` override so a database can be recompacted with a different codec than the one configured for runtime, and refuses to run against a non-RocksDB backend.
- **No offline migration or resync is required.** Changing the property is purely a configuration change; new/compacted SSTs pick up the new codec while older, not-yet-compacted files keep whatever compression they were written with, exactly like the pattern already used for the shared RocksDB block cache (see `reports/memory/native_memory_optimization_report.md`).

## Results

### Mainnet snapshot (~9M blocks), after running `compact-rocksdb`

| Database | Before | After | Reduction | Reduction % |
|---|---:|---:|---:|---:|
| `blocks` | 39 GB | 27 GB | 12 GB | 30.8% |
| `blooms` | 1.9 GB | 264 MB | 1.64 GB | 86.1% |
| `receipts` | 27 GB | 8.0 GB | 19 GB | 70.4% |
| `stateRoots` | 2.0 GB | 407 MB | 1.59 GB | 79.7% |
| `unitrie` | 130 GB | 125 GB | 5 GB | 3.8% |
| **Total** | **199.9 GB** | **160.7 GB** | **39.2 GB** | **19.6%** |

`unitrie` — by far the largest database — barely compresses (3.8%), because Merkle-Patricia trie nodes are dominated by Keccak hashes, which are high-entropy and effectively incompressible by design. The much larger gains on `blooms`, `stateRoots`, and `receipts` reflect that those databases store more structured, repetitive data.

### Synthetic calldata-heavy workload

A synthetic dataset simulating rollup-like transactions (large, repetitive calldata payloads rather than hash-dominated state) compressed by **~80%**, confirming that this feature's payoff scales with how "hash-like" versus "structured" the underlying data is — calldata-heavy or rollup-oriented chains stand to gain the most.

## Operational Considerations

- **Safe by default.** `no_compression` remains the out-of-the-box behavior; nothing changes for a node unless an operator explicitly sets the property.
- **Experimental at this stage.** The PR's own author flags that CPU overhead, compaction duration, and read/write latency under realistic (not just snapshot-compaction) workloads still need dedicated performance testing before wider rollout — this report does not include that data.
- **Compaction is a maintenance operation, not a background migration.** `compact-rocksdb` must be run explicitly (with the node stopped, since it opens the same RocksDB directories the node uses) to rewrite existing data into the new codec; simply flipping the property only affects newly written/compacted SSTs going forward.
- **Interacts with, but doesn't conflict with, the native-memory work.** This is an independent, disk-footprint-focused change — orthogonal to the bounded shared block cache and jemalloc fixes in `reports/memory/native_memory_optimization_report.md` — but worth tracking together, since compression trades some CPU (de/compression on every read and compaction) for less disk I/O and a smaller working set, which can also shift the balance of the CPU-vs-database-contention hypothesis raised in that report's Future Work section.
