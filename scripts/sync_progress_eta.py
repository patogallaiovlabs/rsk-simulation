#!/usr/bin/env python3
"""Follow an RSKj log and print rolling sync speed plus ETA."""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from collections import deque
from typing import Deque, Optional, Tuple

PROGRESS_RE = re.compile(
    r"up to block \[(\d+)\], (\d+) blocks in \[([\d.]+)\]s = \[([\d.]+)\] blocks/s"
)

DEFAULT_LOG = "/Users/patricio/rskj2-sync/logs/run2/rsk.log"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Tail SYNC PROGRESS lines and print last-N average speed plus ETA."
    )
    parser.add_argument(
        "log",
        nargs="?",
        default=DEFAULT_LOG,
        help=f"path to rsk.log (default: {DEFAULT_LOG})",
    )
    parser.add_argument(
        "--target",
        type=int,
        default=9_000_000,
        help="target block height for ETA (default: 9000000)",
    )
    parser.add_argument(
        "--window",
        type=int,
        default=200,
        help="number of recent intervals to average (default: 200)",
    )
    return parser.parse_args()


def parse_progress(line: str) -> Optional[Tuple[int, int, float, float]]:
    if "SYNC PROGRESS" not in line:
        return None
    match = PROGRESS_RE.search(line)
    if not match:
        return None
    return (
        int(match.group(1)),
        int(match.group(2)),
        float(match.group(3)),
        float(match.group(4)),
    )


def fmt_eta(seconds: Optional[float]) -> str:
    if seconds is None:
        return "--"
    if seconds < 0:
        return "done"
    if seconds < 60:
        return f"{seconds:.0f}s"
    if seconds < 3600:
        return f"{seconds / 60:.1f}m"
    hours = seconds / 3600
    if hours < 48:
        return f"{hours:.1f}h"
    return f"{hours / 24:.1f}d"


def fmt_blocks(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def print_status(
    height: int,
    elapsed_s: float,
    line_speed: float,
    window: Deque[Tuple[int, int, float, float]],
    target: int,
) -> None:
    total_blocks = sum(item[1] for item in window)
    total_time = sum(item[2] for item in window)
    avg = total_blocks / total_time if total_time > 0 else 0.0
    remaining = target - height
    eta = remaining / avg if avg > 0 else None
    n = len(window)
    sys.stdout.write(
        f"{height}  {elapsed_s:.1f}s  {line_speed:.1f} blks/s"
        f"  | last{n} {avg:.1f} blks/s"
        f"  | left {fmt_blocks(max(remaining, 0))}"
        f"  | ETA {fmt_eta(eta)}\n"
    )
    sys.stdout.flush()


def seed_window(path: str, window: Deque[Tuple[int, int, float, float]]) -> None:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parsed = parse_progress(line)
            if parsed:
                window.append(parsed)


def follow(path: str, window: Deque, target: int) -> None:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        while True:
            line = handle.readline()
            if line:
                parsed = parse_progress(line)
                if parsed:
                    window.append(parsed)
                    height, _nblocks, elapsed_s, speed = parsed
                    print_status(height, elapsed_s, speed, window, target)
                continue
            try:
                new_size = os.path.getsize(path)
            except OSError:
                time.sleep(0.3)
                continue
            if new_size < size:
                handle.close()
                return
            size = new_size
            time.sleep(0.2)


def wait_for_log(path: str) -> None:
    while not os.path.exists(path):
        sys.stderr.write(f"waiting for {path}\n")
        sys.stderr.flush()
        time.sleep(1.0)


def main() -> int:
    args = parse_args()
    if args.window < 1:
        sys.stderr.write("--window must be >= 1\n")
        return 2

    wait_for_log(args.log)
    window: Deque[Tuple[int, int, float, float]] = deque(maxlen=args.window)
    seed_window(args.log, window)
    if window:
        height, _nblocks, elapsed_s, speed = window[-1]
        print_status(height, elapsed_s, speed, window, args.target)
        sys.stderr.write(
            f"following {args.log}  target={args.target}  window={args.window}\n"
        )
        sys.stderr.flush()
    else:
        sys.stderr.write(
            f"no SYNC PROGRESS lines yet in {args.log}; waiting\n"
        )
        sys.stderr.flush()

    while True:
        try:
            follow(args.log, window, args.target)
        except FileNotFoundError:
            wait_for_log(args.log)
        time.sleep(0.2)
        window.clear()
        if os.path.exists(args.log):
            seed_window(args.log, window)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
