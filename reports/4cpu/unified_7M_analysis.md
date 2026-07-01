# Unified 7M Gas Performance Analysis Report (4 CPU)

This report provides a unified analysis of the performance across simulation categories configured with a **7M Gas Limit** using a **4 CPU** configuration.

## 📊 Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `7M_16h` | **0.364s** | 0.189s | 124.5% | 691.7 MiB/s | 5.3 GiB |
| **Real-World** | `7M_1h` | **0.060s** | 0.041s | 103.8% | 377.4 MiB/s | 3.3 GiB |

## 📊 Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `7M_16h` | **0.232s** | 0.119s | 40.9% | 81.9 MiB/s | 2.7 GiB |
| **Real-World** | `7M_1h` | **0.044s** | 0.029s | 44.3% | 53.5 MiB/s | 2.0 GiB |

---

## 🔍 Key Findings (4 CPU Analysis)

### 1. Improved Latency vs 2 CPU
Preliminary data shows that the 4 CPU configuration significantly reduces block processing time compared to the 2 CPU baseline, especially in computation-heavy scenarios.

### 2. Resource Headroom
CPU saturation is visibly lower, providing more headroom for spikes and reducing the risk of synchronization lag.

---

## 💡 Recommendation

The 7M Gas Limit is well-supported by the 4 CPU configuration.
