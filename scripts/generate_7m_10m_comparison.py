import os
import pandas as pd
import numpy as np
import glob
from pathlib import Path

# Reuse parsing logic from previous script
def clean_value(val):
    if pd.isna(val) or val == '': return np.nan
    if isinstance(val, str):
        val = val.replace('%', '').strip()
        if val == '': return np.nan
    try: return float(val)
    except: return np.nan

def parse_time_value(val):
    if pd.isna(val) or val == '': return np.nan
    if isinstance(val, str):
        val = val.strip()
        if val == '' or val == '0 s': return 0.0
        if 'ms' in val: return float(val.replace('ms', '').strip()) / 1000.0
        elif 'µs' in val or 'us' in val: return float(val.replace('µs', '').replace('us', '').strip()) / 1000000.0
        elif 's' in val: return float(val.replace('s', '').strip())
        else:
            try: return float(val)
            except: return np.nan
    try: return float(val)
    except: return np.nan

def parse_size_value(val, target_unit='MiB'):
    if pd.isna(val) or val == '': return np.nan
    if isinstance(val, str):
        val = val.strip()
        if 'GiB' in val:
            num = float(val.replace('GiB', '').strip())
            return num * 1024.0 if target_unit == 'MiB' else num
        elif 'MiB' in val:
            num = float(val.replace('MiB', '').strip())
            return num / 1024.0 if target_unit == 'GiB' else num
        elif 'KiB' in val:
            num = float(val.replace('KiB', '').strip())
            return num / 1024.0 if target_unit == 'MiB' else num
        else:
            try: return float(val)
            except: return np.nan
    try: return float(val)
    except: return np.nan

def find_col(df, miner_name):
    for col in df.columns:
        if miner_name.lower() in col.lower(): return col
    return None

def find_all_cols(df, miner_name):
    out = []
    m = miner_name.lower()
    for col in df.columns:
        if col == 'Time': continue
        if m in col.lower(): out.append(col)
    return out

def calculate_stats(values, auto_convert=None):
    if values is None or len(values) == 0: return None
    values = np.abs(values)
    mean_val = np.mean(values)
    if auto_convert == 'bytes_to_mib':
        if mean_val > 1000000: values = values / (1024 * 1024.0)
    elif auto_convert == 'bytes_to_mib_s':
        if mean_val > 1000000: values = values / (1024 * 1024.0)
    return {'mean': np.mean(values), 'std': np.std(values)}

def get_stats(run_dir, miner_name):
    stats = {}
    
    # Block Processing Time
    files = glob.glob(str(run_dir / 'data' / 'Block_Proc_Time_Histo-data-as-joinbyfield-*.csv'))
    if files:
        df = pd.read_csv(files[0])
        cols = find_all_cols(df, miner_name)
        if cols:
            vals = np.concatenate([df[c].apply(parse_time_value).dropna().values for c in cols])
            vals = vals[~np.isnan(vals)]
            if len(vals) > 0:
                res = calculate_stats(vals)
                stats['block_proc_avg'] = res['mean']
                stats['block_proc_sd'] = res['std']
    
    # CPU Usage
    files = glob.glob(str(run_dir / 'data' / 'CPU_Usage_per_Container-data-as-joinbyfield-*.csv'))
    if files:
        df = pd.read_csv(files[0])
        col = find_col(df, miner_name)
        if col:
            vals = df[col].apply(clean_value).dropna().values
            if len(vals) > 0:
                res = calculate_stats(vals)
                stats['cpu_avg'] = res['mean']
                
    # Disk Write
    files = glob.glob(str(run_dir / 'data' / 'Disk_Write-data-as-joinbyfield-*.csv'))
    if files:
        df = pd.read_csv(files[0])
        col = find_col(df, miner_name)
        if col:
            vals = df[col].apply(lambda x: clean_value(x)).dropna().values # use clean_value for simplicity if already in MB/s
            if len(vals) > 0:
                res = calculate_stats(vals, 'bytes_to_mib_s')
                stats['disk_write_avg'] = res['mean']
                
    # Memory Usage
    files = glob.glob(str(run_dir / 'data' / 'Memory_Usage_per_Container-data-as-joinbyfield-*.csv'))
    if files:
        df = pd.read_csv(files[0])
        col = find_col(df, miner_name)
        if col:
            vals = df[col].apply(lambda x: parse_size_value(x, 'MiB')).dropna().values
            if len(vals) > 0:
                res = calculate_stats(vals, 'bytes_to_mib')
                stats['mem_avg'] = res['mean'] / 1024.0 # Convert to GiB
                
    return stats

def main():
    root = Path('/Users/patricio/workspace/rsk/rsk-simulation')
    output_path = root / 'reports' / 'unified_7M_10M_2cpu_4cpu_comparison.md'
    
    configs = {
        '2 CPU': root / 'results' / '2cpu',
        '4 CPU': root / 'results' / '4cpu'
    }
    gas_limits = ['7M', '10M']
    categories = {
        'CPU': ['cpu', 'cpu-ecdsa'], # 2cpu name, 4cpu name
        'Real-World': ['real-world', 'real-world']
    }
    
    report = "# Unified Analysis: 7M vs 10M Gas Comparison (2 CPU vs 4 CPU)\n\n"
    report += "This report compares the performance of RSKj nodes under 7M and 10M Gas Limits across different hardware configurations (2 CPU vs 4 CPU).\n\n"
    
    for miner in ['miner1', 'node1']:
        report += f"## 📊 {miner.capitalize()} Performance Comparison\n\n"
        report += "| Gas Limit | Hardware | Category | Block Proc Time (Avg) | Block Proc SD | CPU (Avg) | Disk Write (Avg) | Mem (Avg) |\n"
        report += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"
        
        for limit in gas_limits:
            for cpu_label, base_dir in configs.items():
                for cat_label, dir_names in categories.items():
                    # Pick the right directory name for this config
                    dir_name = dir_names[0] if '2cpu' in str(base_dir) else dir_names[1]
                    cat_path = base_dir / dir_name
                    
                    run_folders = list(cat_path.glob(f"{limit}_*"))
                    if not run_folders: continue
                    
                    # Sort by duration/name to get a representative run if multiple (usually only one for 4cpu)
                    run_dir = sorted(run_folders, key=lambda x: x.name, reverse=True)[0]
                    stats = get_stats(run_dir, miner)
                    
                    if stats:
                        avg = f"{stats.get('block_proc_avg', 0):.3f}s"
                        sd = f"{stats.get('block_proc_sd', 0):.3f}s"
                        cpu = f"{stats.get('cpu_avg', 0):.1f}%"
                        disk = f"{stats.get('disk_write_avg', 0):.1f} MiB/s"
                        mem = f"{stats.get('mem_avg', 0):.1f} GiB"
                        report += f"| {limit} | {cpu_label} | {cat_label} | **{avg}** | {sd} | {cpu} | {disk} | {mem} |\n"
        report += "\n"
        
    report += "---\n\n## 🔍 Key Insights\n\n"
    report += "### 1. Scaling from 2 to 4 CPUs\n"
    report += "Doubling the CPU allocation provides a significant reduction in block processing time, especially for computation-heavy blocks. In the 10M scenario, the 4 CPU config brings the worst-case processing times back into a safer range.\n\n"
    
    report += "### 2. Physical Resource Efficiency\n"
    report += "While RAM usage remains similar regardless of CPU count, the 4 CPU configuration operates at a lower percentage of its overall capacity, reducing jitter and providing better stability during sync spikes.\n\n"
    
    report += "### 3. Impact of 10M Gas Increase\n"
    report += "Moving from 7M to 10M gas increases processing time non-linearly on 2 CPU hardware. The 4 CPU configuration effectively mitigates this scaling penalty, ensuring the node can handle higher transaction throughput with healthy headroom.\n"
    
    with open(output_path, 'w') as f:
        f.write(report)
    print(f"Generated {output_path}")

if __name__ == '__main__':
    main()
