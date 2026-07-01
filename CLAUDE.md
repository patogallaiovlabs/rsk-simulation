# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Docker-based simulation environment for a local RSK (Rootstock) blockchain network. It is used for performance testing, memory analysis, and monitoring of RSKj nodes. The project is not a typical application — it is an orchestration layer of Docker Compose stacks, monitoring infrastructure, and analysis scripts.

## Core Commands

### Network Lifecycle

```bash
# One-time setup: create the shared Docker network
docker network create rsk-simulation-net 2>/dev/null || true

# Start RSK node network (miners + nodes)
docker compose -f docker-compose.rskj.yml up -d

# Start monitoring stack (Prometheus, Grafana, Loki, exporters)
docker compose -f docker-compose.tools.yml up -d

# Start stats dashboard
docker compose -f docker-compose.stats.yml up -d

# Full restart (tears down volumes too — wipes blockchain state)
bash scripts/restart.sh

# Apply config changes without wiping state
docker compose -f docker-compose.rskj.yml up -d --force-recreate
```

### Stress Testing (k6)

```bash
cd repos/rskj-k6-tests
npm install  # first time only
npm run test:regtest:keccak-random-writes
```

### Memory Analysis (NMT)

```bash
# Summary for a single node
./nmt/nmt.sh rskj-miner1 summary

# Compact table of all nodes
./nmt/nmt.sh all compact

# CSV row appended to results/nmt/nmt_history.csv
./nmt/nmt.sh rskj-miner1 csv

# All nodes, CSV (for scripted collection)
./nmt/nmt.sh all csv

# Analyze drops after collecting data
python3 nmt/analyze_drop.py --container rskj-miner2
```

### Grafana Data Export & Analysis

```bash
cd grafana/exporter
cp config.example.json config.json  # first time — fill in api_key and dashboard_uid
pip install requests

# Export last 6h and generate reports
python3 export_panels.py

# Custom time range
python3 export_panels.py --from 2026-02-10T00:00:00Z --to 2026-02-11T00:00:00Z
```

## Architecture

### Docker Compose Stack Separation

There are three independent stacks that share the `rsk-simulation-net` external Docker network:

| File | Purpose |
|---|---|
| `docker-compose.rskj.yml` | RSKj nodes (currently 4 miners `rskj-miner1..4`; the 2 non-mining nodes `rskj-node1`/`rskj-node2` are defined but **disabled** via a compose profile — see "Enabling/disabling nodes") |
| `docker-compose.tools.yml` | Monitoring: Prometheus, Grafana, Loki, Promtail, cAdvisor, node-exporter, docker-stats-exporter, rsk-rpc-exporter |
| `docker-compose.stats.yml` | RSK Stats Dashboard (backend + agent submodules) |

The stacks are intentionally decoupled so the monitoring stack can be restarted without disrupting the nodes.

### RSKj Node Image (`rsk/Dockerfile`)

The image is a multi-stage build: it compiles RSKj from the `repos/rskj` git submodule using Gradle, then produces a minimal JRE image. Key details:

- Base: `eclipse-temurin:17`
- Includes `jattach` (for in-container `jcmd` / NMT access) and `libjemalloc2` (preloaded via `LD_PRELOAD`)
- JMX Prometheus Java Agent is baked in at `/usr/local/lib/rsk/` and runs on port 8080 inside the container (exposed as 9501–9506 on the host)
- `MINER_ID`, `IS_MINER`, `BLOCK_GAS_LIMIT`, `WIRE_DELAY`, `FLUSH_BLOCKS`, `MALLOC_CONF`, `DEFAULT_JVM_OPTS`, `SHARED_BLOCK_CACHE_SIZE` are all runtime env vars
- The genesis file is volume-mounted; different gas limit scenarios use different genesis files in `rsk/genesis/` (`rsk/genesis/genesis_7M.json` through `rsk/genesis/genesis_360M.json`)
- Env vars that have **no Dockerfile default** must be set per-service or startup breaks: `FLUSH_BLOCKS` is interpolated raw into `-Dblockchain.flushNumberOfBlocks=${FLUSH_BLOCKS}`, so omitting it passes an empty value. (`SHARED_BLOCK_CACHE_SIZE` defaults to `1M`, `WIRE_DELAY` to `100`, `BLOCK_GAS_LIMIT` to `7000000`, `GENESIS_FILE` to empty, `IS_MINER` to `true` in the image.)

### Configuration: Changing Gas Limit

When changing `BLOCK_GAS_LIMIT`, the genesis file mount must match. In `docker-compose.rskj.yml`:

```yaml
environment:
  - BLOCK_GAS_LIMIT=25000000
volumes:
  - ./rsk/genesis/genesis_25M.json:/var/lib/rsk/genesis.json
```

After any env/volume change: `docker compose -f docker-compose.rskj.yml up -d --force-recreate`

### Configuration: per-node RocksDB block cache (`SHARED_BLOCK_CACHE_SIZE`)

The RocksDB shared block cache (`database.rocksdb.sharedBlockCacheSize`) used to be hardcoded in `rsk/rsk.conf`. Because `rsk.conf` is mounted into **every** node, it could not differ per node. It is now a per-node env var:

- `rsk/Dockerfile` defines `ENV SHARED_BLOCK_CACHE_SIZE="1M"` and passes `-Ddatabase.rocksdb.sharedBlockCacheSize=${SHARED_BLOCK_CACHE_SIZE}` on the `java` command line. A `-D` system property overrides the value in `rsk.conf`, so `rsk.conf` no longer sets it.
- Set it per service in `docker-compose.rskj.yml` (e.g. `- SHARED_BLOCK_CACHE_SIZE=100M`) to compare cache sizes across nodes. Changing only the env var needs **no image rebuild** — `docker compose ... up -d --force-recreate` is enough.
- No-op for LevelDB nodes (LevelDB ignores the RocksDB block-cache setting).

This is the general pattern in this repo: shared/static config lives in `rsk.conf`; anything that must differ per node is an env var injected as a `-D` override via the Dockerfile entrypoint.

### Configuration: per-DB RocksDB compression (`database.rocksdb.compressionType`)

The `rats-blocksize-stress-SNAPSHOT` branch of `repos/rskj` adds **per-datasource** RocksDB compression. `RocksDbDataSource.createOptions()` calls `config.getRocksDbCompressionType(name)` and `RskSystemProperties` resolves it from (in priority order):

1. `database.rocksdb.compressionType.<dbName>` — per-DB (e.g. `...receipts`, `...unitrie`, `...blocks`).
2. `database.rocksdb.compressionType.default` — fallback for all DBs.
3. `database.rocksdb.compressionType` — a flat single value.
4. Hardcoded default: **`NO_COMPRESSION`**.

Accepted values (case-insensitive): `none`, `snappy`, `lz4`, `zstd`, or the RocksDB enum names (`NO_COMPRESSION`, `SNAPPY_COMPRESSION`, ...). An unknown value throws `RskConfigurationException` at startup.

The **DB name is the datasource directory's last path segment** (`KeyValueDataSourceUtils.makeDataSource` → `datasourcePath.getFileName()`), so the per-DB names match the on-disk dirs: `blocks`, `blooms`, `receipts`, `stateRoots`, `unitrie`, `wallet`.

Example — LZ4 only on `miner1`'s receipts DB. Since `rsk.conf` is shared, set it as a `-D` in that service's `RSKJ_SYS_PROPS` (a `-D` system property wins over the `rsk.conf` file, per `ConfigLoader`):

```yaml
# docker-compose.rskj.yml, rskj-miner1 only
- RSKJ_SYS_PROPS=-Drsk.conf.file=/var/lib/rsk/rsk.conf -Dlogging.dir=test/local-regtest/ -Ddatabase.rocksdb.compressionType.receipts=lz4
```

Operational notes:
- **Compression is applied to newly written/compacted SST files**, not retroactively. Existing SSTs keep their old format until RocksDB compacts them — no resync/wipe needed.
- **Behavior change when adopting this branch:** the old image never called `setCompressionType`, so RocksDB used its built-in default (Snappy). The new code defaults unconfigured DBs to `NO_COMPRESSION`. To keep the old behavior on un-overridden DBs, set `database.rocksdb.compressionType.default = snappy` (in `rsk.conf` for all nodes, or per node).
- LZ4/ZSTD/Snappy libs are bundled in the `rocksdbjni` jar (the branch is on "rocksdb 10"), so no extra native deps are needed.
- Requires an **image rebuild** if the running image predates the feature, **and** the new `rsk.jar` must be pushed into the node's volume (see the critical gotcha under "Per-node image rebuilds"). The `Setting RocksDB compressionType ...` log line is suppressed (the `db` logger is `WARN`), so confirm via the RocksDB `OPTIONS` file instead: `grep -i "^[[:space:]]*compression=" $(ls -t test/local-regtest/database/receipts/OPTIONS-* | head -1)` should show `kLZ4Compression`.

### Configuration: changing a node's DB backend (RocksDB ↔ LevelDB)

The datasource is selected with `-Dkeyvalue.datasource` in a service's `RSKJ_SYS_PROPS` (absent = RocksDB default; `=leveldb` for LevelDB). All four miners now run RocksDB (`miner2` was previously LevelDB and was switched).

Important: an existing data directory records its backend in `<database.dir>/dbKind.properties` (e.g. `keyvalue.datasource=ROCKS_DB`). The runtime datasource must match the on-disk one, otherwise the node won't read the existing DB. To switch backends you must also replace/wipe the database (see "Cloning a node's database").

### Enabling/disabling nodes (compose profiles)

`rskj-node1` and `rskj-node2` are kept in `docker-compose.rskj.yml` but assigned `profiles: ["disabled"]`, so a normal `docker compose -f docker-compose.rskj.yml up -d` starts **only** the miners. To run the disabled nodes too:

```bash
docker compose -f docker-compose.rskj.yml --profile disabled up -d
```

Note: disabled nodes still appear in `nmt.sh`'s container list and will show `N/A` in the compact table when not running.

### Node-specific notes

- `rskj-miner4` is a **clean baseline** miner: no `MALLOC_CONF` (glibc/jemalloc defaults), default `SHARED_BLOCK_CACHE_SIZE` (1M), no JMX/`WIRE_DELAY` overrides (so it inherits the image default `WIRE_DELAY=100` — the other nodes use `0`). It keeps only `DEFAULT_JVM_OPTS`, `RSKJ_SYS_PROPS`, and `RSKJ_LOG_PROPS`. Useful as the "untuned" control when comparing memory behavior.

### Per-node image rebuilds

Each service in `docker-compose.rskj.yml` has its own `build:` block and **no explicit `image:` tag**, so Compose builds a **separate image per service** (`rsk-nodes-rskj-miner1`, `rsk-nodes-rskj-miner2`, ...). Consequences:

- Rebuilding one node does **not** affect the others' running containers:

  ```bash
  docker compose -f docker-compose.rskj.yml build rskj-miner1
  docker compose -f docker-compose.rskj.yml up -d rskj-miner1   # recreates only miner1; volume (DB) persists
  ```

- This is the way to roll out an `repos/rskj` source change (e.g. the compression feature) to a single node while an experiment keeps running on the others. The image build compiles RSKj via Gradle, so it takes several minutes.
- A source change in `repos/rskj` only reaches a node when **that node's image is rebuilt**; nodes on older images keep the old behavior. (The compression feature is currently uncommitted in `repos/rskj` and reaches a node on its next rebuild.)
- `repos/rskj` (the submodule, branch `rats-blocksize-stress-SNAPSHOT`) is what the image builds — **not** the separate `workspace/rsk/rskj` (`master`) checkout, which lacks these changes.

So the normal flow to roll out a code change to a node is just:

```bash
docker compose -f docker-compose.rskj.yml build rskj-miner1
docker compose -f docker-compose.rskj.yml up -d rskj-miner1   # recreates only miner1; DB volume persists
```

> **Why this now "just works" (and the gotcha it fixes).** `rsk.jar` is intentionally stored at **`/usr/local/lib/rsk/rsk.jar`** (the classpath in the Dockerfile entrypoint points there) — i.e. **outside** the `/var/lib/rsk` volume mount. The data volume is mounted at `/var/lib/rsk`, and Docker only seeds an image's files into a volume when the volume is **empty**. Previously the jar lived at `/var/lib/rsk/rsk.jar`, so once a node had run (or had its volume cloned), the volume's stale `rsk.jar` **permanently shadowed** the image's — `build` + `up -d` silently ran the **old jar** (we hit exactly this: receipts `OPTIONS` stayed `kNoCompression` and the in-container jar mtime predated the rebuild). With the jar outside the volume, a rebuilt image always wins.
>
> Verifying a code/config change took effect: check what RocksDB actually wrote (the `db` logger is `WARN` in `rsk/logback.xml`, so the `Setting RocksDB compressionType ...` INFO line is **not** in `docker logs`):
>
> ```bash
> docker exec rskj-miner1 sh -c 'grep -i "^[[:space:]]*compression=" $(ls -t test/local-regtest/database/receipts/OPTIONS-* | head -1)'
> ```
>
> Legacy cleanup: nodes whose volumes predate this change still contain an orphaned, now-unused `/var/lib/rsk/rsk.jar` (~115 MB). It's harmless (no longer on the classpath) but can be removed:
> `docker run --rm -v rsk-nodes_rskj-data-miner1:/v alpine rm -f /v/rsk.jar`

### Cloning a node's database (skip resync)

To bring a new/empty node online without syncing the whole chain, clone another node's Docker volume. The volumes are named `rsk-nodes_rskj-data-<node>` (compose project `rsk-nodes`).

```bash
# 1. Stop the SOURCE (for a consistent RocksDB snapshot) and the TARGET
docker compose -f docker-compose.rskj.yml stop rskj-miner1 rskj-miner4

# 2. Clone the whole volume (alpine helper)
docker run --rm \
  -v rsk-nodes_rskj-data-miner1:/from:ro \
  -v rsk-nodes_rskj-data-miner4:/to \
  alpine sh -c 'rm -rf /to/* /to/..?* /to/.[!.]* 2>/dev/null; cp -a /from/. /to/'

# 3. Bring everything back up (target boots pre-synced; catches up the few blocks since the snapshot)
docker compose -f docker-compose.rskj.yml up -d
```

Gotchas (all learned the hard way):

- **Clone the WHOLE volume, not just the DB subdir.** The volume is mounted at `/var/lib/rsk`, which also holds `rsk.jar` (Docker seeds it from the image *only when the volume is empty*). If you copy just `test/local-regtest/database`, the volume becomes non-empty and the node boots **without `rsk.jar`**.
- **Match the DB backend.** The source's on-disk backend (`dbKind.properties`) must match the target's runtime datasource. Don't clone a LevelDB node (e.g. an old `miner2`) into a RocksDB node — it would ignore the data and resync. Clone RocksDB→RocksDB.
- **Stop the source during the copy.** Copying a live RocksDB dir can capture a half-written state; stopping it for the duration guarantees a clean snapshot. Other peers keep the chain progressing; the source catches up on restart.
- **Node identity is safe.** `peer.privateKey` and the coinbase are derived from `MINER_ID` via `-D` system properties (entrypoint), not stored in the DB, so cloned nodes don't collide.
- **Size/time.** A ~24h regtest DB is ~46 GB; each volume copy in the Docker Desktop VM takes ~4–5 min.
- Confirm success in the target's logs: it should report `Best block number is: <height>` at startup (not 0) and quickly log `Completed syncing phase`.

### Monitoring Data Flow

```
RSKj containers
  ├── JMX → jmx_prometheus_javaagent (port 8080) → Prometheus scrapes (9501-9506)
  ├── Docker logs → Promtail → Loki → Grafana
  └── RPC (port 4444) → rsk-rpc-exporter → Prometheus (mempool metrics)

Host metrics
  ├── node-exporter → Prometheus (system CPU/mem/disk/net)
  └── cAdvisor / docker-stats-exporter → Prometheus (per-container resources)

Grafana (port 3002) queries Prometheus and Loki
```

### NMT Memory Tracking (`nmt/nmt.sh`)

The script queries JVM Native Memory Tracking, OS RSS, cgroup memory, and RocksDB JMX metrics for each RSKj node. It appends rows to `results/nmt/nmt_history.csv` (created automatically). For Docker nodes it uses `jattach` inside the container; for a local JVM it uses `jcmd` on the host.

The `non_jvm_mb` column estimates memory outside JVM's NMT accounting (RocksDB native, jemalloc overhead, etc.).

The node list is hardcoded in `nmt/nmt.sh`: `DOCKER_CONTAINERS=(rskj-miner1 rskj-miner2 rskj-miner3 rskj-miner4 rskj-node1 rskj-node2)` and the `metrics_port_for()` case maps each container to its JMX-Prometheus host port (miner1..4 → 9501..9504, node1 → 9505, node2 → 9506). **Adding a node requires updating both.** `nmt/plot_nmt.py` needs no changes — it discovers containers from the CSV (`df['container'].unique()`) and reads the node table from the compose file.

### Git Submodules

| Path | Content |
|---|---|
| `repos/rskj` | RSKj source — compiled at Docker image build time |
| `repos/rskj-k6-tests` | k6 stress test suite |
| `repos/stats-backend` | RSK Stats Dashboard backend |
| `repos/stats-agent` | RSK Stats Dashboard agent |

Initialize with: `git submodule update --init --recursive`

### Monitoring: Disable JMX Scraping

To skip JMX/JVM metrics (lighter scraping):

```bash
PROMETHEUS_CONFIG=grafana/prometheus-no-jvm.yml docker compose -f docker-compose.tools.yml up -d
```

## RPC Ports (Host)

| Node | HTTP | WS | JMX | JMX-Prom | Peer |
|---|---|---|---|---|---|
| miner1 | 4444 | 4445 | 9101 | 9501 | 50501 |
| miner2 | 4446 | 4447 | 9102 | 9502 | 50502 |
| miner3 | 4448 | 4449 | 9103 | 9503 | 50503 |
| miner4 | 4450 | 4451 | — (JMX off) | 9504 | 50504 |
| node1 (disabled)  | 4464 | 4475 | 9201 | 9505 | 50601 |
| node2 (disabled)  | 4465 | 4476 | 9202 | 9506 | 50602 |

`miner4` leaves `ENABLE_JMX` unset (image default off), so it exposes no direct JMX port — but the JMX-Prometheus javaagent on `8080`→`9504` is always on, so NMT/Prometheus scraping still works.

## Service URLs

- Grafana: http://localhost:3002
- Prometheus: http://localhost:9091
- Stats Backend: http://localhost:3001
- RSK RPC Exporter metrics: http://localhost:9092/metrics

## Troubleshooting

If Docker image pulls fail with gcloud auth errors:
```bash
cp ./docker/config.json ~/.docker/config.json
```

If logs are missing in Grafana/Loki:
```bash
docker compose -f docker-compose.tools.yml logs -f promtail
```

## Memory Investigation Notes

These are findings accumulated while debugging `non_jvm_mb` spikes/drops and node crashes. They explain how to read the NMT data and avoid misinterpreting it.

### Metric vocabulary (`nmt/nmt.sh` → `results/nmt/nmt_history.csv`)

The script collects, per container:

- `cgrp_total_mb` — **the authoritative resident memory** under the Docker cgroup limit (`memory.current`). This is what gets you OOM-killed.
- `rss_mb`, `cache_mb` — process RSS and page cache.
- `nmt_total_mb`, `heap_comm_mb`, `heap_used_mb`, `gc_mb`, `threads_mb`, `metaspace_mb`, `code_mb`, `internal_mb`, `nmt_other_mb` — JVM Native Memory Tracking categories. `heap_comm_mb` is **committed (virtual)** heap, not necessarily resident.
- `non_jvm_mb` — estimate of memory outside JVM NMT accounting (RocksDB native, jemalloc retained/overhead, kernel page cache reclassification).
- `db_fds` — open file descriptors held by the DB.
- Extended cols: `proc_anon_mb`, `proc_priv_clean_mb`, `proc_priv_dirty_mb`, `proc_swap_mb` (from `/proc/1/smaps_rollup`); `cgrp_swapcached_mb`, `cgrp_anon_thp_mb` (from `memory.stat`); RocksDB JMX `rdb_memtables_mb`, `rdb_block_cache_mb`, `rdb_pending_compact_mb`, `rdb_table_readers_mb`, `rdb_sst_mb`.

### Interpreting `non_jvm_mb` drops

`non_jvm_mb` drops are **usually not** a JVM event or an explicit flush. The dominant causes are:

- **jemalloc purge** (`dirty_decay_ms` / `muzzy_decay_ms` returning dirty/muzzy pages to the OS), and
- **kernel page-cache reclassification** (anon ↔ file cache movement).

Use `nmt/analyze_drop.py --container <name>` to attribute a drop using the extended columns. Do **not** assume a 1:1 mapping between `rdb_block_cache_mb` changes and `non_jvm` drops: the RocksDB block cache is a **single shared LRU** across all DB instances, so it churns independently. `nmt.sh` records the block cache with the *first* JMX value (not a sum) — summing it across instances inflates it ~Nx.

### Why a breakdown plot can exceed the cgroup limit

`nmt/plot_nmt.py` stacks `heap_comm_mb` (JVM **committed/virtual** heap) together with resident components like `cache_mb` and `non_jvm_mb`. When committed heap is larger than the resident portion, the stacked total visually exceeds the hard cgroup limit even though actual resident memory (`cgrp_total_mb`) stays within bounds. Treat the breakdown plot as a **composition guide**, and `cgrp_total_mb` as the real number against the limit.

### `amd64` vs `arm64` crash analysis (and its confounds)

Observation: after ~24h, `amd64` nodes crashed while `arm64` nodes survived. `amd64` `node1` ran near its 6 GB cgroup limit with high swap (~2.8 GB) → swap death spiral; `arm64` nodes used far less swap and had more stable `non_jvm`.

**This was not a clean architecture comparison.** Three confounds (now fixed) were present:

1. **Different DB backend.** `amd64` nodes ran LevelDB (`-Dkeyvalue.datasource=leveldb` in `RSKJ_SYS_PROPS`), `arm64` nodes defaulted to RocksDB. LevelDB keeps **many `.ldb` files open** (hence `node1` showing ~410 `db_fds` — normal LevelDB behavior, not a leak), and lacks RocksDB's bounded shared block cache (`rsk.conf`: `database.rocksdb.sharedBlockCacheSize`, `maxOpenFiles = 15`).
2. **jemalloc not loaded on arm64.** `rsk/Dockerfile` hardcoded the x86 path for `LD_PRELOAD`, so arm64 containers silently fell back to glibc malloc. Now arch-aware (`x86_64-linux-gnu` vs `aarch64-linux-gnu`).
3. **Docker Desktop x86 emulation** for `amd64` containers on Apple Silicon adds overhead.

For a fair comparison, align across all nodes: same DB backend (`keyvalue.datasource`), same allocator (jemalloc actually loaded), and the same JVM/logging flags (`FLUSH_BLOCKS`, `DEFAULT_JVM_OPTS`, log level) — several of these were aligned in `docker-compose.rskj.yml`.

Update: all four miners now run **RocksDB** (`miner2`'s `-Dkeyvalue.datasource=leveldb` was removed and its volume re-cloned from a RocksDB node), so the DB-backend confound is gone for the current miner set. The one intentional outlier is `rskj-miner4`, the untuned baseline (no `MALLOC_CONF`, default block cache, default `WIRE_DELAY`).

## RSKj Sync Architecture & Optimization

This applies to the `repos/rskj` submodule (consensus-critical Java; built in Docker, not on the host — there is no local JVM, so changes must be compiled/tested via the Docker image build or CI).

### Long-sync state machine (`co.rsk.net.sync`)

`SyncProcessor` drives a state machine of `SyncState`s:

1. **Find connection point** — binary search for the highest common block with the peer.
2. **`DownloadingSkeletonSyncState`** — request skeleton(s) (sparse list of `BlockIdentifier` boundaries). NOTE: `expectedSkeletons` starts at 0 and the state transitions on the **first** skeleton response, so in practice only **one** skeleton (from the first responder, treated as the trusted/`selectedPeer`) is used.
3. **`DownloadingHeadersSyncState`** — download the headers for each skeleton chunk and validate them.
4. **`DownloadingBodiesSyncState`** — download bodies; this phase already supports multiple peers (segmented by skeleton), but is in practice limited by only one skeleton being collected.

Responses are matched to requests by message id in `SyncProcessor.pendingMessages` (`isPending` → `removePendingMessage` → `syncState.<handler>`). Per-state timeouts come from `BaseSyncState.tick` / `SyncConfiguration.getTimeoutWaitingRequest`.

### Header validation is anchored to the trusted skeleton

A header chunk is valid iff: (a) its size equals the count derived from the skeleton boundary, (b) the top header hash equals the skeleton boundary hash, and (c) intra-chunk parent linkage holds. **All three checks are against the trusted skeleton only** — so a chunk is correct regardless of which peer served it. This is what makes parallel, multi-peer header download safe.

### Optimization: parallel multi-peer header download

`DownloadingHeadersSyncState` was reworked from sequential single-peer to **parallel multi-peer** chunk download:

- Chunk descriptors are precomputed (1-based by skeleton link index; lower index = lower block numbers).
- Up to `maxConcurrentHeaderRequests` chunk requests are kept in flight, one per peer, fanned out across `peersInformation.getBestPeerCandidates()` (the trusted `selectedPeer` is always preferred/first).
- Responses are buffered and reassembled in skeleton order; bodies start only when all chunks complete.
- **Failure handling preserves the trust model:** if the **trusted peer** misbehaves/times out → abort the whole sync (legacy behavior). If a **helper peer** returns invalid data or times out → penalize via `peersInformation.reportEventToPeerScoring`, discard it for the session, and re-queue its chunk for another peer (ultimately the trusted peer), **without aborting**.
- Per-request timeouts are tracked per peer (`tick` iterates in-flight peers).

Setting `maxConcurrentHeaderRequests = 1` exactly reproduces the old sequential, single-peer behavior.

Files changed: `DownloadingHeadersSyncState.java` (rewrite), `SyncProcessor.startDownloadingHeaders` (passes `peersInformation`), `SyncConfiguration` (new field + getter + constructor overload), `RskSystemProperties`/`RskContext` (read the property), `reference.conf` + `expected.conf` (schema), and `DownloadingHeadersSyncStateTest` (updated for the new model + parallel/failover tests).

### Optimization: parallel multi-peer body download

`DownloadingBodiesSyncState` was **already** multi-peer: it splits the headers into segments based on the per-peer `skeletons` map and, in `onEnter`, dispatches a body request to every peer in `suitablePeers`; each peer then pipelines bodies independently and chunks are reassigned/failed-over on timeout or invalid data. The actual limiter was upstream: `DownloadingSkeletonSyncState` initialized `expectedSkeletons = 0` and therefore transitioned to header download on the **first** skeleton response, so the `skeletons` map ended up with a single entry → `suitablePeers` had a single peer → bodies were effectively serial.

Fix (in `DownloadingSkeletonSyncState`): `onEnter` now sets `expectedSkeletons = candidates.size()` and the state waits until **all** requested skeletons have been answered (or discarded) before transitioning, passing the trusted `selectedPeer`. Crucially, `onEnter` already sent a skeleton request to every best candidate, so this collects responses that were previously discarded — **no extra requests**. With multiple skeletons in the map, the existing body-segment machinery fans out body downloads across all responsive peers for free.

Safety / behavior notes:
- The `selectedPeerAnswered` guard means single-candidate setups (and the many unit tests where `getBestPeerCandidates()` is empty) still transition on the first response — **no behavior change** there.
- Each peer's skeleton is validated per-chunk against the actually-downloaded (trusted) headers in `getAvailableNodesIDSFor`, so a peer on a divergent chain is simply excluded from the chunks it can't serve — the multi-skeleton map is safe.
- Tradeoff: sync start now waits for the slowest best-peer's skeleton, bounded by `sync.timeoutWaitingRequest` (the existing `tick` fallback transitions with whatever skeletons arrived as long as the selected peer answered). In the simulation (local, fast regtest peers) this is negligible.

Files changed: `DownloadingSkeletonSyncState.java` (multi-skeleton collection) and `DownloadingSkeletonSyncStateTest` (added single- vs multi-candidate transition tests). `DownloadingBodiesSyncState` itself was left unchanged.

### Config knob

```
# rskj-core/src/main/resources/reference.conf  (under sync { })
sync {
    # Max header-chunk requests in flight to different peers at once.
    # >1 enables parallel multi-peer header download; 1 = legacy sequential.
    maxConcurrentHeaderRequests = 4
}
```

Override per node via `RSKJ_SYS_PROPS` (e.g. `-Dsync.maxConcurrentHeaderRequests=4`) or the node `.conf`.

### Remaining bottlenecks (not yet addressed)

- **Connection-point discovery** is sequential and single-peer (binary search against the selected peer). This is a candidate for a follow-up change but touches consensus-critical state timing, so it was left out of scope.
