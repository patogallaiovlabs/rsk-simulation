# Granular Simulation Analysis Report (7M Gas Limit)

This report provides a detailed, per-node analysis of the simulation results for the 7M gas limit scenario (`size-7M_4hs`), serving as a baseline for future comparisons.

## 1. Node Configurations & Participation

Based on `README.md` and participation metrics:

| Node | Type | Flush Interval | Participation Status | Telemetry Captured |
| :--- | :--- | :--- | :--- | :--- |
| `rskj-miner1` | Miner | 100 blocks | Active | Full |
| `rskj-miner2` | Miner | 1000 blocks | Active | Full |
| `rskj-miner3` | Miner | 100 blocks | Active | Minimal (Flush/Difficulty only) |
| `rskj-miner4` | Miner | 100 blocks | Active | Full |
| `rskj-node1` | Node | 100 blocks | Active | Full |
| `rskj-node2` | Node | 100 blocks | Active | Minimal (Flush/Difficulty only) |

**Observation:** `miner3` and `node2` participate in block production and consensus (showing uncles and difficulty data) but are missing from most core performance telemetry (CPU, Memory, Network).

## 2. Block Processing Performance

*   **Average Processing Time:**
    *   `miner2` (1000 blocks flush) shows the best performance with an average of **0.00247s** per block.
    *   Nodes with 100 blocks flush (`miner1`, `miner4`, `node1`) range between **0.005s - 0.007s**.
*   **Correlation:** The lower flush frequency of `miner2` directly correlates with a ~50% reduction in average block processing time compared to other nodes. This indicates that frequent flushes have a measurable overhead on processing speed even at 7M gas.

## 3. Resource Usage Patterns

*   **CPU Usage:**
    *   Peaks observed up to **63.9%** (`miner1`) and **78.4%** (`node1`) during simulation start, stabilizing to **10-15%** for miners and **~10%** for nodes.
    *   `miner2` (1000 flush) exhibited generally lower and more stable CPU usage than `miner1`.
*   **Memory (JVM Heap):**
    *   All full-telemetry nodes hovered between **2.0 GiB and 2.7 GiB** of heap usage.
    *   Max heap allocated: **2.90 GiB**.
    *   GC Type: `Copy` GC is active (~1-6ms), while `MarkSweepCompact` stayed at 0s, indicating healthy heap management.
*   **Disk I/O:**
    *   `miner1` showed rhythmic Disk Write peaks around **1-2 MB/s**.
    *   Nodes with 100-block flushes showed more frequent, smaller I/O bursts compared to `miner2`.

## 4. Network and Execution Metrics

*   **Network Distribution:** `miner1` is the network hub, handling ~10x more traffic (Sent: ~37 KiB/s, Received: ~42 KiB/s) than other nodes (~3 KiB/s / ~11 KiB/s).
*   **Blockchain Flush JMX:**
    *   `miner2` uniquely reports a higher value (**7.83**) compared to others (**~1.13 - 1.28**). This metric likely reflects the volume or intensity of the "lazy" flush when it eventually occurs.
*   **Uncles:** All nodes produced uncles consistently (typically 1 per block period), showing healthy peer contention.

## 5. Summary for Future Baselines

| Metric (Avg/Stable) | miner1 (100 Flush) | miner2 (1000 Flush) | node1 (100 Flush) |
| :--- | :--- | :--- | :--- |
| Block Proc Time (AVG) | 0.0057s | 0.0025s | 0.0057s |
| CPU Usage (Stable) | 12-15% | 10-12% | 10% |
| Heap Usage | 2.1 - 2.6 GiB | 2.0 - 2.5 GiB | 2.0 - 2.6 GiB |
| Network Sent | ~37 KiB/s | ~3 KiB/s | ~3 KiB/s |

**Conclusion:** The 7M gas limit simulation is very stable. The primary performance differentiator at this scale is the **flush interval**, which provides a significant processing speed advantage to nodes configured with higher thresholds (`miner2`). `miner1` serves as the primary network node.
