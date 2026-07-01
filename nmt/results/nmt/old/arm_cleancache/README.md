# RSKj Simulation Results Summary

Generated on: 2026-06-24 10:03:33

This directory contains Native Memory Tracking (NMT) plots and a summary of the node configurations used during the simulation.

## 📈 Visualizations

- [Total Memory Usage](nmt_total_memory.png)
- [Memory Breakdown (per Node)](nmt_breakdown.png)

## 🔧 Node Configurations (from Docker Compose)

| Node | Role | CPU Limit | Memory Limit | JVM Options | Malloc Arena |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **rskj-miner1** | ⛏️ Miner | 4.0 | 5G | `-Xms3G -Xmx3G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | N/A |
| **rskj-miner2** | ⛏️ Miner | 4.0 | 5G | `-Xms3G -Xmx3G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | N/A |
| **rskj-miner3** | ⛏️ Miner | 4.0 | 5G | `-Xms3G -Xmx3G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | N/A |
| **rskj-miner4** | ⛏️ Miner | 4.0 | 5G | `-Xms3G -Xmx3G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | N/A |
| **rskj-node1** | 🔗 Node | 2.0 | 6G | `-Xms4G -Xmx4G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | N/A |
| **rskj-node2** | 🔗 Node | 2.0 | 6G | `-Xms4G -Xmx4G -XX:MaxDirectMemorySize=512M -XX:MaxMetaspaceSize=256m -XX:CompressedClassSpaceSize=256m -XX:ReservedCodeCacheSize=128m -XX:NativeMemoryTracking=summary` | N/A |
