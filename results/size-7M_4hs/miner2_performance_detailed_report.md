# Miner 2 Detailed Performance Report (7M Gas Baseline)

This report provides a deep-dive analysis of `rskj-miner2` performance during the 7 million gas limit simulation (`size-7M_4hs`). Miner 2 is uniquely configured with a **1000-block flush interval**, which significantly impacts its performance profile.

## 1. Core Performance Metrics Summary

| Metric | Average / Stable Range | Peak / Maximum |
| :--- | :--- | :--- |
| **Block Processing Time** | **0.00247s** | ~0.0035s |
| **CPU Usage** | **10% - 12%** | **67.6%** (at startup) |
| **Heap Memory (JVM)** | **2.0 - 2.6 GiB** | **2.88 GiB** (Max: 2.9 GiB) |
| **Network Sent** | **11.5 KiB/s** | **12.5 KiB/s** |
| **Network Received** | **3.1 KiB/s** | **4.2 KiB/s** |
| **Disk Write Activity** | **1.5 MB/s** | **10.6 MB/s** |
| **Blockchain Flush JMX** | **7.83 (AVG)** | 14.0 (Peak during flush) |

---

## 2. Deep Dive: JVM Behavior

### Heap Memory
- **Profile:** Highly rhythmic "sawtooth" pattern.
- **Efficiency:** The heap remains comfortably below the 2.9 GiB limit, typically oscillating between 2.0 GiB and 2.5 GiB. This indicates efficient object lifecycle management even under high throughput.

### Garbage Collection (GC)
- **Minor GC (Copy):** Extremely fast, averaging **1ms - 3ms**. This reflects the low object retention between flushes.
- **Major GC (MarkSweepCompact):** Rare. A notable peak of **18.3 ms** was recorded at 13:47, but otherwise remained at 0s for the majority of the simulation.
- **Impact:** GC pauses have negligible impact on block processing times for this node.

---

## 3. Deep Dive: Network Traffic

### Data Flow
- **Outbound (Sent):** Miner 2 consistently broadcasts around **11-12 KiB/s**. This is balanced across the simulation duration, suggesting a stable peer communication and block propagation rate.
- **Inbound (Received):** Significantly lower at **~3 KiB/s**.
- **Efficiency:** The low network footprint suggests that despite processing 7M gas blocks, the overhead for block propagation and synchronization is well-optimized for this node.

---

## 4. Deep Dive: Disk I/O & Storage Proxy

### Activity Profile
- **Rhythmic Peaks:** Disk write activity shows sharp peaks of **10.6 MB/s**.
- **Correlation:** These peaks directly correlate with the 1000-block flush events. By "lazy-flushing," Miner 2 minimizes constant disk pressure but creates periodic intensive I/O bursts.
- **Read Activity:** Consistent but low (**0.8 - 1.5 MB/s**), indicating that most state lookups are handled via memory caches (Trie cache).

---

## 5. Characterization: The "Efficient Miner"
Miner 2 represents the **optimal performance configuration** in this simulation. By utilizing a 1000-block flush interval:
1.  It achieves **50% faster block processing** than nodes with a 100-block interval.
2.  It maintains a **very stable resource footprint** (CPU/RAM).
3.  It trades off continuous disk usage for **periodic bursts**, which is generally more efficient for modern storage (NVMe/SSD).

**Conclusion:** Miner 2 should be used as the primary baseline for "ideal" RSK node performance under the 7M gas limit.
