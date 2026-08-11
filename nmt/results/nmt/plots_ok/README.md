# RSKj Simulation Results Summary

Generated on: 2026-08-04 10:22:03

This directory contains Native Memory Tracking (NMT) plots and a summary of the node configurations used during the simulation.

## 📈 Visualizations

- [Total Memory Usage](nmt_total_memory.png)
- [Memory Breakdown (per Node)](nmt_breakdown.png)

## 🔧 Node Configurations (from Docker Compose)

RocksDB columns are derived from `SHARED_BLOCK_CACHE_SIZE` and the `-Ddatabase.rocksdb.compressionType.*` system properties in `RSKJ_SYS_PROPS`.

| Node | Role | CPU Limit | Memory Limit | JVM Options | Flush Blocks | Jemalloc | Shared Block Cache | DB Compression |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **rskj-miner1** | ⛏️ Miner | 2.0 | 6G | `-Xms4G -Xmx4G -XX:NativeMemoryTracking=summary` | 10 | enabled | not set | none |
| **rskj-miner2** | ⛏️ Miner | 2.0 | 6G | `-Xms4G -Xmx4G -XX:NativeMemoryTracking=summary` | 10 | enabled | not set | none |
| **rskj-miner3** | ⛏️ Miner | 2.0 | 6G | `-Xms4G -Xmx4G -XX:NativeMemoryTracking=summary` | 100 | enabled | not set | none |
| **rskj-miner4** | ⛏️ Miner | 2.0 | 5G | `-Xms3G -Xmx3G -XX:NativeMemoryTracking=summary` | 10 | enabled | not set | none |
| **rskj-node1** | 🔗 Node | 2.0 | 6G | `-Xms4G -Xmx4G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | 100 | enabled | 1M | none |
| **rskj-node2** | 🔗 Node | 2.0 | 6G | `-Xms4G -Xmx4G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | 100 | enabled | 1M | none |
