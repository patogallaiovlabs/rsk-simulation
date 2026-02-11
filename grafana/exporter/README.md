# Grafana Panel Data Exporter

Automated tool to export all panel data from a Grafana dashboard to CSV files, eliminating the need for manual panel-by-panel exports.

## Features

- **Automated Export**: Export all panels with a single command
- **Flexible Time Ranges**: Specify custom time ranges for data export
- **Variable Support**: Apply dashboard variables (e.g., select specific containers)
- **CSV Format**: Data exported in the same "joined by field" format as Grafana's UI export
- **Automated Analysis**: Automatically generates quantitative reports and dashboards after export.
- **Dual Report Modes**: Generates "Standard" (key metrics) and "Complete" (unfiltered) report versions.

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

### Basic Export & Analysis

Export all panels and generate reports using the default time range (last 6 hours):

```bash
python3 export_panels.py
```

### Custom Time Range

Export data and generate analysis for a specific time range:

```bash
# ISO format or relative
python3 export_panels.py --from 2026-02-10T00:00:00Z --to 2026-02-11T00:00:00Z
python3 export_panels.py --from now-4h --to now
```

### With Variables

Override dashboard variables:

```bash
# Export data for a specific container
python export_panels.py --var container=rskj-miner2

# Multiple variables
python export_panels.py --var container=rskj-miner2 --var interval=1m
```

### Specific Example (Used in Simulation)

```bash
python3 export_panels.py \
  --from 2026-02-10T21:18:00.998Z \
  --to 2026-02-11T18:29:12.769Z
```

## Output Structure

The tool organizes results into the following structure:

```
results/grafana_exports/
├── README.md                           # Master index with links to all reports
├── [Metric]-data-[Timestamp].csv      # Raw CSV data files
├── reports/                            # Standard reports (Key metrics, fixed 0-1s plots)
│   ├── [node]_performance_report.md
│   └── [node]_performance_dashboard.png
└── reports_complete/                   # Complete reports (All metrics, dynamic plots)
    ├── [node]_performance_report_complete.md
    └── [node]_performance_dashboard_complete.png
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

```python
from export_panels import GrafanaExporter

exporter = GrafanaExporter(
    grafana_url='http://localhost:3002',
    api_key='your-api-key',
    dashboard_uid='mydash',
    output_dir='./exports'
)

# This will only export the CSVs
files = exporter.export_all_panels(
    time_from='now-6h',
    time_to='now'
)
```

## Tips

1. **Automate with cron**: Schedule regular exports
   ```bash
   # Export every 6 hours
   0 */6 * * * cd /path/to/grafana/exporter && python3 export_panels.py --from now-6h --to now
   ```

2. **Combine with analysis**: The script automatically calls `generate_readme.py` to create your reports!
