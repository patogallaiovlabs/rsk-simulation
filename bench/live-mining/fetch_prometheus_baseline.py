#!/usr/bin/env python3
"""Export co.rsk.metrics.BlockProcessingStats gauges (rsk_block_*) from Prometheus for a
given instance and time range into a single wide-format CSV, plus a JSON summary
(mean/p50/p95 per metric). Used to snapshot a live-mining baseline for later comparison
against the same node after a code change.

Usage:
    python3 fetch_prometheus_baseline.py \
        --instance rskj-miner1 --start 2026-08-20T21:30:00Z --end 2026-08-21T12:53:00Z \
        --step 15s --out-prefix results/miner1_2026-08-21_baseline

Requires: Prometheus reachable at --prometheus-url (default http://localhost:9091), the
same one docker-compose.tools.yml stands up.
"""

import argparse
import csv
import json
import urllib.request
import urllib.parse

METRICS = [
    "rsk_block_BlockNumber",
    "rsk_block_GasUsed",
    "rsk_block_TxCount",
    "rsk_block_TotalMs",
    "rsk_block_InitialValidationMs",
    "rsk_block_ExecuteMs",
    "rsk_block_TxExecutionMs",
    "rsk_block_StatePersistMs",
    "rsk_block_StateRootRegisterMs",
    "rsk_block_SaveReceiptsMs",
    "rsk_block_OnBestBlockMs",
    "rsk_block_OnBlockMs",
    "rsk_block_SwitchChainMs",
]


def query_range(prometheus_url, metric, instance_name, start, end, step):
    query = f'{metric}{{name="{instance_name}"}}'
    params = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    url = f"{prometheus_url}/api/v1/query_range?{params}"
    with urllib.request.urlopen(url) as resp:
        data = json.load(resp)
    result = data.get("data", {}).get("result", [])
    if not result:
        return {}
    return {ts: float(v) for ts, v in result[0]["values"]}


def percentile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * (p / 100)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] * (c - k) + s[c] * (k - f)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--instance", required=True, help="value of the 'name' label, e.g. rskj-miner1")
    parser.add_argument("--start", required=True, help="RFC3339, e.g. 2026-08-20T21:30:00Z")
    parser.add_argument("--end", required=True, help="RFC3339")
    parser.add_argument("--step", default="15s")
    parser.add_argument("--out-prefix", required=True, help="writes <prefix>.csv and <prefix>_summary.json")
    parser.add_argument("--prometheus-url", default="http://localhost:9091")
    args = parser.parse_args()

    per_metric = {}
    all_timestamps = set()
    for metric in METRICS:
        series = query_range(args.prometheus_url, metric, args.instance, args.start, args.end, args.step)
        per_metric[metric] = series
        all_timestamps.update(series.keys())

    timestamps = sorted(all_timestamps)
    print(f"{len(timestamps)} timestamps fetched for instance={args.instance}")

    csv_path = f"{args.out_prefix}.csv"
    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp"] + METRICS)
        for ts in timestamps:
            row = [ts] + [per_metric[m].get(ts, "") for m in METRICS]
            writer.writerow(row)
    print(f"wrote {csv_path}")

    summary = {
        "instance": args.instance,
        "start": args.start,
        "end": args.end,
        "step": args.step,
        "n_timestamps": len(timestamps),
        "metrics": {},
    }
    for metric in METRICS:
        values = list(per_metric[metric].values())
        if not values:
            continue
        summary["metrics"][metric] = {
            "n": len(values),
            "mean": sum(values) / len(values),
            "p50": percentile(values, 50),
            "p95": percentile(values, 95),
            "min": min(values),
            "max": max(values),
        }

    json_path = f"{args.out_prefix}_summary.json"
    with open(json_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"wrote {json_path}")

    print(f"\n{'metric':<28}{'n':>8}{'mean':>10}{'p50':>10}{'p95':>10}")
    for metric, s in summary["metrics"].items():
        print(f"{metric:<28}{s['n']:>8}{s['mean']:>10.1f}{s['p50']:>10.1f}{s['p95']:>10.1f}")


if __name__ == "__main__":
    main()
