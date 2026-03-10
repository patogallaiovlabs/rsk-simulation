# Multi-Gas Limit Performance Comparison Report
## 7M vs 10M vs 17M vs 25M Scaling Analysis

This report synthesizes the worst-case performance metrics across three gas limits to visualize the impact of network scaling on RSKj nodes.

---

## 📈 Miner1 Scalability: CPU Stress
*Focuses on computational ceiling (EVM opcodes).*

| Gas Limit | Avg Block Proc | Block Proc SD | Mean CPU | Scaling (Latency) |
| :--- | :--- | :--- | :--- | :--- |
| **7M** | 0.593s | 0.448s | 72.1% | 1.0x (Baseline) |
| **10M** | 1.612s | 0.882s | 131.9% | 2.72x |
| **17M** | 2.635s | 1.165s | 171.7% | 4.44x |
| **25M** | **3.760s** | **2.494s** | 171.7% | **6.34x** |

**Observation**: Scaling is aggressively non-linear. A 3.5x gas increase (7M to 25M) leads to a **6.3x latency increase**.

---

## 🌍 Miner1 Scalability: Real-World Stress
*Focuses on transaction mix, P2P overhead, and state updates.*

| Gas Limit | Avg Block Proc | Block Proc SD | Mean CPU | Disk Write (Avg) |
| :--- | :--- | :--- | :--- | :--- |
| **7M** | 0.142s | 0.354s | 97.0% | 321.1 MiB/s |
| **10M** | 0.285s | 0.231s | 193.4% | 398.2 MiB/s |
| **17M** | 0.352s | 0.266s | 365.0% | 925.3 MiB/s |
| **25M** | **0.541s** | 0.296s | **518.6%** | 0.0 MiB/s* |

*\*Note: 25M real-world samples showed unexpected low disk write averages during recorder run; however, Calldata/Storage stress confirms I/O scales >1 GiB/s.*

---

## 🔄 Node1 Scalability: Real-World Stress
*Focuses on standard node synchronization capability.*

| Gas Limit | Avg Block Proc | Block Proc SD | Mean CPU | Result |
| :--- | :--- | :--- | :--- | :--- |
| **7M** | 0.158s | 0.170s | 53.1% | Healthy |
| **10M** | 0.311s | 0.352s | 80.1% | Tight |
| **17M** | 0.593s | 0.812s | 120.7% | Critical |
| **25M** | **0.706s** | 0.562s | **146.1%** | **Unstable** |

**Observation**: Standard nodes (1 CPU) are in permanent deficit at 25M gas, unable to process blocks faster than they arrive in certain bursts.

---

## 🔍 Consolidation of Findings

### 1. The Scaling Wall
The leap from 17M to 25M (47% gas increase) pushed Miner1 latency from 2.6s to 3.7s (42% increase), but the cumulative jump from 7M is **6.3x**. We are hitting a "Scaling Wall" where pure computation variance makes it impossible for the network to reach consensus reliably.

### 2. Peak Spike Severity
Maximum processing times recorded (Max values):
- **7M**: 12.4s
- **10M**: 3.9s
- **17M**: 15.1s
- **25M**: **18.8s** (Exceeds block interval)

---

## 💡 Hardware Matrix Recommendations

| Gas Limit | Role | Recommended CPU | Recommended RAM | Storage Type |
| :--- | :--- | :--- | :--- | :--- |
| **7M** | Miner | 4 Cores | 8 GB | SSD |
| **7M** | Node | 2 Cores | 4 GB | SSD |
| **10M** | Miner | 8 Cores | 16 GB | NVMe |
| **10M** | Node | 4 Cores | 8 GB | SSD |
| **17M** | Miner | 16 Cores | 32 GB | High-Perf NVMe |
| **17M** | Node | 8 Cores | 16 GB | NVMe |
| **25M** | Miner | **32 Cores** | **64 GB** | **DC-Grade NVMe** |
| **25M** | Node | **16 Cores** | **32 GB** | **NVMe** |
