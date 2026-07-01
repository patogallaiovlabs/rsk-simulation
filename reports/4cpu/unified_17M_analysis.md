# Unified 17M Gas Performance Analysis Report (4 CPU)

This report provides a unified analysis of the performance across simulation categories configured with a **17M Gas Limit** using a **4 CPU** configuration.

## 📊 Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `17M_14h` | **0.912s** | 0.466s | 191.9% | 1248.0 MiB/s | 4.7 GiB |
| **Real-World** | `17M_1h` | **0.166s** | 0.076s | 299.9% | 1120.8 MiB/s | 4.2 GiB |

## 📊 Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `17M_14h` | **0.565s** | 0.282s | 50.6% | 201.5 MiB/s | 2.7 GiB |
| **Real-World** | `17M_1h` | **0.237s** | 0.333s | 56.8% | 204.6 MiB/s | 1.6 GiB |

---

## 🔍 Key Findings (4 CPU Analysis)

### 1. Improved Latency vs 2 CPU
Preliminary data shows that the 4 CPU configuration significantly reduces block processing time compared to the 2 CPU baseline, especially in computation-heavy scenarios.

### 2. Resource Headroom
CPU saturation is visibly lower, providing more headroom for spikes and reducing the risk of synchronization lag.

---

## 💡 Recommendation

The 17M Gas Limit is well-supported by the 4 CPU configuration.
