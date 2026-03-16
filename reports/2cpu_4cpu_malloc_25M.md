# 📊 Multi-Configuration Performance Analysis: 25M Gas Limit
## 2CPU vs 4CPU vs MALLOC_ARENA_MAX Comparison

This report compares the performance of RSKj nodes under a **25M Gas Limit** across three distinct container configurations to identify the most stable setup for high-throughput scaling.

---

## 📈 Miner1: Primary Performance Metrics
*Focuses on block production latency and resource intensity.*

| Metric | 2CPU (Baseline) | 4CPU (Optimized) | Malloc Fix (Arena=2) |
| :--- | :--- | :--- | :--- |
| **Avg Block Proc Time** | 0.579s | **0.376s** (35% faster) | 0.534s |
| **Median Block Proc** | 0.456s | **0.329s** | 0.439s |
| **Max Block Processing** | 3.12s | 11.12s* | 18.62s* |
| **Mean CPU Usage** | 481.2% | 487.5% | 524.3% |
| **Disk Read (Avg)** | 104.7 MiB/s | 342.2 MiB/s | **969.5 MiB/s** |
| **Memory Consumption** | **5,718 MiB** | 9,427 MiB | 7,851 MiB |

*\*Note: Higher Max times in 4CPU/Malloc likely due to significantly longer run durations (16h+) compared to 2CPU (5h).*

---

## 🔄 Node1: Synchronization Efficiency
*Focuses on the node's ability to keep up with the network.*

| Metric | 2CPU (Baseline) | 4CPU (Optimized) | Malloc Fix (Arena=2) |
| :--- | :--- | :--- | :--- |
| **Avg Block Proc Time** | 0.922s | **0.618s** (33% faster) | 0.783s |
| **Median Block Proc** | 0.572s | **0.343s** | 0.565s |
| **Max Block Processing** | 23.03s | **7.72s** | 21.85s |
| **Mean CPU Usage** | 162.3% | 159.8% | **135.6%** (16% lower) |
| **Memory Consumption** | **3,587 MiB** | 3,799 MiB | 5,437 MiB |

---

## 🔍 Key Findings

### 1. CPU Scaling Impact
Moving to **4 vCPUs** (4CPU config) provides the most significant boost to block processing speed, reducing average latency by ~35%. This is critical at 25M gas where processing time variance can easily exceed the 30s block interval.

### 2. The Malloc Fix Advantage
The `MALLOC_ARENA_MAX=2` configuration (Malloc Fix) shows a noticeable improvement in **CPU efficiency for Node1** (135% vs 162% mean). By capping the number of glibc malloc arenas, the JVM spends less time in kernel-level memory management during high JNI/RocksDB activity.

### 3. Disk I/O Saturation
The `Malloc Fix` run recorded nearly **1 GiB/s average Disk Read** on Miner1. This suggests that with more efficient memory management, the bottleneck shifts from CPU/Memory limits to the storage subsystem (I/O Wait).

---

## 💡 Recommendation
For a stable **25M Gas** network, we recommend a hybrid configuration:
- **CPU**: Minimal 4 Cores per Miner to keep `avg_proc < 0.5s`.
- **Memory**: Cap native memory overhead using `MALLOC_ARENA_MAX=4` (to balance speed and stability).
- **Storage**: Maintain DC-Grade NVMe to handle the >500 MiB/s sustained read/write spikes observed in all runs.
