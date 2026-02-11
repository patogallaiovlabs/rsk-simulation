#!/bin/bash
# Quick setup script for Grafana Panel Data Exporter

echo "=========================================="
echo "Grafana Panel Data Exporter - Setup"
echo "=========================================="
echo ""

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is not installed. Please install Python 3.7 or higher."
    exit 1
fi

echo "✓ Python 3 found: $(python3 --version)"

# Install dependencies
echo ""
echo "Installing dependencies..."
pip3 install -r requirements.txt

# Check if config exists
if [ ! -f "config.json" ]; then
    echo ""
    echo "⚠️  config.json not found. Creating from example..."
    cp config.example.json config.json
    echo "✓ Created config.json"
    echo ""
    echo "📝 IMPORTANT: Edit config.json and add your Grafana API key!"
    echo ""
    echo "To create an API key:"
    echo "  1. Log into Grafana"
    echo "  2. Go to Configuration → API Keys"
    echo "  3. Click 'Add API Key'"
    echo "  4. Name: 'panel-exporter', Role: 'Viewer'"
    echo "  5. Copy the key and paste it in config.json"
    echo ""
else
    echo "✓ config.json already exists"
fi

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Edit config.json with your Grafana API key"
echo "  2. Run: python3 export_panels.py"
echo ""
echo "For more options, see README.md or run:"
echo "  python3 export_panels.py --help"
echo ""
