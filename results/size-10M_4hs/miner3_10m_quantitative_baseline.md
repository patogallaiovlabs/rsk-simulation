# Miner 3 Quantitative Performance Baseline (10M Gas)

This report provides a strict quantitative performance analysis of `rskj-miner3` based on simulation datasets. All metrics have been normalized and statistically aggregated to establish a technical baseline.

## 1. Summary Metrics Table

| Category | Metric | Unit | Mean / Avg | Median | Min | Max |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Processing** | Block Processing Time | s | 0.156 | 0.135 | 0.000 | 0.548 |
| | Block Execution (JMX) | s | 0.090 | 0.072 | 0.025 | 0.659 |
| | Gas Consumed (per block) | units | 8.96M | 9.00M | 0.00 | 9.00M |
| **Resources** | CPU Usage | % | 26.26 | 19.50 | 1.44 | 184.00 |
| | Memory Usage (RSS) | MiB | 3192.5 | 3215.4 | 2990.1 | 3491.8 |
| | JVM Heap Used | MiB | 2044.4 | 2037.8 | 1382.4 | 2734.1 |
| | JVM Heap Allocated | MiB | 2969.6 | 2969.6 | 2969.6 | 2969.6 |
| **Disk I/O** | Disk Read | MiB/s | 0.121 | 0.035 | 0.000 | 3.650 |
| | Disk Write | MiB/s | 0.166 | 0.011 | 0.007 | 5.540 |
| **Network** | Network Ingress | KiB/s | 2.96 | 3.02 | 2.16 | 4.33 |
| | Network Egress | KiB/s | 11.38 | 11.40 | 10.60 | 12.60 |
| **JVM GC** | GC Copy Time | s | 0.0035 | 0.0026 | 0.000 | 0.042 |
| | GC MarkSweep Time | s | 0.0000 | 0.0000 | 0.000 | 0.000 |
| **State** | Block Difficulty | - | 32.61 | 32.90 | 22.6 | 41.0 |

---

## 2. Visual Distributions

![Miner 3 Performance Distributions](miner3_10m_performance_research_dashboard.png)

---

## 3. Statistical Analysis

### 3.1 Processing Performance
*   **Efficiency**: The node maintains a highly efficient block processing profile with a median time of **135ms**. Even at its peak (**548ms**), it remains well within the expected limits for a 10M gas configuration.
*   **Execution vs. Processing**: Block execution accounts for approximately **58%** of the total processing time (Mean 0.090s vs 0.156s), suggesting overhead in IO or verification steps outside the core execution engine.

### 3.2 Resource Utilization
*   **CPU Volatility**: While the average CPU load is low (**26.3%**), the 184% maximum indicates significant bursting during block production or heavy validation cycles. The distribution is highly right-skewed.
*   **Memory Stability**: RSS memory is extremely stable around **3.1 GiB**, indicating no leaks and predictable footprint.
*   **Heap Management**: The JVM uses roughly **69%** of its allocated heap on average. GC Copy cycles are frequent but very short (3.5ms avg), maintaining high application responsiveness.

### 3.3 IO & Network
*   **Disk Footprint**: Disk activity is minimal, with throughput rarely exceeding **5.54 MiB/s**. This confirms the simulation is not IO-bound.
*   **Network Balance**: Egress traffic (**11.38 KiB/s**) is significantly higher than ingress (**2.96 KiB/s**), which is consistent with a miner primarily broadcasting new blocks and transactions.

### 3.4 Blockchain State
*   **Stability**: Block difficulty shows moderate variance (Std Dev ~3.5), indicating a relatively stable mining environment over the 4-hour period.
*   **Uncles**: A total of **33** uncle blocks were observed for `miner3`, reflecting the competitive nature of the simulation.
