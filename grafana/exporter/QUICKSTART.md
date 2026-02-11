# Quick Start Guide

## Step 1: Add Your API Key

Edit `config.json` and replace `PASTE_YOUR_API_KEY_HERE` with your actual Grafana API token.

## Step 2: Install Dependencies (if needed)

The setup script had an issue with system Python. Install dependencies with:

```bash
# Option 1: Use --break-system-packages (quick but not recommended)
pip3 install --break-system-packages -r requirements.txt

# Option 2: Use virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Step 3: Run Full Export & Analysis

To export all panels and generate quantitative reports in one command:

```bash
python3 export_panels.py --from now-4h --to now
```

## Output Structure

Results are saved to `../../results/grafana_exports/`:

- **`README.md`**: Start here! It contains links to all reports.
- **`reports/`**: Standard reports with key metrics and standardized plots.
- **`reports_complete/`**: Complete reports with all metrics and dynamic plots.
- **`*.csv`**: Raw data files for your own custom analysis.

## Troubleshooting

### "Connection refused"
Make sure Grafana is running on `http://localhost:3002`

### "No data available"
Ensure your time range (`--from`) covers a period where the simulation was actually running.
