# Unified 25M Gas Performance Analysis Report (Worst-Case)

This report provides a unified analysis of the **least performant samples** across all simulation categories configured with a **25M Gas Limit**. This establishes the "performance floor" for a massive 3.5x increase over the 7M baseline.

## 📊 Worst-Case Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `25M_1h` | **3.760s** | 2.494s | 171.7% | 175.5 MiB/s | 1.3 GiB |
| **Calldata** | `25M_3h` | **0.191s** | 0.803s | 106.2% | 923.4 MiB/s | 4.0 GiB |
| **Real-World** | `25M_2h` | **0.541s** | 0.296s | **518.6%** | 0.0 MiB/s | 4.8 GiB |
| **Storage** | `size-25M_24hs` | **0.238s** | 0.651s | 62.0% | 493.0 MiB/s | 3.7 GiB |

*\*Note: CPU usage for Miner1 in Real-World is exponentially higher than at 17M, indicating total system saturation.*

## 📊 Worst-Case Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `25M_1h` | **2.025s** | 1.397s | 58.5% | 2.3 MiB/s | 1.2 GiB |
| **Calldata** | `25M_3h` | **0.073s** | 0.078s | 64.2% | 790.5 MiB/s | 3.9 GiB |
| **Real-World** | `25M_2h` | **0.706s** | 0.562s | **146.1%** | 484.1 MiB/s | 3.0 GiB |
| **Storage** | `size-25M_24hs` | **0.226s** | 0.772s | 39.2% | 380.4 MiB/s | 3.7 GiB |

---

## 🔍 Key Findings (25M Scaling)

### 1. Exponential Latency Growth
At 25M gas, Miner1 processing time reaches **3.76s** in CPU stress. This is a **~6.3x increase** from the 7M baseline, while the gas limit only increased by 3.5x. The scaling is clearly non-linear and approaching dangerous levels for block interval consistency.

### 2. High Jitter (Processing Variance)
The Standard Deviation for Miner1 CPU stress hit **2.49s**. Combined with the 3.76s average, this means a significant volume of blocks take **over 6 seconds** to reach consensus, creating a high risk of orphan blocks.

### 3. Absolute Resource Depletion
- **CPU saturation**: Miner1 hit **518.6% CPU usage**. On a 2-core setup (4 threads visible to JVM), the node is constantly thrashing to keep up with block assembly.
- **Node1 Burden**: Even standard synchronizing nodes (Node1) are failing to stay under 1 CPU core usage during real-world stress (**146%**).

---

## 📉 Detailed Observations

### Peak Spikes
In the **Calldata 3h** and **Storage 24hs** runs, we observed peak processing times of **15.1s** and **18.8s** respectively. These peaks represent "stopped-the-world" moments where the node is completely unresponsive to the network during block processing.

### I/O Pressure
Calldata Disk Write throughput at 25M reaches **923 MiB/s** average, confirming that the commitment phase for very large blocks is a secondary bottleneck after pure compute.

---

## 💡 Recommendation
**The 25M Gas Limit is critically unstable for the current hardware configuration.**
- **Hardware Upgrade Mandatory**: Minimum Specs for 25M would require **32 Cores / 64 GB RAM** and high-performance DC-grade NVMe.
- **Protocol Risk**: At this gas level, the "Safety Margin" (Block Proc Time / Block Target Time) is below 40% for Miner1, which is insufficient for reliable P2P propagation.
