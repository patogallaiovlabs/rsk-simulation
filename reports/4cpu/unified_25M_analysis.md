# Unified 25M Gas Performance Analysis Report (4 CPU)

This report provides a unified analysis of the performance across simulation categories configured with a **25M Gas Limit** using a **4 CPU** configuration.

## 📊 Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `25M_2h` | **1.460s** | 0.669s | 288.2% | 1641.4 MiB/s | 4.2 GiB |
| **Real-World** | `25M_16h` | **0.376s** | 0.467s | 487.5% | 2167.1 MiB/s | 9.2 GiB |

## 📊 Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `25M_2h` | **0.894s** | 0.402s | 75.6% | 308.2 MiB/s | 2.6 GiB |
| **Real-World** | `25M_16h` | **0.618s** | 0.933s | 159.9% | 819.4 MiB/s | 3.7 GiB |

---

## 🔍 Key Findings (4 CPU Analysis)

### 1. Improved Latency vs 2 CPU
Preliminary data shows that the 4 CPU configuration significantly reduces block processing time compared to the 2 CPU baseline, especially in computation-heavy scenarios.

### 2. Resource Headroom
CPU saturation is visibly lower, providing more headroom for spikes and reducing the risk of synchronization lag.

---

## 💡 Recommendation

The 25M Gas Limit is well-supported by the 4 CPU configuration.
