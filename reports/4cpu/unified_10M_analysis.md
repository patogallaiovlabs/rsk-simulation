# Unified 10M Gas Performance Analysis Report (4 CPU)

This report provides a unified analysis of the performance across simulation categories configured with a **10M Gas Limit** using a **4 CPU** configuration.

## 📊 Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `10M_4h` | **0.516s** | 0.278s | 138.9% | 875.1 MiB/s | 4.2 GiB |
| **Real-World** | `10M_2h` | **0.106s** | 0.050s | 157.3% | 703.1 MiB/s | 5.3 GiB |

## 📊 Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `10M_4h` | **0.325s** | 0.174s | 40.4% | 117.0 MiB/s | 2.5 GiB |
| **Real-World** | `10M_2h` | **0.087s** | 0.057s | 54.5% | 145.4 MiB/s | 3.3 GiB |

---

## 🔍 Key Findings (4 CPU Analysis)

### 1. Improved Latency vs 2 CPU
Preliminary data shows that the 4 CPU configuration significantly reduces block processing time compared to the 2 CPU baseline, especially in computation-heavy scenarios.

### 2. Resource Headroom
CPU saturation is visibly lower, providing more headroom for spikes and reducing the risk of synchronization lag.

---

## 💡 Recommendation

The 10M Gas Limit is well-supported by the 4 CPU configuration.
