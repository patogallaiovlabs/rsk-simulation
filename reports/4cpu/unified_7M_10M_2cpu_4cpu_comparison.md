# Unified Analysis: 7M vs 10M Gas Comparison (2 CPU vs 4 CPU)

This report provides a head-to-head comparison of RSKj node performance between **7M** and **10M** Gas Limits, across both **2 CPU** and **4 CPU** hardware configurations. Data is sourced from the representative "worst-case" unified reports for each setup.

## 📊 Miner1 Performance Comparison

| Gas Limit | Hardware | Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **7M** | 2 CPU | CPU | `7M_24h` | **0.593s** | 0.448s | 72.1% |
| **7M** | 4 CPU | CPU | `7M_16h` | **0.364s** | 0.189s | 124.5% |
| **10M** | 2 CPU | CPU | `10M_1h` | **1.612s** | 0.882s | 131.9% |
| **10M** | 4 CPU | CPU | `10M_4h` | **0.516s** | 0.278s | 138.9% |
| | | | | | | |
| **7M** | 2 CPU | Real-World | `7M_12h` | **0.142s** | 0.354s | 97.0% |
| **7M** | 4 CPU | Real-World | `7M_1h` | **0.060s** | 0.041s | 103.8% |
| **10M** | 2 CPU | Real-World | `10M_1h` | **0.285s** | 0.231s | 193.4% |
| **10M** | 4 CPU | Real-World | `10M_2h` | **0.106s** | 0.050s | 157.3% |

## 📊 Node1 Performance Comparison

| Gas Limit | Hardware | Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **7M** | 2 CPU | CPU | `7M_24h` | **0.452s** | 0.457s | 42.5% |
| **7M** | 4 CPU | CPU | `7M_16h` | **0.232s** | 0.119s | 40.9% |
| **10M** | 2 CPU | CPU | `10M_1h` | **1.121s** | 0.795s | 60.9% |
| **10M** | 4 CPU | CPU | `10M_4h` | **0.325s** | 0.174s | 40.4% |
| | | | | | | |
| **7M** | 2 CPU | Real-World | `7M_12h` | **0.158s** | 0.170s | 53.1% |
| **7M** | 4 CPU | Real-World | `7M_1h` | **0.044s** | 0.029s | 44.3% |
| **10M** | 2 CPU | Real-World | `10M_1h` | **0.311s** | 0.352s | 80.1% |
| **10M** | 4 CPU | Real-World | `10M_2h` | **0.087s** | 0.057s | 54.5% |

---

## 🔍 Key Insights

### 1. Scaling Mitigates the 10M Penalty
On 2 CPU hardware, moving from 7M to 10M gas causes a massive **~2.7x increase** in worst-case CPU processing time (0.59s -> 1.61s). Upgrading to 4 CPU hardware reduces the 10M processing time to **0.51s**, which is actually lower than the 7M baseline on 2 CPUs.

### 2. High Jitter Recovery
The Standard Deviation (SD) for CPU-heavy blocks at 10M drops from **0.88s** (2 CPU) to **0.27s** (4 CPU) for Miner1. This indicates that the 4 CPU config not only processes faster but also much more predictably, reducing the risk of block propagation spikes.

---

## 💡 Recommendation
The move to a **10M Gas Limit** is highly viable but strongly recommended to be paired with **4 CPU cores** for mining and high-traffic nodes to maintain the performance baseline established by the 2 CPU/7M configuration.
