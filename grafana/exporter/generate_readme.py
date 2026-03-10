#!/usr/bin/env python3
"""
Generate README, quantitative reports, and performance dashboards for exported Grafana data.
Integrates logic from analyze_7m_baseline.py and generate_performance_dashboards.py.
"""

import yaml
import pandas as pd
import numpy as np
import os
import glob
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.stats import gaussian_kde
from pathlib import Path
from typing import Dict, List, Optional, Any

# --- Data Cleaning & Parsing (from analyze_7m_baseline.py) ---

def clean_value(val):
    if pd.isna(val) or val == '':
        return np.nan
    if isinstance(val, str):
        val = val.replace('%', '').strip()
        if val == '':
            return np.nan
    try:
        return float(val)
    except (ValueError, TypeError):
        return np.nan

def parse_time_value(val):
    if pd.isna(val) or val == '':
        return np.nan
    if isinstance(val, str):
        val = val.strip()
        if val == '' or val == '0 s':
            return 0.0
        if 'ms' in val:
            return float(val.replace('ms', '').strip()) / 1000.0
        elif 'µs' in val or 'us' in val:
            return float(val.replace('µs', '').replace('us', '').strip()) / 1000000.0
        elif 's' in val:
            return float(val.replace('s', '').strip())
        else:
            try: return float(val)
            except ValueError: return np.nan
    try: return float(val)
    except: return np.nan

def parse_size_value(val, target_unit='MiB'):
    if pd.isna(val) or val == '':
        return np.nan
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

def parse_network_value(val):
    if pd.isna(val) or val == '':
        return np.nan
    if isinstance(val, str):
        val = val.strip()
        if 'MB/s' in val or 'MiB/s' in val:
            return float(val.replace('MB/s', '').replace('MiB/s', '').strip()) * 1024.0
        elif 'kB/s' in val or 'KiB/s' in val:
            return float(val.replace('kB/s', '').replace('KiB/s', '').strip())
        elif 'B/s' in val:
            return float(val.replace('B/s', '').strip()) / 1024.0
        else:
            try: return float(val)
            except: return np.nan
    try: return float(val)
    except: return np.nan

def parse_disk_value(val):
    if pd.isna(val) or val == '':
        return np.nan
    if isinstance(val, str):
        val = val.strip()
        if 'MB/s' in val or 'MiB/s' in val:
            return float(val.replace('MB/s', '').replace('MiB/s', '').strip())
        elif 'kB/s' in val or 'KiB/s' in val:
            return float(val.replace('kB/s', '').replace('KiB/s', '').strip()) / 1024.0
        elif 'B/s' in val:
            return float(val.replace('B/s', '').strip()) / (1024*1024.0)
        else:
            try: return float(val)
            except: return np.nan
    try: return float(val)
    except: return np.nan

def find_col(df, miner_name, metric_pattern=None, fallback=False):
    for col in df.columns:
        col_lower = col.lower()
        if miner_name.lower() in col_lower:
            if metric_pattern:
                if metric_pattern.lower() in col_lower:
                    return col
            else:
                return col
    
    # Fallback to first non-time column for global/aggregate metrics
    if fallback and len(df.columns) > 1:
        return df.columns[1]
    return None


def find_all_cols(df, miner_name):
    """Return all column names that contain miner_name (e.g. for Histo CSVs with multiple series per container)."""
    out = []
    m = miner_name.lower()
    for col in df.columns:
        if col == 'Time':
            continue
        if m in col.lower():
            out.append(col)
    return out

def calculate_stats(values, auto_convert=None):
    if values is None or len(values) == 0:
        return None
    
    # Use absolute values for everything (handles negative network/disk in Grafana)
    values = np.abs(values)
    
    mean_val = np.mean(values)
    
    if auto_convert == 'bytes_to_mib':
        if mean_val > 1000000: # Probable bytes
            values = values / (1024 * 1024.0)
    elif auto_convert == 'bytes_to_kib':
        if mean_val > 1000: # Probable bytes
            values = values / 1024.0
    elif auto_convert == 'bytes_to_mib_s':
        if mean_val > 1000: # Probable bytes
            values = values / (1024 * 1024.0)
            
    return {
        'mean': np.mean(values),
        'median': np.median(values),
        'min': np.min(values),
        'max': np.max(values),
        'std': np.std(values),
        'count': len(values),
        'raw': values
    }

# --- Visualization (inspired by generate_performance_dashboards.py) ---

def create_performance_dashboard(title, block_times, cpu_usage, stats, output_path, x_limit=None):
    fig = plt.figure(figsize=(14, 10))
    fig.patch.set_facecolor('white')
    
    gs = fig.add_gridspec(2, 2, height_ratios=[2, 0.6], hspace=0.4, wspace=0.3, 
                          left=0.08, right=0.95, top=0.92, bottom=0.08)
    
    # Block processing time distribution (fixed high granularity so all miners look comparable)
    ax1 = fig.add_subplot(gs[0, 0])
    ax1.set_facecolor('#f8f9fa')
    if block_times is not None and len(block_times) > 1:
        n_bins = 500  # fixed high count so miner1 and miner2 look equally granular
        ax1.hist(block_times, bins=n_bins, density=True, color='#a0c4e8', alpha=0.6, edgecolor='white', linewidth=0.3)
        try:
            kde = gaussian_kde(block_times)
            x_kde = np.linspace(min(block_times), max(block_times), 500)
            ax1.plot(x_kde, kde(x_kde), 'k-', linewidth=2)
        except Exception:
            pass
        # Rug: small ticks at bottom (subsample if many points for clarity)
        ymin, _ = ax1.get_ylim()
        n_rug = min(1000, len(block_times))
        rug_x = block_times[:: max(1, len(block_times) // n_rug)][:n_rug] if len(block_times) > n_rug else block_times
        ax1.plot(rug_x, np.full_like(rug_x, ymin), '|', color='#4a90d9', markersize=2, alpha=0.4)
    ax1.set_xlabel('Block Processing Time (s)')
    ax1.set_ylabel('Density')
    ax1.set_title('Block Processing Distribution')
    if x_limit:
        ax1.set_xlim(0, x_limit)
    ax1.grid(True, alpha=0.3, linestyle='--', linewidth=0.5)
    
    # CPU Usage scatter/timeline
    ax2 = fig.add_subplot(gs[0, 1])
    ax2.set_facecolor('#f8f9fa')
    if cpu_usage is not None and len(cpu_usage) > 0:
        ax2.scatter(range(len(cpu_usage)), cpu_usage, s=6, alpha=0.35, color='#6c757d', edgecolors='none')
    ax2.set_xlabel('Sample Index')
    ax2.set_ylabel('CPU Usage (%)')
    ax2.set_title('CPU Utilization Timeline')
    ax2.grid(True, alpha=0.3, linestyle='--', linewidth=0.5)
    
    # Summary Table
    ax_table = fig.add_subplot(gs[1, :])
    ax_table.axis('off')
    
    table_data = [['Metric', 'Mean', 'Median', 'Std Dev', 'Min', 'Max']]
    if stats.get('Block Processing Time'):
        s = stats['Block Processing Time']
        table_data.append(['Block Proc Time (s)', f"{s['mean']:.4f}", f"{s['median']:.4f}", f"{s['std']:.4f}", f"{s['min']:.3f}", f"{s['max']:.3f}"])
    if stats.get('CPU Usage per Container'):
        s = stats['CPU Usage per Container']
        table_data.append(['CPU Usage (%)', f"{s['mean']:.2f}", f"{s['median']:.1f}", f"{s['std']:.2f}", f"{s['min']:.2f}", f"{s['max']:.1f}"])
    
    if len(table_data) > 1:
        table = ax_table.table(cellText=table_data[1:], colLabels=table_data[0], cellLoc='center', loc='center')
        table.auto_set_font_size(False)
        table.set_fontsize(9)
        table.scale(1, 2.2)
        for i in range(len(table_data[0])):
            table[(0, i)].set_facecolor('#e9ecef')
            table[(0, i)].set_text_props(weight='bold')
            
    fig.suptitle(title, fontsize=14, fontweight='bold', y=0.97)
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    plt.close()

def generate_individual_plots(export_dir: Path):
    """Generate a simple line plot for every CSV found in the data/ folder."""
    data_dir = export_dir / 'data'
    plots_dir = export_dir / 'plots'
    plots_dir.mkdir(parents=True, exist_ok=True)
    
    csv_files = list(data_dir.glob('*.csv'))
    if not csv_files:
        print("No CSV files found in data/ for individual plotting.")
        return

    print(f"Generating individual plots for {len(csv_files)} files...")
    for csv_file in csv_files:
        try:
            df = pd.read_csv(csv_file)
            if 'Time' not in df.columns or len(df.columns) < 2:
                continue

            # Use filename without timestamp as title
            stem_base = csv_file.stem.split('-data-as-joinbyfield-')[0]
            title = stem_base.replace('_', ' ')
            is_difficulty = 'Block_Difficulty' in stem_base or 'Block Difficulty' in title

            plt.figure(figsize=(10, 6))
            plt.style.use('bmh')

            df['Time'] = pd.to_datetime(df['Time'])
            all_vals = []
            for col in df.columns[1:]:
                series_data = df[col].apply(clean_value)
                plt.plot(df['Time'], series_data, label='_nolegend_', alpha=0.7)
                all_vals.extend(series_data.dropna().tolist())

            if is_difficulty:
                plt.ylim(20, 50)
                if all_vals:
                    all_vals = np.array([v for v in all_vals if not np.isnan(v)])
                    if len(all_vals) > 0:
                        mean_val = np.mean(all_vals)
                        median_val = np.median(all_vals)
                        plt.axhline(y=mean_val, color='green', linestyle='--', linewidth=2, label=f'Mean: {mean_val:.4g}')
                        plt.axhline(y=median_val, color='orange', linestyle='-.', linewidth=2, label=f'Median: {median_val:.4g}')

            plt.title(f"Metric: {title}", fontsize=12, fontweight='bold')
            plt.xlabel("Time")
            plt.ylabel("Value")
            plt.xticks(rotation=45)
            if is_difficulty:
                plt.legend(loc='upper center', bbox_to_anchor=(0.5, -0.12), ncol=2, fontsize='small', frameon=True)

            plt.tight_layout(rect=[0, 0.08, 1, 1])
            plot_path = plots_dir / f"{csv_file.stem}.png"
            plt.savefig(plot_path, dpi=150, bbox_inches='tight')
            plt.close()
        except Exception as e:
            print(f"  Warning: Failed to plot {csv_file.name}: {e}")

# --- Main Logic ---

def parse_docker_compose(compose_file: str) -> Dict[str, Dict]:
    with open(compose_file) as f:
        compose = yaml.safe_load(f)
    configs = {}
    for service_name, service_config in compose.get('services', {}).items():
        if service_name.startswith('rskj-'):
            env = service_config.get('environment', [])
            fb = '100'
            im = False
            for e in env:
                if 'FLUSH_BLOCKS=' in e: fb = e.split('=')[1].replace('${FLUSH_BLOCKS:-', '').replace('}', '')
                if 'IS_MINER=true' in e: im = True
            limits = service_config.get('deploy', {}).get('resources', {}).get('limits', {}) or {}
            cpus = limits.get('cpus', '')
            memory = limits.get('memory', '')
            if isinstance(cpus, (int, float)):
                cpus = str(cpus)
            elif isinstance(cpus, str):
                cpus = cpus.strip("'\"")
            configs[service_name] = {'flush_blocks': fb, 'is_miner': im, 'cpus': cpus, 'memory': memory}
    return configs

# --- Mapping Definitions ---

KEY_FILES_MAPPING = {
    'Block Processing Time': ((lambda x: parse_time_value(x)), "Block_Proc_Time_Histo-data-as-joinbyfield-*.csv", None),
    'BlockExecution JMX': ((lambda x: parse_time_value(x)), "BlockExecution_JMX___1s-data-as-joinbyfield-*.csv", None),
    'CPU Usage per Container': ((lambda x: clean_value(x)), "CPU_Usage_per_Container-data-as-joinbyfield-*.csv", None),
    'Memory Usage per Container': ((lambda x: parse_size_value(x, 'MiB')), "Memory_Usage_per_Container-data-as-joinbyfield-*.csv", 'bytes_to_mib'),
    'Disk Read': ((lambda x: parse_disk_value(x)), "Disk_Read-data-as-joinbyfield-*.csv", 'bytes_to_mib_s'),
    'Disk Write': ((lambda x: parse_disk_value(x)), "Disk_Write-data-as-joinbyfield-*.csv", 'bytes_to_mib_s'),
    'Gas Consumption': ((lambda x: clean_value(x)), "Gas_Consumption-data-as-joinbyfield-*.csv", None),
    'JVM GC Collection Time': (None, "JVM_GC_Collection_Time-data-as-joinbyfield-*.csv", None),
    'JVM Heap Memory Usage': (None, "JVM_Heap_Memory_Usage-data-as-joinbyfield-*.csv", None),
    'Received Network Traffic per Container': ((lambda x: parse_network_value(x)), "Received_Network_Traffic_per_Container-data-as-joinbyfield-*.csv", 'bytes_to_kib'),
    'Sent Network Traffic per Container': ((lambda x: parse_network_value(x)), "Sent_Network_Traffic_per_Container-data-as-joinbyfield-*.csv", 'bytes_to_kib'),
    'Block Difficulty': ((lambda x: clean_value(x)), "Block_Difficulty-data-as-joinbyfield-*.csv", None),
}

COMPLETE_FILES_MAPPING = {
    'Block Processing Time': ((lambda x: parse_time_value(x)), "Block_Processing_Time-data-as-joinbyfield-*.csv", None),
    'Blockchain Flush JMX': ((lambda x: parse_time_value(x)), "Blockchain_Flush_JMX-data-as-joinbyfield-*.csv", None),
    'BlockExecution > 1s': ((lambda x: clean_value(x)), "BlockExecution___1s-data-as-joinbyfield-*.csv", None),
    'BlockExecution JMX': ((lambda x: parse_time_value(x)), "BlockExecution_JMX-data-as-joinbyfield-*.csv", None),
    'CPU Usage per Container Histogram': ((lambda x: clean_value(x)), "CPU_Usage_per_Container_Histogram-data-as-joinbyfield-*.csv", None),
    'CPU Usage per Container': ((lambda x: clean_value(x)), "CPU_Usage_per_Container-data-as-joinbyfield-*.csv", None),
    'Datasource Flush': ((lambda x: parse_time_value(x)), "Datasource_Flush-data-as-joinbyfield-*.csv", None),
    'Disk Read': ((lambda x: parse_disk_value(x)), "Disk_Read-data-as-joinbyfield-*.csv", 'bytes_to_mib_s'),
    'Disk Usage': ((lambda x: clean_value(x)), "Disk_Usage-data-as-joinbyfield-*.csv", None),
    'Disk Write': ((lambda x: parse_disk_value(x)), "Disk_Write-data-as-joinbyfield-*.csv", 'bytes_to_mib_s'),
    'Gas Consumption': ((lambda x: clean_value(x)), "Gas_Consumption-data-as-joinbyfield-*.csv", None),
    'JVM GC Collection Time': (None, "JVM_GC_Collection_Time-data-as-joinbyfield-*.csv", None),
    'JVM Heap Memory Usage': (None, "JVM_Heap_Memory_Usage-data-as-joinbyfield-*.csv", None),
    'Memory Usage per Container': ((lambda x: parse_size_value(x, 'MiB')), "Memory_Usage_per_Container-data-as-joinbyfield-*.csv", 'bytes_to_mib'),
    'Received Network Traffic per Container': ((lambda x: parse_network_value(x)), "Received_Network_Traffic_per_Container-data-as-joinbyfield-*.csv", 'bytes_to_kib'),
    'Sent Network Traffic per Container': ((lambda x: parse_network_value(x)), "Sent_Network_Traffic_per_Container-data-as-joinbyfield-*.csv", 'bytes_to_kib'),
}

def process_miner(miner_name, export_dir: Path, mappings: Dict):
    results = {}
    for metric, (parser, pattern, conv) in mappings.items():
        files = glob.glob(str(export_dir / 'data' / pattern))
        if not files: continue
        df = pd.read_csv(files[0])
        
        # Initial search (may fail for global metrics)
        col = find_col(df, miner_name)
        
        if metric == 'JVM GC Collection Time':
            copy_col = find_col(df, miner_name, "jvm_gc_collection_seconds_sum")
            if not copy_col: copy_col = find_col(df, miner_name, "copy")
            
            ms_col = find_col(df, miner_name, "marksweep")
            if not ms_col: ms_col = find_col(df, miner_name, "marksweepcompact")
            
            gc_res = {}
            if copy_col: gc_res['Copy'] = calculate_stats(df[copy_col].apply(parse_time_value).dropna().values, conv)
            if ms_col: gc_res['MarkSweep'] = calculate_stats(df[ms_col].apply(parse_time_value).dropna().values, conv)
            results[metric] = gc_res
        elif metric == 'JVM Heap Memory Usage':
            used_col = find_col(df, miner_name, "jvm_memory_bytes_used")
            if not used_col: used_col = find_col(df, miner_name, "heap")
            
            max_col = find_col(df, miner_name, "jvm_memory_bytes_max")
            if not max_col: max_col = find_col(df, miner_name, "max")
            
            heap_res = {}
            if used_col: heap_res['Used'] = calculate_stats(df[used_col].apply(lambda x: parse_size_value(x, 'MiB')).dropna().values, 'bytes_to_mib')
            if max_col: heap_res['Allocated'] = calculate_stats(df[max_col].apply(lambda x: parse_size_value(x, 'MiB')).dropna().values, 'bytes_to_mib')
            results[metric] = heap_res
        else:
            is_gas = (metric == 'Gas Consumption')
            # Block Processing Time: use all columns for this miner (Histo has multiple series per container)
            if metric == 'Block Processing Time':
                all_cols = find_all_cols(df, miner_name)
                if all_cols:
                    vals = np.concatenate([df[c].apply(parser).dropna().values for c in all_cols])
                    vals = vals[~np.isnan(vals)]
                else:
                    vals = np.array([])
                if len(vals) > 0:
                    results[metric] = calculate_stats(vals, conv)
                continue
            # Use the already found 'col' or fallback for gas
            if not col:
                col = find_col(df, miner_name, fallback=is_gas)
            
            if not col: continue
            
            vals = df[col].apply(parser).dropna().values
            if is_gas and len(vals) > 0 and np.mean(vals) > 1000:
                vals = vals / 1e6
            results[metric] = calculate_stats(vals, conv)
            
    return results

def format_stat(val, decimals=2):
    return f"{val:.{decimals}f}" if val is not None and not np.isnan(val) else 'N/A'

def generate_miner_report(miner_name, results, output_path, img_path, resource_limits=None):
    report = f"# {miner_name.replace('rskj-', '').capitalize()} Quantitative Performance Report\n\n"
    report += "| Category | Metric | Unit | Mean | Median | Min | Max |\n"
    report += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"
    
    order = [
        ('Processing', 'Block Processing Time', 's', 3),
        ('', 'BlockExecution JMX', 's', 3),
        ('', 'Gas Consumed (per block)', 'M units', 2),
        ('Resources', 'CPU Usage per Container', '%', 2),
        ('', 'Memory Usage per Container', 'MiB', 1),
        ('', 'CPU & Memory Assigned', '-', 0),
        ('JVM', 'JVM Heap Used', 'MiB', 1),
        ('', 'JVM Heap Allocated', 'MiB', 1),
        ('JVM GC', 'JVM GC', 's', 4),
        ('Disk I/O', 'Disk Read', 'MiB/s', 3),
        ('', 'Disk Write', 'MiB/s', 3),
        ('Network', 'Received Network Traffic per Container', 'KiB/s', 2),
        ('', 'Sent Network Traffic per Container', 'KiB/s', 2),
    ]
    
    for cat, metric, unit, dec in order:
        if metric == 'CPU & Memory Assigned':
            if resource_limits and (resource_limits.get('cpus') or resource_limits.get('memory')):
                cpus = resource_limits.get('cpus', '') or '-'
                memory = resource_limits.get('memory', '') or '-'
                val = f"{cpus} CPU, {memory}"
                report += f"| | CPU & Memory Assigned | - | {val} | - | - | - |\n"
            else:
                report += f"| | CPU & Memory Assigned | - | N/A | - | - | - |\n"
        elif metric == 'JVM GC':
            gc_data = results.get('JVM GC Collection Time') or {}
            for gc_type in ('Copy', 'MarkSweep'):
                s = gc_data.get(gc_type) if isinstance(gc_data, dict) else None
                report += f"| JVM GC | GC {gc_type} Time | s | {format_stat(s['mean'], 4) if s else 'N/A'} | {format_stat(s['median'], 4) if s else 'N/A'} | {format_stat(s['min'], 3) if s else 'N/A'} | {format_stat(s['max'], 3) if s else 'N/A'} |\n"
        elif metric == 'JVM Heap Used':
            s = results.get('JVM Heap Memory Usage', {}).get('Used')
            report += f"| JVM | JVM Heap Used | MiB | {format_stat(s['mean'], 1) if s else 'N/A'} | {format_stat(s['median'], 1) if s else 'N/A'} | {format_stat(s['min'], 1) if s else 'N/A'} | {format_stat(s['max'], 1) if s else 'N/A'} |\n"
        elif metric == 'JVM Heap Allocated':
            s = results.get('JVM Heap Memory Usage', {}).get('Allocated')
            report += f"| | JVM Heap Allocated | MiB | {format_stat(s['mean'], 1) if s else 'N/A'} | {format_stat(s['median'], 1) if s else 'N/A'} | {format_stat(s['min'], 1) if s else 'N/A'} | {format_stat(s['max'], 1) if s else 'N/A'} |\n"
        elif metric == 'Gas Consumed (per block)':
            s = results.get('Gas Consumption')
            report += f"| | Gas Consumed (per block) | M units | {format_stat(s['mean'], dec) if s else 'N/A'} | {format_stat(s['median'], dec) if s else 'N/A'} | {format_stat(s['min'], dec) if s else 'N/A'} | {format_stat(s['max'], dec) if s else 'N/A'} |\n"
        else:
            s = results.get(metric)
            report += f"| {cat} | {metric} | {unit} | {format_stat(s['mean'], dec) if s else 'N/A'} | {format_stat(s['median'], dec) if s else 'N/A'} | {format_stat(s['min'], dec) if s else 'N/A'} | {format_stat(s['max'], dec) if s else 'N/A'} |\n"

    report += f"\n![Performance Dashboard]({img_path.name})\n"
    with open(output_path, 'w') as f: f.write(report)

def main():
    if len(sys.argv) < 3: sys.exit(1)
    export_dir = Path(sys.argv[1]); compose_file = sys.argv[2]
    
    configs = parse_docker_compose(compose_file)
    
    # Create output directories
    reports_dir = export_dir / 'reports'
    complete_dir = export_dir / 'reports_complete'
    reports_dir.mkdir(parents=True, exist_ok=True)
    complete_dir.mkdir(parents=True, exist_ok=True)
    
    # File lists for README
    key_files = [
        "BlockExecution_JMX___1s-data-as-joinbyfield-",
        "Block_Proc_Time_Histo-data-as-joinbyfield-",
        "Block_Processing_Time___1s-data-as-joinbyfield-",
        "Block_Difficulty-data-as-joinbyfield-",
        "CPU_Usage_per_Container-data-as-joinbyfield-",
        "CPU_Usage_per_Container_Histogram-data-as-joinbyfield-",
        "Disk_Read-data-as-joinbyfield-",
        "Disk_Usage-data-as-joinbyfield-",
        "Disk_Write-data-as-joinbyfield-",
        "Gas_Consumption-data-as-joinbyfield-",
        "JVM_GC_Collection_Time-data-as-joinbyfield-",
        "JVM_Heap_Memory_Usage-data-as-joinbyfield-",
        "Memory_Usage_per_Container-data-as-joinbyfield-",
        "Received_Network_Traffic_per_Container-data-as-joinbyfield-",
        "Sent_Network_Traffic_per_Container-data-as-joinbyfield-"
    ]
    complete_files = [
        "BlockExecution_JMX-data-as-joinbyfield",
        "Block_Processing_Time-data-as-joinbyfield",
        "Blockchain_Flush_JMX-data-as-joinbyfield",
        "CPU_Usage_per_Container_Histogram-data-as-joinbyfield",
        "CPU_Usage_per_Container-data-as-joinbyfield",
        "Datasource_Flush-data-as-joinbyfield",
        "Disk_Read-data-as-joinbyfield",
        "Disk_Usage-data-as-joinbyfield",
        "Disk_Write-data-as-joinbyfield",
        "Gas_Consumption-data-as-joinbyfield",
        "JVM_GC_Collection_Time-data-as-joinbyfield",
        "JVM_Heap_Memory_Usage-data-as-joinbyfield",
        "Memory_Usage_per_Container-data-as-joinbyfield",
        "Received_Network_Traffic_per_Container-data-as-joinbyfield",
        "Sent_Network_Traffic_per_Container-data-as-joinbyfield"
    ]

    readme = []
    for s_name, cfg in sorted(configs.items()):
        readme.append(f"{s_name}: \n* flush every {cfg['flush_blocks']} blocks" + ("\n* receives transactions from the test" if 'miner1' in s_name else "") + "\n")
        
        # 1. Standard Report (Fixed 1s X-axis)
        results_std = process_miner(s_name, export_dir, KEY_FILES_MAPPING)
        if results_std:
            img_path = reports_dir / f"{s_name}_performance_dashboard.png"
            rpt_path = reports_dir / f"{s_name}_performance_report.md"
            bt = results_std.get('Block Processing Time', {}).get('raw')
            cpu = results_std.get('CPU Usage per Container', {}).get('raw')
            create_performance_dashboard(f"Performance Analysis (Standard) - {s_name}", bt, cpu, results_std, img_path, x_limit=1.0)
            generate_miner_report(s_name, results_std, rpt_path, img_path, resource_limits=cfg)
            readme.append(f"[Go to detailed report for {s_name}](reports/{rpt_path.name})")

        # 2. Complete Report (Dynamic X-axis)
        results_comp = process_miner(s_name, export_dir, COMPLETE_FILES_MAPPING)
        if results_comp:
            img_path = complete_dir / f"{s_name}_performance_dashboard_complete.png"
            rpt_path = complete_dir / f"{s_name}_performance_report_complete.md"
            bt = results_comp.get('Block Processing Time', {}).get('raw')
            cpu = results_comp.get('CPU Usage per Container', {}).get('raw')
            create_performance_dashboard(f"Performance Analysis (Complete) - {s_name}", bt, cpu, results_comp, img_path, x_limit=None)
            generate_miner_report(s_name, results_comp, rpt_path, img_path, resource_limits=cfg)
            readme.append(f"[Go to complete report for {s_name}](reports_complete/{rpt_path.name})\n")

    readme.append("\nFiles to analyze:\n\n" + "\n".join(key_files))
    readme.append("\nFiles to analyze 2:\n\n" + "\n".join(complete_files))
    
    # Generate individual plots for all CSVs
    generate_individual_plots(export_dir)
    
    with open(export_dir / 'README.md', 'w') as f: f.write("\n".join(readme))
    print("✓ Generated README, standard reports (/reports), and complete reports (/reports_complete).")

if __name__ == '__main__': main()
