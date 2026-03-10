# Unified 17M Gas Performance Analysis Report (Worst-Case)

This report provides a unified analysis of the **least performant samples** across all simulation categories configured with a **17M Gas Limit**. This establishes the "performance floor" for a significant increase over the 7M and 10M benchmarks.

## 📊 Worst-Case Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `17M_1h` | **2.635s** | 1.165s | 171.7% | 175.5 MiB/s | 1.2 GiB |
| **Calldata** | `17M_5h` | **0.098s** | 0.090s | 54.9% | 208.0 MiB/s | 3.3 GiB |
| **Real-World** | `17M_2h_last` | **0.352s** | 0.266s | 365.0% | 925.3 MiB/s | 4.7 GiB |
| **Storage** | `size-17M_24hs` | **0.102s** | 0.188s | 47.2% | 314.9 MiB/s | 3.5 GiB |

*\*Note: CPU usage for Miner1 in Real-World exceeds 300%, indicating extreme saturation well beyond the nominal 2-CPU assignment.*

## 📊 Worst-Case Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `17M_1h` | **1.212s** | 0.694s | 58.5% | 2.3 MiB/s | 1.1 GiB |
| **Calldata** | `17M_5h` | **0.044s** | 0.054s | 31.1% | 180.1 MiB/s | 3.1 GiB |
| **Real-World** | `17M_2h_last` | **0.593s** | 0.812s | 120.7% | 361.1 MiB/s | 3.0 GiB |
| **Storage** | `size-17M_24hs` | **0.109s** | 0.227s | 22.7% | 194.2 MiB/s | 3.4 GiB |

---

## 🔍 Key Findings (17M Scaling)

### 1. Critical Latency Thresholds
At 17M gas, the **CPU Stress** average block processing time for Miner1 reaches **2.63s**. In the latest **Real-World** stress tests, Node1 average latency jumped to **0.593s**, which is significant for a non-mining node and indicates network-wide strain.

### 2. Excessive Jitter (Standard Deviation)
The **Block Proc SD** for Node1 in real-world scenarios hit **0.812s**. This signifies extreme volatility in synchronization time; while the average is manageable, the high jitter causes inconsistent peer-to-peer performance.

### 3. Resource Exhaustion
- **CPU Saturation**: Miner1's **365% CPU usage** and Node1's **120% usage** (on a 1-CPU assignment) confirm total resource exhaustion. The background work of managing a 17M gas block interval exceeds the reserved capacity.
- **I/O Heat**: Real-World Disk Write throughput has peaked at **925.3 MiB/s**. This is an extreme baseline requirement for secondary storage.

### 4. Stability & Variance (SD)
- **Non-EVM Overhead**: The high latency in Node1 during real-world tests (**0.59s**) vs synthetic CPU tests (**1.2s**) shows that while pure compute is slower, the *complexity* of the real-world mix at 17M gas creates more unpredictable synchronization patterns.

### 5. Tail Latencies (Extreme Spikes)
The maximum processing times observed in these worst-case samples are a blocking risk for mining:
- **Real-World (17M_2h_last)**: Miner1 hit a **2.2s** peak, but other 17M samples (like 4h) recorded up to **15.16s**.
- **CPU (1h)**: Node1 recorded a **3.9s** peak.
These spikes represent "dead zones" where the node is unable to process incoming transactions or maintain P2P heartbeat.

---

## 📈 Detailed Observations

### Mining Overhead vs. Synchronizing
In the **CPU Stress** test, Miner1 takes **2.6s** while Node1 takes **1.2s**. This gap (greater than at 7M or 10M) shows that the complexity of *constructing* a 17M gas block is disproportionately higher than simply *verifying* it.

### Data Availability Limits
Similar to lower gas limits, the **Calldata** tests drive the most consistent high-volume Disk Writes, but at 17M, the sustained pressure on the database commit cycle is beginning to impact the baseline block processing average.

---

## 💡 Recommendation
The 17M Gas Limit is **not recommended for current hardware configurations** (2 CPU, 8GB RAM).
- **Minimum Specs**: If 17M is desired, mining nodes **must use 8 CPU cores** and high-performance NVMe storage.
- **Propagation Risk**: The combination of 2.6s average latency and 1.1s SD creates a high risk of network-wide synchronization delays and block re-orgs.
