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

## Step 3: Run the Export

For your specific dashboard with the exact time range from the URL:

```bash
python3 export_panels.py \
  --from 2026-02-10T21:18:00.998Z \
  --to 2026-02-11T18:29:12.769Z
```

This will export all panels with data from that exact time range.

### Alternative: Export with relative time

If you want to export the last 24 hours of data:

```bash
python3 export_panels.py --from now-24h --to now
```

## Output

CSV files will be saved to: `../../results/grafana_exports/`

Each file will be named like:
- `Block_Processing_Time-data-as-joinbyfield-2026-02-11 15_50_13.csv`
- `CPU_Usage_per_Container-data-as-joinbyfield-2026-02-11 15_50_13.csv`
- etc.

## Troubleshooting

### "No module named 'requests'"

Install dependencies:
```bash
pip3 install --break-system-packages requests
```

### "401 Unauthorized"

Your API key is incorrect. Double-check it in `config.json`.

### "Connection refused"

Make sure Grafana is running on `http://localhost:3002`
