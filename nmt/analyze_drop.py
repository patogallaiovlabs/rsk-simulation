#!/usr/bin/env python3
"""Detect non_jvm_mb drops in nmt_history.csv and attribute likely causes."""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd

THRESHOLD_MB = 80
TRACK_COLS = [
    "rss_mb",
    "cache_mb",
    "cgrp_total_mb",
    "nmt_total_mb",
    "heap_comm_mb",
    "heap_used_mb",
    "proc_anon_mb",
    "proc_priv_clean_mb",
    "proc_priv_dirty_mb",
    "proc_swap_mb",
    "cgrp_swapcached_mb",
    "cgrp_anon_thp_mb",
    "rdb_memtables_mb",
    "rdb_block_cache_mb",
    "rdb_pending_compact_mb",
    "rdb_table_readers_mb",
    "rdb_sst_mb",
]


def delta(row, prev, col: str) -> float | None:
    if col not in row.index or col not in prev.index:
        return None
    cur, old = row[col], prev[col]
    if pd.isna(cur) or pd.isna(old):
        return None
    return float(cur) - float(old)


def classify_drop(d: dict[str, float | None]) -> list[str]:
    hints: list[str] = []
    non_jvm = d.get("non_jvm_mb")
    if non_jvm is None or non_jvm >= -THRESHOLD_MB:
        return ["No large non_jvm drop in this step."]

    nmt = d.get("nmt_total_mb")
    rss = d.get("rss_mb")
    cache = d.get("cache_mb")
    cgrp = d.get("cgrp_total_mb")
    priv_clean = d.get("proc_priv_clean_mb")
    priv_dirty = d.get("proc_priv_dirty_mb")
    memtables = d.get("rdb_memtables_mb")
    pending = d.get("rdb_pending_compact_mb")
    block_cache = d.get("rdb_block_cache_mb")
    sst = d.get("rdb_sst_mb")
    swap = d.get("proc_swap_mb")
    swapcached = d.get("cgrp_swapcached_mb")

    if nmt is not None and abs(nmt) < 5:
        hints.append("JVM NMT flat → native/OS accounting, not Java heap/GC.")
    elif nmt is not None and nmt < -20:
        hints.append("NMT committed fell → possible JVM release or NMT category shift.")

    if rss is not None and rss < -20 and cache is not None and cache > 20:
        hints.append("RSS↓ + cache↑ → anonymous pages reclassified to file page cache.")
    elif rss is not None and rss < -20:
        hints.append("RSS↓ without matching cache↑ → anon pages dropped or swapped.")

    if cgrp is not None and rss is not None and cgrp > rss + 50:
        hints.append("Cgroup total fell less than RSS → mostly reclassification, not exit from container.")
    elif cgrp is not None and cgrp < -50:
        hints.append("Cgroup total fell materially → memory left the container cgroup.")

    if priv_clean is not None and priv_clean > 30:
        hints.append("Private_Clean↑ → likely jemalloc/kernel released dirty anonymous pages.")
    if priv_dirty is not None and priv_dirty < -30:
        hints.append("Private_Dirty↓ → dirty anonymous resident pages were reclaimed.")

    if memtables is not None and memtables < -5:
        hints.append("RocksDB memtables↓ → memtable flush likely contributed.")
    elif memtables is not None and abs(memtables) < 2:
        hints.append("RocksDB memtables flat → flush unlikely to be the trigger.")

    if pending is not None and pending < -50:
        hints.append("Pending compaction↓ → compaction backlog drained.")
    if block_cache is not None and abs(block_cache) > 10:
        hints.append(
            "RocksDB block cache usage changed (shared LRU; independent churn, not 1:1 with non_jvm)."
        )
    if sst is not None and sst > 50:
        hints.append("SST on-disk size↑ → new SST files written (flush/compaction output).")

    if swap is not None and abs(swap) > 20:
        hints.append("Process swap changed → check memory pressure / swapcached.")
    if swapcached is not None and abs(swapcached) > 20:
        hints.append("Cgroup swapcached changed → swapped file-backed pages involved.")

    if not hints:
        hints.append("Insufficient extended columns; run newer nmt.sh to populate tracking fields.")
    return hints


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--csv",
        default="results/nmt/nmt_history.csv",
        help="Path to nmt_history.csv",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=THRESHOLD_MB,
        help="Report non_jvm drops larger than this many MB (default: 80)",
    )
    parser.add_argument(
        "--container",
        default=None,
        help="Only analyze this container name",
    )
    args = parser.parse_args()

    csv_path = Path(args.csv)
    if not csv_path.exists():
        raise SystemExit(f"CSV not found: {csv_path}")

    df = pd.read_csv(csv_path)
    df["timestamp"] = pd.to_datetime(df["timestamp"])
    df = df.sort_values(["container", "timestamp"])

    containers = [args.container] if args.container else sorted(df["container"].unique())
    found = False

    for container in containers:
        sub = df[df["container"] == container].reset_index(drop=True)
        if len(sub) < 2:
            continue
        for i in range(1, len(sub)):
            prev, row = sub.iloc[i - 1], sub.iloc[i]
            if pd.isna(row.get("non_jvm_mb")) or pd.isna(prev.get("non_jvm_mb")):
                continue
            drop = float(row["non_jvm_mb"]) - float(prev["non_jvm_mb"])
            if drop > -args.threshold:
                continue
            found = True
            changes = {"non_jvm_mb": drop}
            for col in TRACK_COLS:
                changes[col] = delta(row, prev, col)
            print(f"\n{'=' * 72}")
            print(f"{container}  {prev['timestamp']} → {row['timestamp']}")
            print(f"non_jvm_mb: {prev['non_jvm_mb']:.0f} → {row['non_jvm_mb']:.0f}  (Δ {drop:+.0f} MB)")
            print("-" * 72)
            for col in TRACK_COLS:
                val = changes.get(col)
                if val is None:
                    continue
                if abs(val) < 1:
                    continue
                print(f"  {col:28s} {val:+8.0f} MB")
            print("-" * 72)
            print("Likely origin:")
            for hint in classify_drop(changes):
                print(f"  • {hint}")

    if not found:
        print(f"No non_jvm drops ≥ {args.threshold:.0f} MB found.")


if __name__ == "__main__":
    main()
