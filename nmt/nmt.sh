#!/bin/bash
# nmt.sh - Query JVM Native Memory Tracking, OS RSS, and memory metrics for RSKj
#
# Usage:
#   ./nmt.sh [target] [summary|detail|diff|compact|csv]
#
#   target : rskj-miner1 (default), rskj-miner2, rskj-miner3, rskj-miner4, rskj-node1, rskj-node2,
#            rskj-local (host JVM), or 'all' (docker nodes + local if running)
#   mode   : summary (default), detail, diff, compact, csv
#
# Extended columns (CSV) track RocksDB JMX, process smaps, and cgroup extras
# to attribute non_jvm drops. After a run, use:
#   python3 analyze_drop.py --container rskj-miner2
#
# Local node discovery (rskj-local):
#   - RSKJ_PID env var (explicit PID), else jps -l | co.rsk.Start, else pgrep -f co.rsk.Start
#   - RSKJ_LOCAL_NAME env var to rename the CSV/plot label (default: rskj-local)
#   - Uses jcmd on the host (jattach not required)
#   - macOS resident totals use vmmap "Physical footprint" (ps RSS underreports JVM heap)

TARGET="${1:-rskj-miner1}"
MODE="${2:-summary}"

DOCKER_CONTAINERS=(rskj-miner1 rskj-miner2 rskj-miner3 rskj-miner4 rskj-node1 rskj-node2)
LOCAL_NAME="${RSKJ_LOCAL_NAME:-rskj-local}"

# Populated by fetch_* ; consumed by compute_metrics
tot_bytes=0
rss_bytes=0
cache_bytes=0
db_fds=0
raw_nmt=""
heap_info=""

# Populated by compute_metrics
tot_mb=0
rss_mb=0
cache_mb=0
h_comm_mb=0
nmt_comm_mb=0
nmt_oth_mb=0
internal_mb=0
non_jvm_mb=0
gc_mb=0
threads_mb=0
metaspace_mb=0
code_mb=0
heap_used_mb=0
proc_anon_mb=0
proc_priv_clean_mb=0
proc_priv_dirty_mb=0
proc_swap_mb=0
cgrp_swapcached_mb=0
cgrp_anon_thp_mb=0
rdb_memtables_mb=0
rdb_block_cache_mb=0
rdb_pending_compact_mb=0
rdb_table_readers_mb=0
rdb_sst_mb=0

CSV_HEADER="timestamp,container,cgrp_total_mb,rss_mb,cache_mb,nmt_total_mb,heap_comm_mb,gc_mb,threads_mb,metaspace_mb,code_mb,internal_mb,nmt_other_mb,non_jvm_mb,db_fds,heap_used_mb,proc_anon_mb,proc_priv_clean_mb,proc_priv_dirty_mb,proc_swap_mb,cgrp_swapcached_mb,cgrp_anon_thp_mb,rdb_memtables_mb,rdb_block_cache_mb,rdb_pending_compact_mb,rdb_table_readers_mb,rdb_sst_mb"
CSV_EXTRA_PAD=",,,,,,,,,,,,"

metrics_port_for() {
  case "$1" in
    rskj-miner1) echo 9501 ;;
    rskj-miner2) echo 9502 ;;
    rskj-miner3) echo 9503 ;;
    rskj-miner4) echo 9504 ;;
    rskj-node1)  echo 9505 ;;
    rskj-node2)  echo 9506 ;;
    *) echo "" ;;
  esac
}

sum_prom_metric() {
  local metrics="$1"
  local needle="$2"
  echo "$metrics" | grep "$needle" | grep -v '^#' | sed 's/.*} //' | \
    awk '{s+=$1} END {printf "%.0f", s+0}'
}

# Shared across all RocksDB instances — each MBean repeats the same value.
first_prom_metric() {
  local metrics="$1"
  local needle="$2"
  echo "$metrics" | grep "$needle" | grep -v '^#' | sed 's/.*} //' | head -1 | \
    awk '{printf "%.0f", $1+0}'
}

reset_extended_metrics() {
  heap_used_mb=0
  proc_anon_mb=0
  proc_priv_clean_mb=0
  proc_priv_dirty_mb=0
  proc_swap_mb=0
  cgrp_swapcached_mb=0
  cgrp_anon_thp_mb=0
  rdb_memtables_mb=0
  rdb_block_cache_mb=0
  rdb_pending_compact_mb=0
  rdb_table_readers_mb=0
  rdb_sst_mb=0
}

parse_heap_used_mb() {
  local info="$1"
  local used_kb
  used_kb=$(echo "$info" | sed -n 's/.*used \([0-9]*\)K.*/\1/p' | head -1)
  heap_used_mb=$(kb2mb "${used_kb:-0}")
}

read_process_smaps() {
  local pid="$1"
  local smaps anon_kb clean_kb dirty_kb swap_kb
  if [ -r "/proc/$pid/smaps_rollup" ]; then
    smaps=$(grep -E '^(Anonymous|Private_Clean|Private_Dirty|Swap):' "/proc/$pid/smaps_rollup" 2>/dev/null)
    anon_kb=$(echo "$smaps" | awk '/^Anonymous:/{print $2}')
    clean_kb=$(echo "$smaps" | awk '/^Private_Clean:/{print $2}')
    dirty_kb=$(echo "$smaps" | awk '/^Private_Dirty:/{print $2}')
    swap_kb=$(echo "$smaps" | awk '/^Swap:/{print $2}')
    proc_anon_mb=$(kb2mb "${anon_kb:-0}")
    proc_priv_clean_mb=$(kb2mb "${clean_kb:-0}")
    proc_priv_dirty_mb=$(kb2mb "${dirty_kb:-0}")
    proc_swap_mb=$(kb2mb "${swap_kb:-0}")
  fi
}

read_cgroup_extras() {
  local stat="$1"
  local swapcached_bytes anon_thp_bytes
  swapcached_bytes=$(to_int "$(echo "$stat" | grep -w "swapcached" | awk '{print $2}')")
  anon_thp_bytes=$(to_int "$(echo "$stat" | grep -w "anon_thp" | awk '{print $2}')")
  cgrp_swapcached_mb=$(b2mb "$swapcached_bytes")
  cgrp_anon_thp_mb=$(b2mb "$anon_thp_bytes")
}

fetch_rocksdb_metrics() {
  local port="$1"
  local metrics
  local memtables_bytes block_cache_bytes pending_bytes readers_bytes sst_bytes
  [ -n "$port" ] || return 0
  metrics=$(curl -sf --max-time 3 "http://127.0.0.1:${port}/metrics" 2>/dev/null) || return 0
  memtables_bytes=$(sum_prom_metric "$metrics" "RocksDbStats_CurSizeAllMemTables")
  block_cache_bytes=$(first_prom_metric "$metrics" "RocksDbStats_BlockCacheUsageBytes")
  pending_bytes=$(sum_prom_metric "$metrics" "RocksDbStats_EstimatePendingCompactionBytes")
  readers_bytes=$(sum_prom_metric "$metrics" "RocksDbStats_EstimateTableReadersMem")
  sst_bytes=$(sum_prom_metric "$metrics" "RocksDbStats_TotalSstFilesSizeBytes")
  rdb_memtables_mb=$(b2mb "$memtables_bytes")
  rdb_block_cache_mb=$(b2mb "$block_cache_bytes")
  rdb_pending_compact_mb=$(b2mb "$pending_bytes")
  rdb_table_readers_mb=$(b2mb "$readers_bytes")
  rdb_sst_mb=$(b2mb "$sst_bytes")
}

upgrade_csv_header_if_needed() {
  local f="$1"
  [ -f "$f" ] || return 0
  head -1 "$f" | grep -q "rdb_memtables_mb" && return 0
  local tmp="${f}.upgrade.$$"
  {
    echo "$CSV_HEADER"
    tail -n +2 "$f" | while IFS= read -r line; do
      echo "${line}${CSV_EXTRA_PAD}"
    done
  } > "$tmp" && mv "$tmp" "$f"
}

to_int() {
  local v="${1:-0}"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

b2mb() { echo $(( $(to_int "$1") / 1024 / 1024 )); }
kb2mb() { echo $(( $(to_int "$1") / 1024 )); }

docker_container_exec_ok() {
  docker exec "$1" true >/dev/null 2>&1
}

docker_exec_quiet() {
  local c="$1"
  shift
  local out
  out=$(docker exec "$c" "$@" 2>/dev/null) || return 1
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  echo "$out"
}

# Parse vmmap/ps size tokens (e.g. 3.9G, 10.8M, 6400K) to bytes.
parse_size_to_bytes() {
  local raw="${1:-0}"
  local num unit
  if [[ "$raw" =~ ^([0-9.]+)[[:space:]]*([KkMmGgTt])[iI]?[bB]?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    num="${raw%%[KMGTPkmgtp]*}"
    unit="${raw#"$num"}"
  fi
  case "$unit" in
    K|k|KB|kb|Ki|ki) awk "BEGIN{printf \"%.0f\", $num * 1024}" ;;
    M|m|MB|mb|Mi|mi) awk "BEGIN{printf \"%.0f\", $num * 1024 * 1024}" ;;
    G|g|GB|gb|Gi|gi) awk "BEGIN{printf \"%.0f\", $num * 1024 * 1024 * 1024}" ;;
    T|t|TB|tb|Ti|ti) awk "BEGIN{printf \"%.0f\", $num * 1024 * 1024 * 1024 * 1024}" ;;
    *) awk "BEGIN{printf \"%.0f\", $num + 0}" ;;
  esac
}

extract_nmt() { echo "$1" | sed -n 's/.*committed=\([0-9]*\)KB.*/\1/p' | head -1; }

find_local_rskj_pid() {
  if [ -n "$RSKJ_PID" ] && kill -0 "$RSKJ_PID" 2>/dev/null; then
    echo "$RSKJ_PID"
    return 0
  fi
  local pid=""
  if command -v jps >/dev/null 2>&1; then
    pid=$(jps -l 2>/dev/null | awk '/co\.rsk\.Start/{print $1; exit}')
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  pid=$(pgrep -f 'co\.rsk\.Start' 2>/dev/null | head -1)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid"
    return 0
  fi
  return 1
}

local_process_label() {
  local pid="$1"
  local cmd
  cmd=$(ps -p "$pid" -o command= 2>/dev/null | head -c 80)
  echo "pid=${pid} ${cmd}"
}

read_os_memory() {
  local pid="$1"
  tot_bytes=0
  rss_bytes=0
  cache_bytes=0

  local os
  os=$(uname -s)

  if [ "$os" = "Linux" ] && [ -r "/proc/$pid/smaps_rollup" ]; then
    local pss_anon pss_file
    pss_anon=$(awk '/^Pss_Anon:/{print $2}' "/proc/$pid/smaps_rollup")
    pss_file=$(awk '/^Pss_File:/{print $2}' "/proc/$pid/smaps_rollup")
    rss_bytes=$(( ${pss_anon:-0} * 1024 ))
    cache_bytes=$(( ${pss_file:-0} * 1024 ))
    tot_bytes=$(( rss_bytes + cache_bytes ))
  elif [ "$os" = "Darwin" ]; then
    # ps RSS underreports JVM heap on macOS; vmmap Physical footprint matches
    # Activity Monitor / VisualVM "physical memory" much better.
    if command -v vmmap >/dev/null 2>&1; then
      local vmmap_out footprint mapped_resident
      vmmap_out=$(vmmap -summary "$pid" 2>/dev/null)
      footprint=$(echo "$vmmap_out" | awk '/^Physical footprint:/ && $0 !~ /peak/ {print $3; exit}')
      mapped_resident=$(echo "$vmmap_out" | awk '/^mapped file/ {print $3; exit}')
      tot_bytes=$(parse_size_to_bytes "${footprint:-0}")
      cache_bytes=$(parse_size_to_bytes "${mapped_resident:-0}")
      rss_bytes=$(( tot_bytes - cache_bytes ))
      [ "$rss_bytes" -lt 0 ] && rss_bytes=0
    else
      local rss_kb
      rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
      rss_bytes=$(( ${rss_kb:-0} * 1024 ))
      tot_bytes=$rss_bytes
      cache_bytes=0
    fi
  else
    local rss_kb
    rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
    rss_bytes=$(( ${rss_kb:-0} * 1024 ))
    tot_bytes=$rss_bytes
  fi
}

count_db_fds() {
  local pid="$1"
  if [ -d "/proc/$pid/fd" ]; then
    ls -l "/proc/$pid/fd" 2>/dev/null | grep -c database || echo 0
  elif command -v lsof >/dev/null 2>&1; then
    lsof -p "$pid" 2>/dev/null | grep -c database || echo 0
  else
    echo 0
  fi
}

run_jcmd() {
  local pid="$1"
  shift
  if command -v jcmd >/dev/null 2>&1; then
    jcmd "$pid" "$@" 2>/dev/null
  elif command -v jattach >/dev/null 2>&1; then
    jattach "$pid" jcmd "$*" 2>/dev/null
  fi
}

fetch_docker_stats_fallback() {
  local c="$1"
  local mem_used
  reset_extended_metrics
  mem_used=$(docker stats "$c" --no-stream --format '{{.MemUsage}}' 2>/dev/null | awk '{print $1}')
  tot_bytes=$(parse_size_to_bytes "${mem_used:-0}")
  rss_bytes=$tot_bytes
  cache_bytes=0
  db_fds=0
  raw_nmt=""
  heap_info=""
  fetch_rocksdb_metrics "$(metrics_port_for "$c")"
}

fetch_docker_metrics() {
  local c="$1"
  tot_bytes=0
  rss_bytes=0
  cache_bytes=0
  db_fds=0
  raw_nmt=""
  heap_info=""
  reset_extended_metrics

  if ! docker_container_exec_ok "$c"; then
    fetch_docker_stats_fallback "$c"
    return 0
  fi

  local stat=""
  if docker exec "$c" [ -f /sys/fs/cgroup/memory.current ] >/dev/null 2>&1; then
    tot_bytes=$(docker_exec_quiet "$c" cat /sys/fs/cgroup/memory.current) || tot_bytes=0
    stat=$(docker exec "$c" cat /sys/fs/cgroup/memory.stat 2>/dev/null)
    rss_bytes=$(to_int "$(echo "$stat" | grep -w "anon" | awk '{print $2}')")
    cache_bytes=$(to_int "$(echo "$stat" | grep -w "file" | awk '{print $2}')")
  else
    tot_bytes=$(docker_exec_quiet "$c" cat /sys/fs/cgroup/memory/memory.usage_in_bytes) || tot_bytes=0
    stat=$(docker exec "$c" cat /sys/fs/cgroup/memory/memory.stat 2>/dev/null)
    rss_bytes=$(to_int "$(echo "$stat" | grep -w "rss" | awk '{print $2}')")
    cache_bytes=$(to_int "$(echo "$stat" | grep -w "cache" | awk '{print $2}')")
  fi
  read_cgroup_extras "$stat"
  local smaps
  smaps=$(docker exec "$c" sh -c 'grep -E "^(Anonymous|Private_Clean|Private_Dirty|Swap):" /proc/1/smaps_rollup 2>/dev/null' 2>/dev/null)
  if [ -n "$smaps" ]; then
    proc_anon_mb=$(kb2mb "$(echo "$smaps" | awk '/^Anonymous:/{print $2}')")
    proc_priv_clean_mb=$(kb2mb "$(echo "$smaps" | awk '/^Private_Clean:/{print $2}')")
    proc_priv_dirty_mb=$(kb2mb "$(echo "$smaps" | awk '/^Private_Dirty:/{print $2}')")
    proc_swap_mb=$(kb2mb "$(echo "$smaps" | awk '/^Swap:/{print $2}')")
  fi
  db_fds=$(to_int "$(docker exec "$c" sh -c "ls -l /proc/1/fd | grep database | wc -l" 2>/dev/null)")
  raw_nmt=$(docker exec "$c" jattach 1 jcmd "VM.native_memory summary" 2>/dev/null)
  heap_info=$(docker exec "$c" jattach 1 jcmd "GC.heap_info" 2>/dev/null)
  if ! echo "$raw_nmt" | grep -q "^Total:"; then
    raw_nmt=""
    heap_info=""
  else
    parse_heap_used_mb "$heap_info"
  fi
  fetch_rocksdb_metrics "$(metrics_port_for "$c")"
}

fetch_local_metrics() {
  local pid
  pid=$(find_local_rskj_pid) || return 1
  reset_extended_metrics
  read_os_memory "$pid"
  read_process_smaps "$pid"
  db_fds=$(count_db_fds "$pid")
  raw_nmt=$(run_jcmd "$pid" VM.native_memory summary)
  heap_info=$(run_jcmd "$pid" GC.heap_info)
  parse_heap_used_mb "$heap_info"
  fetch_rocksdb_metrics "${RSKJ_METRICS_PORT:-}"
}

nmt_enabled=1

compute_metrics() {
  h_comm_mb=0
  nmt_comm_mb=0
  nmt_oth_mb=0
  internal_mb=0
  gc_mb=0
  threads_mb=0
  metaspace_mb=0
  code_mb=0
  non_jvm_mb=0
  nmt_enabled=1

  if [ -z "$raw_nmt" ]; then
    if [ "$(to_int "$tot_bytes")" -gt 0 ]; then
      tot_mb=$(b2mb "$tot_bytes")
      rss_mb=$(b2mb "$rss_bytes")
      cache_mb=$(b2mb "$cache_bytes")
      nmt_enabled=0
      non_jvm_mb=0
      return 0
    fi
    return 1
  fi

  tot_mb=$(b2mb "$tot_bytes")
  rss_mb=$(b2mb "$rss_bytes")
  cache_mb=$(b2mb "$cache_bytes")
  non_jvm_mb=$(( rss_mb ))
  gc_mb=0
  threads_mb=0
  metaspace_mb=0
  code_mb=0
  internal_mb=0
  nmt_oth_mb=0
  h_comm_mb=0
  nmt_comm_mb=0

  if echo "$raw_nmt" | grep -qi "tracking is not enabled"; then
    nmt_enabled=0
    non_jvm_mb=$rss_mb
    return 0
  fi

  if ! echo "$raw_nmt" | grep -q "^Total:"; then
    return 1
  fi
  nmt_enabled=1

  local nmt_committed_kb heap_committed_kb gc_kb thr_kb meta_kb code_kb internal_kb
  nmt_committed_kb=$(extract_nmt "$(echo "$raw_nmt" | grep "^Total:")")
  heap_committed_kb=$(extract_nmt "$(echo "$raw_nmt" | grep "Java Heap" | head -1)")
  gc_kb=$(extract_nmt "$(echo "$raw_nmt" | grep -m1 "GC ")")
  thr_kb=$(extract_nmt "$(echo "$raw_nmt" | grep -m1 "Thread ")")
  meta_kb=$(extract_nmt "$(echo "$raw_nmt" | grep -m1 "Metaspace ")")
  code_kb=$(extract_nmt "$(echo "$raw_nmt" | grep -m1 "Code ")")
  internal_kb=$(extract_nmt "$(echo "$raw_nmt" | grep -m1 "Internal ")")

  tot_mb=$(b2mb "$tot_bytes")
  rss_mb=$(b2mb "$rss_bytes")
  cache_mb=$(b2mb "$cache_bytes")
  h_comm_mb=$(kb2mb "$heap_committed_kb")
  nmt_comm_mb=$(kb2mb "$nmt_committed_kb")
  gc_mb=$(kb2mb "$gc_kb")
  threads_mb=$(kb2mb "$thr_kb")
  metaspace_mb=$(kb2mb "$meta_kb")
  code_mb=$(kb2mb "$code_kb")
  internal_mb=$(kb2mb "$internal_kb")
  nmt_oth_mb=$(( nmt_comm_mb - h_comm_mb - gc_mb - threads_mb - metaspace_mb - code_mb - internal_mb ))
  [ "$nmt_oth_mb" -lt 0 ] && nmt_oth_mb=0

  # non_jvm = native memory outside JVM NMT (RocksDB, jemalloc, etc.)
  # Loaded Docker nodes: resident anon exceeds NMT virtual → rss - nmt_committed.
  # Lighter nodes (rss < nmt_committed, e.g. local -Xms=-Xmx): use committed heap
  # envelope, NOT heap_used — G1 sawtooth would otherwise spike non_jvm after every GC.
  local nmt_native_mb
  nmt_native_mb=$(( gc_mb + threads_mb + metaspace_mb + code_mb + internal_mb + nmt_oth_mb ))
  if [ "$rss_mb" -gt "$nmt_comm_mb" ]; then
    non_jvm_mb=$(( rss_mb - nmt_comm_mb ))
  else
    non_jvm_mb=$(( rss_mb - h_comm_mb - nmt_native_mb ))
    [ "$non_jvm_mb" -lt 0 ] && non_jvm_mb=0
  fi
  return 0
}

fmt_mb() {
  if [ "$1" = "0" ] && [ "$nmt_enabled" = "0" ]; then
    echo "N/A"
  else
    echo "${1} MB"
  fi
}

print_compact_row() {
  local name="$1"
  printf "%-13s  %9s  %9s  %9s  %9s  %9s  %9s  %9s  %4s\n" \
    "$name" "${tot_mb} MB" "${cache_mb} MB" "${rss_mb} MB" \
    "$(fmt_mb "$h_comm_mb")" "$(fmt_mb "$nmt_comm_mb")" "$(fmt_mb "$nmt_oth_mb")" "$(fmt_mb "$internal_mb")" "${db_fds:-0}"
}

extended_csv_suffix() {
  echo "$heap_used_mb,$proc_anon_mb,$proc_priv_clean_mb,$proc_priv_dirty_mb,$proc_swap_mb,$cgrp_swapcached_mb,$cgrp_anon_thp_mb,$rdb_memtables_mb,$rdb_block_cache_mb,$rdb_pending_compact_mb,$rdb_table_readers_mb,$rdb_sst_mb"
}

append_csv_row() {
  local name="$1"
  local HISTORY_FILE="results/nmt/nmt_history.csv"
  mkdir -p "$(dirname "$HISTORY_FILE")"
  if [ ! -f "$HISTORY_FILE" ]; then
    echo "$CSV_HEADER" > "$HISTORY_FILE"
  else
    upgrade_csv_header_if_needed "$HISTORY_FILE"
  fi
  if [ "$nmt_enabled" = "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$name,$tot_mb,$rss_mb,$cache_mb,,,,,,,,,,${db_fds:-0},$(extended_csv_suffix)" >> "$HISTORY_FILE"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$name,$tot_mb,$rss_mb,$cache_mb,$nmt_comm_mb,$h_comm_mb,$gc_mb,$threads_mb,$metaspace_mb,$code_mb,$internal_mb,$nmt_oth_mb,$non_jvm_mb,${db_fds:-0},$(extended_csv_suffix)" >> "$HISTORY_FILE"
  fi
}

print_csv_line() {
  local name="$1"
  if [ "$nmt_enabled" = "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$name,$tot_mb,$rss_mb,$cache_mb,,,,,,,,,,${db_fds:-0},$(extended_csv_suffix)"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$name,$tot_mb,$rss_mb,$cache_mb,$nmt_comm_mb,$h_comm_mb,$gc_mb,$threads_mb,$metaspace_mb,$code_mb,$internal_mb,$nmt_oth_mb,$non_jvm_mb,${db_fds:-0},$(extended_csv_suffix)"
  fi
}

is_local_target() {
  case "$1" in
    local|rskj-local|"$LOCAL_NAME") return 0 ;;
  esac
  return 1
}

compact_row() {
  local target="$1"
  local name="$target"
  if is_local_target "$target"; then
    name="$LOCAL_NAME"
    fetch_local_metrics || {
      printf "%-13s  %9s  %9s  %9s  %9s  %9s  %9s  %9s  %4s\n" \
        "$name" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
      return
    }
  else
    fetch_docker_metrics "$target"
  fi
  if ! compute_metrics; then
    printf "%-13s  %9s  %9s  %9s  %9s  %9s  %9s  %9s  %4s\n" \
      "$name" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
    return
  fi
  print_compact_row "$name"
  append_csv_row "$name"
}

csv_row() {
  local target="$1"
  local name="$target"
  if is_local_target "$target"; then
    name="$LOCAL_NAME"
    fetch_local_metrics || {
      echo "$(date '+%Y-%m-%d %H:%M:%S'),$name,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
      return
    }
  else
    fetch_docker_metrics "$target"
  fi
  if ! compute_metrics; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$name,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A"
    return
  fi
  print_csv_line "$name"
}

run_nmt() {
  local target="$1"
  echo ""
  echo "======================================================="
  echo " NMT ${MODE}: ${target}  ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "======================================================="
  if is_local_target "$target"; then
    local pid
    pid=$(find_local_rskj_pid) || { echo "No local co.rsk.Start process found (set RSKJ_PID?)"; return 1; }
    echo "Local JVM: $(local_process_label "$pid")"
    run_jcmd "$pid" VM.native_memory "${MODE}"
    return
  fi
  if ! docker_container_exec_ok "$target"; then
    echo "docker exec unavailable for ${target} (rebuild/recreate container?)"
    return 1
  fi
  docker exec "$target" jattach 1 jcmd "VM.native_memory ${MODE}" 2>&1
}

TARGETS=()
if [ "$TARGET" = "all" ]; then
  TARGETS=("${DOCKER_CONTAINERS[@]}")
  if find_local_rskj_pid >/dev/null 2>&1; then
    TARGETS+=("$LOCAL_NAME")
  fi
elif is_local_target "$TARGET"; then
  TARGETS=("$LOCAL_NAME")
else
  TARGETS=("$TARGET")
fi

if [ "$MODE" = "csv" ]; then
  echo "$CSV_HEADER"
  for t in "${TARGETS[@]}"; do
    csv_row "$t"
  done
elif [ "$MODE" = "compact" ] || { [ "$TARGET" = "all" ] && [ "$MODE" = "summary" ]; }; then
  echo "NMT Summary (RESIDENT: Total≈RSS+Cache | VIRTUAL: NMT=Heap+Oth) — $(date '+%Y-%m-%d %H:%M:%S')"
  if pid=$(find_local_rskj_pid 2>/dev/null); then
    echo "Local node: $(local_process_label "$pid")"
  fi
  echo ""
  printf "%-13s  %9s  %9s  %9s  %9s  %9s  %9s  %9s  %4s\n" \
    "CONTAINER" "TOTAL(R)" "CACHE(R)" "RSS(R)" "HEAP(V)" "NMT(V)" "NMT_OTH(V)" "INTERNAL(V)" "FDS"
  printf "%-13s  %9s  %9s  %9s  %9s  %9s  %9s  %9s  %4s\n" \
    "-------------" "---------" "---------" "---------" "---------" "---------" "---------" "---------" "----"
  for t in "${TARGETS[@]}"; do
    compact_row "$t"
  done
elif [ "$TARGET" = "all" ]; then
  for t in "${TARGETS[@]}"; do
    run_nmt "$t"
  done
else
  run_nmt "$TARGET"
fi
