# Indexer (option 16) — local serial A/B, re-analysed at 90% utilization

Re-analysis of already-collected arms; no new runs. Blocks filtered to >=90% of the
25M local gas limit, paired within each cycle so the box term cancels by construction
(both arms ran serially on the same machine).

| cycle | blocks (base/tip) | p50 connect base | p50 connect tip | delta |
|---|---|---|---|---|
| 1 | 0 / 3 | - | - | not analysable |
| 2 | 55 / 58 | 32.0 ms | 32.0 ms | +0.0% |
| 3 | 67 / 73 | 31.0 ms | 30.0 ms | -3.2% |

**No meaningful build effect on this workload.** +0.0% and -3.2% sit inside the
+/-10% same-build noise measured for local runs, so neither is a signal.

Cycle 1 is excluded rather than reported: it predates the saturation retune and
peaked at ~21.4M/24.5M gas, so almost nothing clears the 90% bar. Lowering the
threshold to 85% only lifts it to 1 and 4 blocks -- still far too few for a median.
That is a coverage gap, not a null result, and the two are not interchangeable.

p50 executeMs (13ms vs 12-13ms) and saveReceiptsMs (0ms both arms) are likewise flat.
saveReceiptsMs being 0 on both sides is expected locally and is NOT evidence against
the receipts improvement seen on Boton: local NVMe makes the baseline cost ~0 to begin
with, so there is nothing for the change to remove. The effect needs slower I/O to be
visible (Boton: 64ms -> 5ms).
