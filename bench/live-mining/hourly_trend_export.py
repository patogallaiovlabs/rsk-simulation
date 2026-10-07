#!/usr/bin/env python3
"""Bucket an already-fetched wide-format CSV (see fetch_prometheus_baseline.py) into
hourly means per metric, and print/save as CSV. Used to see trends over a long window
without staring at raw per-scrape data.

Usage:
    python3 hourly_trend_export.py results/miner1_2026-08-21_baseline.csv --out results/miner1_2026-08-21_hourly_trend.csv
"""
import argparse
import csv
from collections import defaultdict
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_path")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    with open(args.csv_path) as f:
        reader = csv.DictReader(f)
        fieldnames = [fn for fn in reader.fieldnames if fn != "timestamp"]
        buckets = defaultdict(lambda: defaultdict(list))
        for row in reader:
            dt = datetime.fromtimestamp(float(row["timestamp"]), tz=timezone.utc)
            hour_key = dt.strftime("%Y-%m-%d %H:00")
            for fn in fieldnames:
                if row[fn] != "":
                    buckets[hour_key][fn].append(float(row[fn]))

    hours = sorted(buckets.keys())
    with open(args.out, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["hour"] + fieldnames)
        for hour in hours:
            row = [hour]
            for fn in fieldnames:
                vs = buckets[hour][fn]
                row.append(round(sum(vs) / len(vs), 1) if vs else "")
            writer.writerow(row)

    print(f"wrote {args.out}")
    print(f"\n{'hour':<18}" + "".join(f"{fn.replace('rsk_block_',''):>16}" for fn in fieldnames if 'Ms' in fn))
    for hour in hours:
        line = f"{hour:<18}"
        for fn in fieldnames:
            if 'Ms' not in fn:
                continue
            vs = buckets[hour][fn]
            mean = sum(vs) / len(vs) if vs else 0
            line += f"{mean:>16.1f}"
        print(line)


if __name__ == "__main__":
    main()
