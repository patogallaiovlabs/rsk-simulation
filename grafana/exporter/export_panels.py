#!/usr/bin/env python3
"""
Grafana Panel Data Exporter

This script automatically exports data from all panels in a Grafana dashboard to CSV files.
It uses the Grafana API to query panel data and saves each panel's data with proper formatting.
"""

import json
import csv
import os
import sys
import requests
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any, Optional
import argparse


class GrafanaExporter:
    def __init__(self, grafana_url: str, api_key: str, dashboard_uid: str, output_dir: str):
        """
        Initialize the Grafana exporter.
        
        Args:
            grafana_url: Base URL of Grafana instance (e.g., http://localhost:3000)
            api_key: Grafana API key with read permissions
            dashboard_uid: UID of the dashboard to export
            output_dir: Directory where CSV files will be saved
        """
        self.grafana_url = grafana_url.rstrip('/')
        self.api_key = api_key
        self.dashboard_uid = dashboard_uid
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        self.headers = {
            'Authorization': f'Bearer {api_key}',
            'Content-Type': 'application/json'
        }
    
    def get_dashboard(self) -> Dict[str, Any]:
        """Fetch the dashboard JSON from Grafana."""
        url = f'{self.grafana_url}/api/dashboards/uid/{self.dashboard_uid}'
        response = requests.get(url, headers=self.headers)
        response.raise_for_status()
        return response.json()['dashboard']
    
    def get_panel_data(self, panel: Dict[str, Any], time_from: str, time_to: str, 
                      variables: Optional[Dict[str, str]] = None) -> List[Dict[str, Any]]:
        """
        Query data for a specific panel.
        
        Args:
            panel: Panel configuration from dashboard JSON
            time_from: Start time (ISO format or relative like 'now-6h')
            time_to: End time (ISO format or relative like 'now')
            variables: Dashboard variables to apply (e.g., {'container': 'rskj-miner2'})
        
        Returns:
            List of query results
        """
        # Skip panels without targets (like row panels)
        if 'targets' not in panel or not panel['targets']:
            return []
        
        # Build query payload
        queries = []
        for target in panel['targets']:
            if target.get('hide', False):
                continue
            
            query = {
                'refId': target.get('refId', 'A'),
                'datasource': target.get('datasource', {}),
                'expr': target.get('expr', ''),
                'format': 'time_series',
                'instant': target.get('instant', False),
                'range': target.get('range', True),
                'intervalMs': 30000,
                'maxDataPoints': 1000
            }
            
            # Apply variable substitution
            if variables:
                for var_name, var_value in variables.items():
                    query['expr'] = query['expr'].replace(f'${var_name}', var_value)
                    query['expr'] = query['expr'].replace(f'${{var_name}}', var_value)
            
            queries.append(query)
        
        if not queries:
            return []
        
        # Query Grafana API
        url = f'{self.grafana_url}/api/ds/query'
        payload = {
            'queries': queries,
            'from': time_from,
            'to': time_to
        }
        
        try:
            response = requests.post(url, headers=self.headers, json=payload)
            response.raise_for_status()
            return response.json().get('results', {})
        except requests.exceptions.RequestException as e:
            print(f"Warning: Failed to query panel '{panel.get('title', 'Unknown')}': {e}")
            return []
    
    def save_panel_to_csv(self, panel_title: str, panel_id: int, data: List[Dict[str, Any]], 
                         timestamp: str) -> Optional[str]:
        """
        Save panel data to CSV file.
        
        Args:
            panel_title: Title of the panel
            panel_id: Panel ID
            data: Query results data
            timestamp: Timestamp string for filename
        
        Returns:
            Path to saved CSV file, or None if no data
        """
        if not data:
            return None
        
        # Sanitize filename
        safe_title = "".join(c if c.isalnum() or c in (' ', '-', '_') else '_' for c in panel_title)
        safe_title = safe_title.strip().replace(' ', '_')
        filename = f"{safe_title}-data-as-joinbyfield-{timestamp}.csv"
        filepath = self.output_dir / filename
        
        # Collect all time series data
        all_series = []
        for ref_id, result in data.items():
            if 'frames' in result:
                for frame in result['frames']:
                    if 'data' in frame and 'values' in frame['data']:
                        all_series.append({
                            'refId': ref_id,
                            'frame': frame
                        })
        
        if not all_series:
            return None
        
        # Build CSV with time as first column and series as subsequent columns
        time_series_map = {}
        headers = ['Time']
        
        for series in all_series:
            frame = series['frame']
            schema = frame.get('schema', {}).get('fields', [])
            values = frame['data']['values']
            
            # Find time and value fields
            time_idx = None
            value_idx = None
            series_name = None
            
            for idx, field in enumerate(schema):
                if field.get('type') == 'time':
                    time_idx = idx
                elif field.get('type') in ('number', 'float64'):
                    value_idx = idx
                    # Build series name from labels
                    labels = field.get('labels', {})
                    if labels:
                        series_name = ','.join(f'{k}="{v}"' for k, v in sorted(labels.items()))
                    else:
                        series_name = field.get('name', f'Value_{idx}')
            
            if time_idx is None or value_idx is None:
                continue
            
            # Add series to map
            if series_name and series_name not in headers:
                headers.append(series_name)
            
            times = values[time_idx]
            vals = values[value_idx]
            
            for t, v in zip(times, vals):
                if t not in time_series_map:
                    time_series_map[t] = {}
                time_series_map[t][series_name] = v
        
        # Write CSV
        with open(filepath, 'w', newline='') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow(headers)
            
            for timestamp in sorted(time_series_map.keys()):
                row = [datetime.fromtimestamp(timestamp / 1000).strftime('%Y-%m-%d %H:%M:%S')]
                for header in headers[1:]:
                    row.append(time_series_map[timestamp].get(header, ''))
                writer.writerow(row)
        
        return str(filepath)
    
    def export_all_panels(self, time_from: str = 'now-6h', time_to: str = 'now',
                         variables: Optional[Dict[str, str]] = None) -> List[str]:
        """
        Export all panels from the dashboard.
        
        Args:
            time_from: Start time for queries
            time_to: End time for queries
            variables: Dashboard variables to apply
        
        Returns:
            List of paths to exported CSV files
        """
        print(f"Fetching dashboard '{self.dashboard_uid}'...")
        dashboard = self.get_dashboard()
        
        panels = dashboard.get('panels', [])
        timestamp = datetime.now().strftime('%Y-%m-%d %H_%M_%S')
        exported_files = []
        
        print(f"Found {len(panels)} panels. Starting export...")
        
        for panel in panels:
            panel_type = panel.get('type', '')
            panel_title = panel.get('title', 'Untitled')
            panel_id = panel.get('id', 0)
            
            # Skip row panels and library panels
            if panel_type == 'row':
                print(f"  Skipping row: {panel_title}")
                continue
            
            if panel_type == 'library-panel-ref':
                print(f"  Skipping library panel: {panel_title} (not yet supported)")
                continue
            
            print(f"  Exporting: {panel_title} (ID: {panel_id}, Type: {panel_type})")
            
            # Get panel data
            data = self.get_panel_data(panel, time_from, time_to, variables)
            
            # Save to CSV
            filepath = self.save_panel_to_csv(panel_title, panel_id, data, timestamp)
            
            if filepath:
                exported_files.append(filepath)
                print(f"    ✓ Saved to: {filepath}")
            else:
                print(f"    ⚠ No data available")
        
        return exported_files


def main():
    parser = argparse.ArgumentParser(
        description='Export all panel data from a Grafana dashboard to CSV files'
    )
    parser.add_argument('--config', type=str, default='config.json',
                       help='Path to configuration file (default: config.json)')
    parser.add_argument('--from', dest='time_from', type=str, default='now-6h',
                       help='Start time (default: now-6h)')
    parser.add_argument('--to', dest='time_to', type=str, default='now',
                       help='End time (default: now)')
    parser.add_argument('--var', action='append', dest='variables',
                       help='Dashboard variable in format name=value (can be used multiple times)')
    
    args = parser.parse_args()
    
    # Load configuration
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"Error: Configuration file '{args.config}' not found.")
        print("Please create a config.json file. See config.example.json for reference.")
        sys.exit(1)
    
    with open(config_path) as f:
        config = json.load(f)
    
    # Parse variables
    variables = {}
    if args.variables:
        for var in args.variables:
            if '=' in var:
                name, value = var.split('=', 1)
                variables[name] = value
    
    # Merge with config variables
    if 'variables' in config:
        variables = {**config['variables'], **variables}
    
    # Create exporter
    exporter = GrafanaExporter(
        grafana_url=config['grafana_url'],
        api_key=config['api_key'],
        dashboard_uid=config['dashboard_uid'],
        output_dir=config.get('output_dir', './exports')
    )
    
    # Export all panels
    print(f"\n{'='*60}")
    print(f"Grafana Panel Data Exporter")
    print(f"{'='*60}")
    print(f"Time range: {args.time_from} to {args.time_to}")
    if variables:
        print(f"Variables: {variables}")
    print(f"Output directory: {exporter.output_dir}")
    print(f"{'='*60}\n")
    
    exported_files = exporter.export_all_panels(
        time_from=args.time_from,
        time_to=args.time_to,
        variables=variables
    )
    
    print(f"\n{'='*60}")
    print(f"Export complete!")
    print(f"Exported {len(exported_files)} panels")
    print(f"Files saved to: {exporter.output_dir}")
    print(f"{'='*60}\n")


if __name__ == '__main__':
    main()
