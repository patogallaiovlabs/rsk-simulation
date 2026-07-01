#!/bin/bash
# analyze_native_memory.sh - Inspect memory segments of a running RSKj container

CONTAINER=${1:-rskj-miner1}

echo "======================================================="
echo " Analyzing Native Memory for: ${CONTAINER}"
echo "======================================================="

# 1. Show pmap summary (top 20 largest segments)
echo ""
echo "[1] Largest Memory Segments (pmap -x):"
docker exec "$CONTAINER" sh -c "pmap -x 1 | sort -k3 -rn | head -20"

# 2. Show NMT summary (for comparison)
echo ""
echo "[2] JVM Native Memory Tracking (Summary):"
docker exec "$CONTAINER" jattach 1 jcmd "VM.native_memory summary" | grep -A 20 "Total:"

# 3. Check for specific large anonymous mappings
echo ""
echo "[3] Potential RocksDB / Native Library allocations (Anon segments > 10MB):"
docker exec "$CONTAINER" sh -c "pmap -x 1 | grep anon | awk '\$3 > 10000 {print \$0}'"

echo ""
echo "Note: 'non_jvm_mb' is calculated as RSS - NMT_Committed."
echo "If you see large 'anon' segments in [3] that are NOT in [2], these are JNI/native allocations."
