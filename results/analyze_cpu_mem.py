#!/usr/bin/env python3
"""Correlate CPU / memory / block-processing-time with block gas limit.

Reads the exported Grafana CSVs from the 4cpu/cpu-ecdsa sweep (fixed 4 vCPU,
ECDSA-heavy workload, gas limit varied 7M -> 25M) and the post-leak-fix NMT
runs, and prints steady-state aggregates per gas limit.
"""
import csv, glob, os, statistics

BASE = os.path.dirname(os.path.abspath(__file__))
MINERS = ["rskj-miner1", "rskj-miner2"]          # primary loaded nodes
ALL_NODES = ["rskj-miner1", "rskj-miner2", "rskj-node1", "rskj-node2"]
WARMUP = 0.20  # drop first 20% of samples as warmup

def read_cols(path):
    with open(path, newline="") as fh:
        rows = list(csv.reader(fh))
    header, data = rows[0], rows[1:]
    # drop warmup
    data = data[int(len(data) * WARMUP):]
    cols = {}
    for i, h in enumerate(header):
        vals = []
        for r in data:
            if i < len(r) and r[i] not in ("", None):
                try:
                    vals.append(float(r[i]))
                except ValueError:
                    pass
        cols[h] = vals
    return cols

def match_col(cols, node):
    for h, v in cols.items():
        if node in h and v:
            return v
    return []

def med(xs):
    return statistics.median(xs) if xs else float("nan")

def p95(xs):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.95 * len(xs)))]

GAS = {"7M": 7, "10M": 10, "17M": 17, "25M": 25}
RUNS = {
    "7M":  "4cpu/cpu-ecdsa/7M_16h",
    "10M": "4cpu/cpu-ecdsa/10M_4h",
    "17M": "4cpu/cpu-ecdsa/17M_14h",
    "25M": "4cpu/cpu-ecdsa/25M_2h",
}

def find(run, prefix):
    g = glob.glob(os.path.join(BASE, run, "data", prefix + "*joinbyfield*.csv"))
    return g[0] if g else None

print("=" * 96)
print("CPU / MEMORY / BLOCK-TIME vs BLOCK GAS LIMIT  (4 vCPU, ECDSA-heavy sweep, miners avg)")
print("=" * 96)
print(f"{'gas':>5} | {'CPU% med':>9} {'CPU% p95':>9} | {'CPU/core%':>9} | "
      f"{'mem MB med':>10} | {'blk-time s med':>14} {'blk-time s p95':>14}")
print("-" * 96)
rows_out = []
for tag, run in RUNS.items():
    cpu_f = find(run, "CPU_Usage_per_Container-")
    mem_f = find(run, "Memory_Usage_per_Container-")
    bt_f = find(run, "Block_Processing_Time_AVG-")
    cpu_c = read_cols(cpu_f)
    mem_c = read_cols(mem_f)
    bt_c = read_cols(bt_f)

    cpu_vals, mem_vals, bt_vals = [], [], []
    for n in MINERS:
        cpu_vals += match_col(cpu_c, n)
        mem_vals += [x / (1024 * 1024) for x in match_col(mem_c, n)]
        bt_vals += match_col(bt_c, n)

    cpu_med, cpu_p95 = med(cpu_vals), p95(cpu_vals)
    mem_med = med(mem_vals)
    bt_med, bt_p95 = med(bt_vals), p95(bt_vals)
    # CPU is per-container percent; 4 cores -> 400% = full saturation
    per_core = cpu_med / 4.0
    rows_out.append((tag, cpu_med, cpu_p95, per_core, mem_med, bt_med, bt_p95))
    print(f"{tag:>5} | {cpu_med:9.0f} {cpu_p95:9.0f} | {per_core:8.0f}% | "
          f"{mem_med:10.0f} | {bt_med:14.3f} {bt_p95:14.3f}")

print("-" * 96)
# scaling factors relative to 7M
base = rows_out[0]
print("\nScaling relative to 7M (x):")
print(f"{'gas':>5} | {'gas x':>6} | {'CPU x':>6} | {'mem x':>6} | {'blk-time x':>10}")
for r in rows_out:
    tag = r[0]
    print(f"{tag:>5} | {GAS[tag]/GAS['7M']:6.2f} | {r[1]/base[1]:6.2f} | "
          f"{r[4]/base[4]:6.2f} | {r[5]/base[5]:10.2f}")
