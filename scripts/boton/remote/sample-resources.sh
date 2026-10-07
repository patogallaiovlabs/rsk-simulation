#!/usr/bin/env bash
# Runs ON a Boton box. Samples node resource usage alongside a load run, so a
# build comparison covers more than block timings: CPU, RSS, disk I/O and
# database growth are all things the storage/receipt optimizations move.
#
#   nohup bash sample-resources.sh [interval_s] [out.csv] &
#
# Writes a CSV plus periodic NMT dumps (the JVM runs with
# -XX:NativeMemoryTracking=summary, so jcmd can break native memory down).
set -u
INTERVAL="${1:-15}"
OUT="${2:-/home/ubuntu/results/resources.csv}"
NMT_DIR="$(dirname "$OUT")/nmt"
mkdir -p "$NMT_DIR" "$(dirname "$OUT")"

sudo -n true 2>/dev/null || { echo "need passwordless sudo for /proc/<pid>/io" >&2; exit 1; }

python3 - "$INTERVAL" "$OUT" "$NMT_DIR" <<'PY'
import os,sys,time,subprocess,shutil

interval=float(sys.argv[1]); out=sys.argv[2]; nmt_dir=sys.argv[3]
HZ=os.sysconf("SC_CLK_TCK")

def pid():
    try: return int(subprocess.check_output(["pgrep","-f","co.rsk.Start"]).split()[0])
    except Exception: return None

def sudo_read(p):
    try: return subprocess.check_output(["sudo","-n","cat",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return ""

def cpu_ticks(p):
    s=sudo_read(f"/proc/{p}/stat")
    if not s: return None
    f=s[s.rfind(")")+2:].split()
    return int(f[11])+int(f[12])          # utime + stime

def rss_vm(p):
    st=sudo_read(f"/proc/{p}/status"); r=v=0
    for line in st.splitlines():
        if line.startswith("VmRSS:"):  r=int(line.split()[1])//1024
        if line.startswith("VmSize:"): v=int(line.split()[1])//1024
    return r,v

def io(p):
    d={}
    for line in sudo_read(f"/proc/{p}/io").splitlines():
        k,_,val=line.partition(":")
        try: d[k.strip()]=int(val)
        except ValueError: pass
    return d

def db_mb():
    try: return int(subprocess.check_output(["sudo","-n","du","-sm","/var/lib/rsk/database"]).split()[0])
    except Exception: return -1

new = not os.path.exists(out)
fh=open(out,"a",buffering=1)
if new:
    fh.write("ts,cpu_pct,rss_mb,vmsize_mb,db_mb,read_mb,write_mb,rchar_mb,wchar_mb,mem_avail_mb,load1\n")

prev_t=prev_c=None; prev_io=None; n=0
while True:
    p=pid()
    if p:
        c=cpu_ticks(p); t=time.time()
        cpu=""
        if prev_c is not None and c is not None and t>prev_t:
            cpu=f"{100.0*(c-prev_c)/HZ/(t-prev_t):.1f}"
        prev_c, prev_t = c, t
        r,v=rss_vm(p); d=io(p)
        rd=d.get("read_bytes",0)//(1024*1024); wr=d.get("write_bytes",0)//(1024*1024)
        rc=d.get("rchar",0)//(1024*1024);      wc=d.get("wchar",0)//(1024*1024)
        avail=0
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"): avail=int(line.split()[1])//1024
        load1=open("/proc/loadavg").read().split()[0]
        fh.write(f"{time.strftime('%H:%M:%S',time.gmtime())},{cpu},{r},{v},{db_mb()},{rd},{wr},{rc},{wc},{avail},{load1}\n")
        # NMT snapshot every ~5 minutes -- jcmd is heavier, do not do it every tick
        if n % max(1,int(300/interval)) == 0 and shutil.which("jcmd"):
            try:
                o=subprocess.check_output(["sudo","-n","-u","rsk","jcmd",str(p),"VM.native_memory","summary"],
                                          stderr=subprocess.DEVNULL,timeout=30).decode()
                open(os.path.join(nmt_dir,f"nmt_{time.strftime('%H%M%S',time.gmtime())}.txt"),"w").write(o)
            except Exception: pass
        n+=1
    time.sleep(interval)
PY
