# Unified 7M Gas Performance Analysis Report (Worst-Case)

This report provides a unified analysis of the **least performant samples** across all simulation categories configured with a **7M Gas Limit**. By focusing on the worst-case samples, we establish a robust baseline for minimum expected performance on the target hardware.

## 📊 Worst-Case Summary (Miner1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `7M_24h` | **0.593s** | 0.448s | 72.1% | 163.1 MiB/s | 2.1 GiB |
| **Calldata** | `7M_8h` | **0.209s** | 0.222s | 159.7% | 556.2 MiB/s | 4.1 GiB |
| **Real-World** | `7M_12h` | **0.142s** | 0.354s | 97.0% | 321.1 MiB/s | 5.2 GiB |
| **Storage** | `size-7M_6hs_mt*` | **0.067s** | 0.131s | 45.3% | 169.8 MiB/s | 2.1 GiB |
| **Memory** | `7M` (Run 1) | **0.041s** | 0.049s | 34.6% | 38.8 MiB/s | 1.4 GiB |

## 📊 Worst-Case Summary (Node1)

| Category | Representative Sample | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | `7M_24h` | **0.452s** | 0.457s | 42.5% | 4.3 MiB/s | 1.6 GiB |
| **Calldata** | `7M_8h` | **0.073s** | 0.082s | 68.7% | 447.4 MiB/s | 3.9 GiB |
| **Real-World** | `7M_12h` | **0.158s** | 0.170s | 53.1% | 218.7 MiB/s | 3.8 GiB |
| **Storage** | `size-7M_6hs_mt*` | **0.060s** | 0.167s | 20.7% | 67.7 MiB/s | 2.0 GiB |
| **Memory** | `7M` (Run 1) | **0.024s** | 0.029s | 23.5% | 7.7 MiB/s | 1.3 GiB |

*\*MT = Multiple Transactions per block.*

---

## 🔍 Key Findings (Worst-Case Analysis)

### 1. The Real Bottleneck: Pure Computation
The **CPU Stress** test remains the most taxing on individual block processing time (**0.593s**), even compared to the worst-case Calldata or Real-World samples. This confirms that complex opcode execution is the mathematical ceiling for 7M scaling.

### 2. Physical Resource Saturation
- **CPU Overload**: In the **Calldata 8h** run, the average CPU usage reached **~160%** (on a 2-CPU miner), indicating that the node was operating at its functional limit for sustained periods.
- **Memory Ceiling**: The **Real-World 12h** run exhibits the highest memory consumption (**5.2 GB**), showing that long-duration network activity is the primary driver of RAM pressure.

### 3. I/O Resilience
The **Storage** and **Memory** categories remained highly performant even in their "worst" samples, with latencies staying below **0.07s**. This suggests that RSKj's state management is not the weak link at the 7M limit.

---

## 📈 Detailed Observations

### Peak Latencies (The Critical Outliers)
While the table shows averages, the peak latencies in these worst-case samples are the real risk factors:
- **Real-World (12h)**: 12.4s peak.
- **CPU (24h)**: 3.1s peak.
- **Calldata (8h)**: 3.4s peak.

### Data Availability Stress
The **Calldata** test remains the only category that consistently pushes disk write throughput above **500 MiB/s**, confirming that data-heavy blocks are the primary driver of I/O wait.

---

## 💡 Recommendation
The 7M Gas Limit is fundamentally stable but shows signs of **Resource Creep** in real-world scenarios over longer durations (12h+).
- **Monitoring**: Memory growth over time in 7M real-world scenarios should be monitored for potential leaks or non-optimal cache growth.
- **Hardware**: 2 CPU cores are the absolute minimum; 4 cores are recommended for 7M to avoid the 97%+ saturation observed in the 12h real-world run.
