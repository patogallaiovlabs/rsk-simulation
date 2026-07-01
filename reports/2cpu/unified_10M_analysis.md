# Unified 10M Gas Performance Analysis Report (Worst-Case)

This report provides a unified analysis of the **least performant samples** across all simulation categories configured with a **10M Gas Limit**. This establishes the "performance floor" for a 40% increase over the 7M limit.

## 📊 Worst-Case Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `10M_1h` | **1.612s** | 0.882s | 131.9% | 136.7 MiB/s | 1.2 GiB |
| **Calldata** | `10M_18h` | **0.073s** | 0.046s | 68.1% | 489.6 MiB/s | 3.8 GiB |
| **Real-World** | `10M_1h` | **0.285s** | 0.231s | 193.4% | 398.2 MiB/s | 5.0 GiB |
| **Storage** | `size-10M_4hs` | **0.065s** | 0.130s | 42.5% | 215.4 MiB/s | 3.8 GiB |

## 📊 Worst-Case Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `10M_1h` | **1.121s** | 0.795s | 60.9% | 2.0 MiB/s | 1.1 GiB |
| **Calldata** | `10M_18h` | **0.033s** | 0.024s | 27.3% | 359.1 MiB/s | 3.7 GiB |
| **Real-World** | `10M_1h` | **0.311s** | 0.352s | 80.1% | 157.5 MiB/s | 3.7 GiB |
| **Storage** | `size-10M_4hs` | **0.061s** | 0.160s | 17.8% | 96.7 MiB/s | 3.7 GiB |

---

## 🔍 Key Findings (10M vs 7M)

### 1. Significant Latency Escalation
At 10M gas, the **CPU Stress** average block processing time reaches **1.61s** (vs 0.59s at 7M). This represents a **~2.7x increase** in processing time for a **1.4x increase** in gas, indicating that computational overhead scales non-linearly at these limits.

### 2. Physical Limits (CPU & RAM)
- **CPU Saturation**: Miner1 consistently reaches nearly **200% CPU** (utilizing both assigned cores) in Real-World scenarios. Node1 (assigned 1 CPU) hit **80%** occupancy, leaving very little headroom for peak spikes.
- **Memory Pressure**: Real-World memory usage for Miner1 hit **5.0 GB**. Given that some containers are assigned 8GB, this is healthy, but Node1 (assigned 4GB) is operating near its memory limit with **3.7 GB** usage.

### 3. Stability & Variance (SD)
- **High Jitter**: The **CPU Stress** test shows a very high Standard Deviation (**0.88s** for Miner1 and **0.79s** for Node1). This indicates extreme variability in processing time for compute-heavy blocks at 10M.
- **Predictable I/O**: Conversely, **Calldata** and **Storage** tests show much lower SD (**0.02s - 0.16s**), meaning data-heavy and state-heavy blocks have very consistent processing times even at higher gas limits.

### 4. Tail Latency Risks
While averages are under 0.3s for Real-World, the maximum processing times recorded were:
- **CPU (Node1)**: 3.93s peak.
- **Real-World (Miner1)**: 1.71s peak.
- **Real-World (Node1)**: 3.61s peak.
These peaks are manageable within the 15s/30s block time but reduce the safety margin for block propagation.

---

## 📉 Detailed Observations

### I/O Consistency
Despite the gas increase, **Storage** and **Calldata** I/O throughput (Disk Write) remained within similar ranges to the 7M tests (**200-500 MiB/s**). This suggests that the I/O layer is highly optimized and can absorb the extra transaction volume without proportional latency increases.

### Miner Overhead
Miner1 exhibits significantly more CPU consumption and Block Processing time in the CPU Stress test compared to Node1 (**1.61s vs 1.12s**). This confirms that the block assembly and metadata management for 10M gas blocks adds significant overhead to the mining process itself.

---

## 💡 Recommendation
The 10M Gas Limit is viable but **requires 4 CPU cores** for mining nodes to maintain healthy headroom.
- **Node1 Configuration**: Using 1 CPU and 4GB RAM for a "standard" node at 10M is tight. Increased resource allocation (2 CPU, 8GB) is recommended to prevent sync lag during high-activity periods.
- **Processing Overhead**: Further analysis of the JMX metrics for 10M runs showed that EVM execution represents an even smaller fraction of total processing time, reinforcing that "non-EVM" overhead is the scaling bottleneck.
