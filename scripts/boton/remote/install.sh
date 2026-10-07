#!/usr/bin/env bash
# Runs ON a Boton box. Installs a regtest stress miner over the packaged RSKj
# layout, backing up whatever is deployed first. Expects these in /tmp:
#   rsk-new.jar  stress.conf  logback.xml  genesis.json  sysconfig-rsk
set -euo pipefail
STAMP=$(date +%Y%m%d-%H%M%S)
echo "=== stopping rsk ==="
sudo systemctl stop rsk || true

echo "=== backing up (stamp $STAMP) ==="
[ -f /usr/share/rsk/rsk.jar ] && sudo cp -a /usr/share/rsk/rsk.jar "/usr/share/rsk/rsk.jar.bak-$STAMP"
[ -f /etc/sysconfig/rsk ]     && sudo cp -a /etc/sysconfig/rsk     "/etc/sysconfig/rsk.bak-$STAMP"

echo "=== reset database + logs (keeping /var/lib/rsk mount) ==="
sudo rm -rf /var/lib/rsk/database /var/log/rsk/stress
sudo install -d -o rsk -g rsk -m 0755 /var/lib/rsk/database /var/log/rsk/stress

# Restore the pre-loaded database if a seed is present, rather than starting from
# genesis. Every run then begins from byte-identical, already-populated state -- no
# warm-up bias, and the receipt/state paths are exercised at realistic size from block
# one. The seed is staged once per box at ~/seed-loaded-1159.tar.gz; its internal layout
# is test/local-regtest/database/... whereas this node uses -Ddatabase.dir=
# /var/lib/rsk/database, hence --strip-components=3.
SEED="${SEED:-/home/ubuntu/seed-loaded-1159.tar.gz}"
if [ -f "$SEED" ]; then
  echo "    restoring seed $(basename "$SEED") ($(du -h "$SEED" | cut -f1))"
  sudo tar xzf "$SEED" -C /var/lib/rsk/database --strip-components=3 \
    || { echo "    seed restore FAILED" >&2; exit 1; }
  sudo chown -R rsk:rsk /var/lib/rsk/database
  echo "    database now: $(sudo du -sh /var/lib/rsk/database | cut -f1)"
else
  echo "    no seed at $SEED -- starting from an EMPTY database"
fi

echo "=== installing ==="
sudo install -o rsk -g rsk -m 0644 /tmp/rsk-new.jar /usr/share/rsk/rsk.jar
sudo install -m 0644 /tmp/stress.conf      /etc/rsk/stress.conf
sudo install -m 0644 /tmp/logback.xml      /etc/rsk/logback.xml
sudo install -m 0644 /tmp/genesis.json     /etc/rsk/genesis.json
sudo install -m 0644 /tmp/sysconfig-rsk    /etc/sysconfig/rsk

# Start both sides cold. Otherwise whatever happened to be in page cache before the
# run silently advantages one box: in run 2 the baseline read 1MB from disk over 2.5h
# while the tip read 1246MB, which is most of the explanation for its slower
# txExecutionMs. Cold start makes that a property of the build, not of history.
echo "=== dropping page cache ==="
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
echo "  MemAvailable now: $(awk '/MemAvailable/{print $2/1024" MB"}' /proc/meminfo)"

echo "=== starting ==="
sudo systemctl start rsk
sleep 8
echo "service: $(systemctl is-active rsk)"
sudo grep -m1 "git.hash" /var/log/rsk/stress/rsk.log 2>/dev/null || true
df -h /var/lib/rsk | tail -1
