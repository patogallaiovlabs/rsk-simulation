import pandas as pd
import matplotlib.pyplot as plt
import os
import re
import argparse
import yaml

def summarize_rocksdb_compression(sys_props):
    """Build a human-readable RocksDB compression summary from RSKJ_SYS_PROPS.

    Recognizes per-DB overrides (-Ddatabase.rocksdb.compressionType.<db>=<type>)
    and the default override (-Ddatabase.rocksdb.compressionType.default=<type>).
    """
    if not sys_props or sys_props == 'N/A':
        return "none"

    matches = re.findall(r'-Ddatabase\.rocksdb\.compressionType\.([\w-]+)=(\S+)', sys_props)
    if not matches:
        return "none"

    default_type = None
    per_db = []
    for db, ctype in matches:
        if db == 'default':
            default_type = ctype
        else:
            per_db.append((db, ctype))

    parts = []
    if default_type:
        parts.append(f"all DBs → `{default_type}` (default)")
    if per_db:
        parts.append(", ".join(f"`{db}` → `{ctype}`" for db, ctype in per_db))
    return "; ".join(parts) if parts else "none"


def generate_readme(output_dir, docker_compose_path):
    if not os.path.exists(docker_compose_path):
        print(f"Warning: {docker_compose_path} not found. Skipping README generation.")
        return

    try:
        with open(docker_compose_path, 'r') as f:
            compose_data = yaml.safe_load(f)
    except Exception as e:
        print(f"Error parsing {docker_compose_path}: {e}")
        return

    services = compose_data.get('services', {})
    if not services:
        print(f"Warning: No services found in {docker_compose_path}")
        return

    markdown = "# RSKj Simulation Results Summary\n\n"
    markdown += f"Generated on: {pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
    markdown += "This directory contains Native Memory Tracking (NMT) plots and a summary of the node configurations used during the simulation.\n\n"
    
    markdown += "## 📈 Visualizations\n\n"
    markdown += "- [Total Memory Usage](nmt_total_memory.png)\n"
    markdown += "- [Memory Breakdown (per Node)](nmt_breakdown.png)\n\n"

    markdown += "## 🔧 Node Configurations (from Docker Compose)\n\n"
    markdown += "RocksDB columns are derived from `SHARED_BLOCK_CACHE_SIZE` and the "
    markdown += "`-Ddatabase.rocksdb.compressionType.*` system properties in `RSKJ_SYS_PROPS`.\n\n"
    markdown += "| Node | Role | CPU Limit | Memory Limit | JVM Options | Flush Blocks | Jemalloc | Shared Block Cache | DB Compression |\n"
    markdown += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"

    for name, config in services.items():
        env_list = config.get('environment', [])
        # Convert list of 'KEY=VAL' to dict
        env_dict = {}
        for item in env_list:
            if isinstance(item, str) and '=' in item:
                k, v = item.split('=', 1)
                env_dict[k] = v
        
        is_miner = env_dict.get('IS_MINER', 'false').lower() == 'true'
        role = "⛏️ Miner" if is_miner else "🔗 Node"
        
        deploy = config.get('deploy', {})
        resources = deploy.get('resources', {})
        limits = resources.get('limits', {})
        cpus = limits.get('cpus', 'N/A')
        memory = limits.get('memory', 'N/A')
        
        jvm_opts = env_dict.get('DEFAULT_JVM_OPTS', 'N/A')
        flush_blocks = re.sub(r'\$\{FLUSH_BLOCKS:-(\d+)\}', r'\1', env_dict.get('FLUSH_BLOCKS', 'default'))
        # ENABLE_JEMALLOC defaults to "true" in the Dockerfile when unset.
        jemalloc = 'enabled' if env_dict.get('ENABLE_JEMALLOC', 'true').lower() == 'true' else 'disabled'
        block_cache = env_dict.get('SHARED_BLOCK_CACHE_SIZE', 'not set')
        compression = summarize_rocksdb_compression(env_dict.get('RSKJ_SYS_PROPS', ''))
        
        markdown += f"| **{name}** | {role} | {cpus} | {memory} | `{jvm_opts}` | {flush_blocks} | {jemalloc} | {block_cache} | {compression} |\n"

    readme_path = os.path.join(output_dir, 'README.md')
    with open(readme_path, 'w') as f:
        f.write(markdown)
    print(f"Saved {readme_path}")

def main():
    parser = argparse.ArgumentParser(description='Plot RSKj Native Memory Tracking (NMT) metrics.')
    parser.add_argument('--csv', default='results/nmt/nmt_history.csv', help='Path to the NMT history CSV file.')
    parser.add_argument('--output', '-o', default='results/nmt/plots', help='Folder where to put the results (default: current directory).')
    parser.add_argument('--compose', default='../docker-compose.rskj.yml', help='Path to the docker-compose file for summary.')
    args = parser.parse_args()

    csv_path = args.csv
    output_dir = args.output
    docker_compose_path = args.compose

    if not os.path.exists(csv_path):
        print(f"Error: {csv_path} not found.")
        return

    # Create output directory if it doesn't exist
    if output_dir != '.' and not os.path.exists(output_dir):
        os.makedirs(output_dir)
        print(f"Created output directory: {output_dir}")

    # Generate README.md summary
    generate_readme(output_dir, docker_compose_path)

    df = pd.read_csv(csv_path)
    df['timestamp'] = pd.to_datetime(df['timestamp'])
    
    # Sort by timestamp
    df = df.sort_values('timestamp')

    # Get unique containers (sorted alphabetically for stable plot order)
    containers = sorted(df['container'].unique())

    # Determine columns for plotting
    if 'cgroup_total_mb' in df.columns:
        col_total = 'cgroup_total_mb'
    elif 'rss_mb' in df.columns:
        col_total = 'rss_mb'
    else:
        col_total = 'nmt_total_mb'

    # Define potential categories for stacking (order: heap first, then NMT native, then non-JVM)
    potential_categories = [
        'heap_mb', 'heap_comm_mb', 
        'gc_mb', 'threads_mb', 'metaspace_mb', 'code_mb', 'internal_mb',
        'nmt_other_mb', 
        'non_jvm_mb', 'cache_mb'
    ]
    categories = [c for c in potential_categories if c in df.columns]

    # 1. Plot Total Memory for all containers
    plt.figure(figsize=(12, 6))
    for container in containers:
        container_df = df[df['container'] == container]
        plt.plot(container_df['timestamp'], container_df[col_total], label=f"{container} ({col_total})")

    plt.title(f'Memory Usage Over Time ({col_total.upper()})')
    plt.xlabel('Time')
    plt.ylabel('Memory (MB)')
    plt.legend()
    plt.grid(True, linestyle='--', alpha=0.6)
    plt.xticks(rotation=45)
    plt.tight_layout()
    
    total_mem_path = os.path.join(output_dir, 'nmt_total_memory.png')
    plt.savefig(total_mem_path)
    print(f"Saved {total_mem_path} (using {col_total})")

    # 2. Detailed breakdown for each container (Subplots)
    num_containers = len(containers)
    if num_containers == 0:
        print("No data found in CSV for plotting.")
        return
        
    fig, axes = plt.subplots(num_containers, 1, figsize=(15, 6 * num_containers), sharex=True)
    
    if num_containers == 1:
        axes = [axes]

    for i, container in enumerate(containers):
        container_df = df[df['container'] == container].copy()
        current_cats = [c for c in categories if c in df.columns]
        # Breakdown requires JVM NMT columns; docker-stats-only rows have NaN heap.
        if 'heap_comm_mb' in container_df.columns:
            breakdown_df = container_df[container_df['heap_comm_mb'].notna()]
        else:
            breakdown_df = container_df

        ax = axes[i]

        if breakdown_df.empty or not current_cats:
            ax.text(
                0.5, 0.5, 'No NMT breakdown available',
                transform=ax.transAxes, ha='center', va='center',
            )
        else:
            plot_data = breakdown_df[current_cats].fillna(0)
            ax.stackplot(
                breakdown_df['timestamp'],
                plot_data.T,
                labels=current_cats,
                alpha=0.8,
            )
        
        if 'db_disk_mb' in container_df.columns:
            ax2 = ax.twinx()
            ax2.plot(container_df['timestamp'], container_df['db_disk_mb'], color='black', linestyle='--', linewidth=1.5, label='DB Disk (MB)')
            ax2.set_ylabel('Disk (MB)')
            ax2.legend(loc='upper right')

        ax.set_title(f'Memory Breakdown: {container}')
        ax.set_ylabel('Memory (MB)')
        ax.legend(loc='upper left')
        ax.grid(True, linestyle=':', alpha=0.5)

    plt.xlabel('Time')
    plt.xticks(rotation=45)
    plt.tight_layout()
    
    breakdown_path = os.path.join(output_dir, 'nmt_breakdown.png')
    plt.savefig(breakdown_path)
    print(f"Saved {breakdown_path}")

if __name__ == "__main__":
    main()
