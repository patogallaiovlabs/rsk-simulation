#!/bin/bash
# nmt.sh - Query JVM Native Memory Tracking, OS RSS, and Cgroup metrics for RSKj containers
#
# Usage:
#   ./nmt.sh [container] [summary|detail|diff|compact]
#
#   container  : rskj-miner1 (default), rskj-miner2, rskj-node1, rskj-node2, or 'all'
#   mode       : summary (default), detail, diff, compact

CONTAINER="${1:-rskj-miner1}"
MODE="${2:-summary}"

# Parse one NMT summary and emit a compact one-line table row
compact_row() {
  local c="$1"
  local rss_kb
  local cgrp_total_bytes
  local cgrp_file_bytes
  local db_fds
  local db_active
  local db_size_mb
  
  # 1. OS metrics
  rss_kb=$(docker exec "$c" grep VmRSS /proc/1/status 2>/dev/null | awk '{print $2}')
  cgrp_total_bytes=$(docker exec "$c" cat /sys/fs/cgroup/memory.current 2>/dev/null)
  cgrp_file_bytes=$(docker exec "$c" grep -w "file" /sys/fs/cgroup/memory.stat 2>/dev/null | awk '{print $2}')
  
  # 2. DB Stats
  db_active=$(docker exec "$c" sh -c "ls -l /proc/1/fd | grep database | awk '{print \$NF}' | xargs dirname | sort -u | wc -l" 2>/dev/null)
  db_fds=$(docker exec "$c" sh -c "ls -l /proc/1/fd | grep database | wc -l" 2>/dev/null)
  db_size_mb=$(docker exec "$c" sh -c 'du -sm ./test/local-regtest/database/ 2>/dev/null' | awk '{print $1}')
  
  # 3. JVM NMT
  raw=$(docker exec "$c" jattach 1 jcmd "VM.native_memory summary" 2>/dev/null)
  
  if [ -z "$raw" ]; then
    printf "%-13s  %8s  %8s  %8s  %8s  %8s  %8s  %4s  %9s\n" \
      "$c" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
    return
  fi
  
  extract() { echo "$1" | sed -n 's/.*committed=\([0-9]*\)KB.*/\1/p' | head -1; }
  total_committed=$(extract "$(echo "$raw" | grep "^Total:")")
  heap=$(extract "$(echo "$raw"     | grep "Java Heap"  | head -1)")
  gc=$(extract "$(echo "$raw"       | grep -m1 "GC ")")
  thr=$(extract "$(echo "$raw"      | grep -m1 "Thread ")")
  meta=$(extract "$(echo "$raw"     | grep -m1 "Metaspace ")")
  
  kb2mb() { echo $(( ${1:-0} / 1024 )); }
  b2mb() { echo $(( ${1:-0} / 1024 / 1024 )); }
  
  local tot_mb=$(b2mb $cgrp_total_bytes)
  local rss_mb=$(kb2mb $rss_kb)
  local cache_mb=$(b2mb $cgrp_file_bytes)
  local nmt_mb=$(kb2mb $total_committed)
  local sum_mb=$(( rss_mb + cache_mb ))
  local non_jvm_mb=$(( rss_mb - nmt_mb ))
  if [ $non_jvm_mb -lt 0 ]; then non_jvm_mb=0; fi

  # Requested Order: Total Grafana, Total CACHE+RSS, CACHE, RSS, JVM(NMT), HEAP, NON-JVM, FDS, DB DISK
  printf "%-13s  %6s MB  %6s MB  %6s MB  %6s MB  %6s MB  %6s MB  %6s MB  %3s  %7s MB\n" \
    "$c" "$tot_mb" "$sum_mb" "$cache_mb" "$rss_mb" "$nmt_mb" "$(kb2mb $heap)" "$non_jvm_mb" "${db_fds:-0}" "${db_size_mb:-0}"

  # Log to CSV (13 columns - layout persists)
  HISTORY_FILE="results/nmt/nmt_history.csv"
  mkdir -p "$(dirname "$HISTORY_FILE")"
  if [ ! -f "$HISTORY_FILE" ]; then
    echo "timestamp,container,cgrp_total_mb,rss_mb,cache_mb,nmt_total_mb,heap_mb,gc_mb,threads_mb,metaspace_mb,non_jvm_mb,db_count,db_fds,db_disk_mb" > "$HISTORY_FILE"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S'),$c,$tot_mb,$rss_mb,$cache_mb,$nmt_mb,$(kb2mb $heap),$(kb2mb $gc),$(kb2mb $thr),$(kb2mb $meta),$non_jvm_mb,${db_active:-0},${db_fds:-0},${db_size_mb:-0}" >> "$HISTORY_FILE"
}

# Parse one NMT summary and emit a CSV row
csv_row() {
  local c="$1"
  local rss_kb
  local cgrp_total_bytes
  local cgrp_file_bytes
  rss_kb=$(docker exec "$c" grep VmRSS /proc/1/status 2>/dev/null | awk '{print $2}')
  cgrp_total_bytes=$(docker exec "$c" cat /sys/fs/cgroup/memory.current 2>/dev/null)
  cgrp_file_bytes=$(docker exec "$c" grep -w "file" /sys/fs/cgroup/memory.stat 2>/dev/null | awk '{print $2}')
  
  local db_active=$(docker exec "$c" sh -c "ls -l /proc/1/fd | grep database | awk '{print \$NF}' | xargs dirname | sort -u | wc -l" 2>/dev/null)
  local db_size_mb=$(docker exec "$c" sh -c 'du -sm ./test/local-regtest/database/ 2>/dev/null' | awk '{print $1}')

  local raw=$(docker exec "$c" jattach 1 jcmd "VM.native_memory summary" 2>/dev/null)
  if [ -z "$raw" ]; then
    echo "$c,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
    return
  fi
  extract() { echo "$1" | sed -n 's/.*committed=\([0-9]*\)KB.*/\1/p' | head -1; }
  total_committed=$(extract "$(echo "$raw" | grep "^Total:")")
  heap=$(extract "$(echo "$raw"     | grep "Java Heap"  | head -1)")
  gc=$(extract "$(echo "$raw"       | grep -m1 "GC ")")
  thr=$(extract "$(echo "$raw"      | grep -m1 "Thread ")")
  meta=$(extract "$(echo "$raw"     | grep -m1 "Metaspace ")")

  kb2mb() { echo $(( ${1:-0} / 1024 )); }
  b2mb() { echo $(( ${1:-0} / 1024 / 1024 )); }
  
  local tot_mb=$(b2mb $cgrp_total_bytes)
  local rss_mb=$(kb2mb $rss_kb)
  local cache_mb=$(b2mb $cgrp_file_bytes)
  local nmt_mb=$(kb2mb $total_committed)
  local non_jvm_mb=$(( rss_mb - nmt_mb ))
  if [ $non_jvm_mb -lt 0 ]; then non_jvm_mb=0; fi

  echo "$(date '+%Y-%m-%d %H:%M:%S'),$c,$tot_mb,$rss_mb,$cache_mb,$nmt_mb,$(kb2mb $heap),$(kb2mb $gc),$(kb2mb $thr),$(kb2mb $meta),$non_jvm_mb,${db_active:-0},${db_fds:-0},${db_size_mb:-0}"
}

run_nmt() {
  local c="$1"
  echo ""
  echo "======================================================="
  echo " NMT ${MODE}: ${c}  ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "======================================================="
  docker exec "$c" jattach 1 jcmd "VM.native_memory ${MODE}" 2>&1
}

if [ "$MODE" = "csv" ]; then
  echo "timestamp,container,cgroup_total_mb,rss_mb,cache_mb,nmt_total_mb,heap_mb,gc_mb,threads_mb,metaspace_mb,non_jvm_mb,db_count,db_disk_mb"
  if [ "$CONTAINER" = "all" ]; then
    for c in rskj-miner1 rskj-miner2 rskj-node1 rskj-node2; do
      csv_row "$c"
    done
  else
    csv_row "$CONTAINER"
  fi
elif [ "$MODE" = "compact" ] || { [ "$CONTAINER" = "all" ] && [ "$MODE" = "summary" ]; }; then
  echo "NMT+OS+DB+CGRP Compact Summary — $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  printf "%-13s  %-9s  %-9s  %-9s  %-9s  %-9s  %-9s  %-9s  %-4s  %-10s\n" \
    "CONTAINER" "GRAFANA" "RSS+CACHE" "CACHE" "RSS" "JVM(NMT)" "HEAP" "NON-JVM" "FDS" "DB DISK"
  printf "%-13s  %-9s  %-9s  %-9s  %-9s  %-9s  %-9s  %-9s  %-4s  %-10s\n" \
    "-------------" "---------" "---------" "---------" "---------" "---------" "---------" "---------" "----" "----------"
  if [ "$CONTAINER" = "all" ]; then
    for c in rskj-miner1 rskj-miner2 rskj-node1 rskj-node2; do
      compact_row "$c"
    done
  else
    compact_row "$CONTAINER"
  fi
elif [ "$CONTAINER" = "all" ]; then
  for c in rskj-miner1 rskj-miner2 rskj-node1 rskj-node2; do
    run_nmt "$c"
  done
else
  run_nmt "$CONTAINER"
fi
