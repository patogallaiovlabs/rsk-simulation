# RSKj Simulation Results Summary

Generated on: 2026-03-16 10:15:07

This directory contains Native Memory Tracking (NMT) plots and a summary of the node configurations used during the simulation.

## 📈 Visualizations

- [Total Memory Usage](nmt_total_memory.png)
- [Memory Breakdown (per Node)](nmt_breakdown.png)

## 🔧 Node Configurations (from Docker Compose)

| Node | Role | CPU Limit | Memory Limit | JVM Options | Malloc Arena |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **rskj-miner1** | ⛏️ Miner | 4.0 | 8G | `-Xms4G -Xmx5G -XX:MaxDirectMemorySize=2G -XX:NativeMemoryTracking=summary` | 6 |
| **rskj-miner2** | ⛏️ Miner | 4.0 | 8G | `-Xms4G -Xmx4G -XX:MaxDirectMemorySize=2G -XX:NativeMemoryTracking=summary` | 8 |
| **rskj-node1** | 🔗 Node | 1.0 | 6G | `-Xms3G -Xmx4G -XX:MaxDirectMemorySize=1G -XX:NativeMemoryTracking=summary` | 4 |
| **rskj-node2** | 🔗 Node | 2.0 | 6G | `-Xms3G -Xmx4G -XX:MaxDirectMemorySize=1G -XX:NativeMemoryTracking=summary` | N/A |
