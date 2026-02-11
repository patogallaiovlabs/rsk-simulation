# Grafana Panel Data Exporter

Automated tool to export all panel data from a Grafana dashboard to CSV files, eliminating the need for manual panel-by-panel exports.

## Features

- **Automated Export**: Export all panels with a single command
- **Flexible Time Ranges**: Specify custom time ranges for data export
- **Variable Support**: Apply dashboard variables (e.g., select specific containers)
- **CSV Format**: Data exported in the same "joined by field" format as Grafana's UI export
- **Batch Processing**: Process dozens of panels in seconds

## Prerequisites

1. **Python 3.7+** installed
2. **Grafana API Key** with read permissions

### Creating a Grafana API Key

1. Log into your Grafana instance
2. Go to **Configuration** → **API Keys** (or **Service Accounts** in newer versions)
3. Click **Add API Key** / **Create service account token**
4. Name: `panel-exporter` (or any name you prefer)
5. Role: **Viewer** (read-only access is sufficient)
6. Click **Add** and copy the generated key

## Installation

1. Install required Python packages:

```bash
pip install requests
```

2. Create your configuration file:

```bash
cd grafana/exporter
cp config.example.json config.json
```

3. Edit `config.json` with your settings:

```json
{
  "grafana_url": "http://localhost:3000",
  "api_key": "YOUR_API_KEY_HERE",
  "dashboard_uid": "mydash",
  "output_dir": "../../results/grafana_exports",
  "variables": {
    "container": "rskj-miner2",
    "interval": "30s"
  }
}
```

**Configuration fields:**
- `grafana_url`: Your Grafana instance URL
- `api_key`: The API key you created
- `dashboard_uid`: Dashboard UID (found in dashboard URL: `/d/mydash/...`)
- `output_dir`: Where to save exported CSV files
- `variables`: Default dashboard variables to apply

## Usage

### Basic Export

Export all panels using the default time range (last 6 hours):

```bash
python export_panels.py
```

### Custom Time Range

Export data for a specific time range:

```bash
# Last 24 hours
python export_panels.py --from now-24h --to now

# Specific date range (ISO format)
python export_panels.py --from 2026-02-10T00:00:00Z --to 2026-02-11T00:00:00Z

# Last 4 hours
python export_panels.py --from now-4h --to now
```

### With Variables

Override dashboard variables:

```bash
# Export data for a specific container
python export_panels.py --var container=rskj-miner2

# Multiple variables
python export_panels.py --var container=rskj-miner2 --var interval=1m
```

### Complete Example

```bash
python export_panels.py \
  --from 2026-02-10T12:00:00Z \
  --to 2026-02-11T16:00:00Z \
  --var container=rskj-miner2 \
  --var interval=30s
```

## Output

The script will create CSV files in the specified output directory, with filenames matching Grafana's export format:

```
results/grafana_exports/
├── Block_Processing_Time-data-as-joinbyfield-2026-02-11 15_43_30.csv
├── CPU_Usage_per_Container-data-as-joinbyfield-2026-02-11 15_43_30.csv
├── Gas_Consumption-data-as-joinbyfield-2026-02-11 15_43_30.csv
├── JVM_Heap_Memory_Usage-data-as-joinbyfield-2026-02-11 15_43_30.csv
└── ...
```

Each CSV file contains:
- **Time** column (first column)
- **Series columns** (one per time series, labeled with metric labels)

## Troubleshooting

### "Error: Configuration file 'config.json' not found"

Create `config.json` from the example file:
```bash
cp config.example.json config.json
```

### "401 Unauthorized"

Your API key is invalid or expired. Create a new one in Grafana.

### "No data available" for all panels

Check:
1. Time range is correct (data exists in that period)
2. Dashboard variables are set correctly
3. Prometheus/data source is accessible from Grafana

### Library panels show "not yet supported"

Library panels require additional API calls. For now, these are skipped. You can export them individually from the Grafana UI.

## Advanced Usage

### Programmatic Use

You can also use the exporter as a Python module:

```python
from export_panels import GrafanaExporter

exporter = GrafanaExporter(
    grafana_url='http://localhost:3000',
    api_key='your-api-key',
    dashboard_uid='mydash',
    output_dir='./exports'
)

files = exporter.export_all_panels(
    time_from='now-6h',
    time_to='now',
    variables={'container': 'rskj-miner2'}
)

print(f"Exported {len(files)} files")
```

## Tips

1. **Automate with cron**: Schedule regular exports
   ```bash
   # Export every 6 hours
   0 */6 * * * cd /path/to/grafana/exporter && python export_panels.py --from now-6h --to now
   ```

2. **Export multiple scenarios**: Create different config files
   ```bash
   python export_panels.py --config config_7M.json
   python export_panels.py --config config_10M.json
   python export_panels.py --config config_17M.json
   ```

3. **Combine with analysis scripts**: Chain the exporter with your data processing pipeline
