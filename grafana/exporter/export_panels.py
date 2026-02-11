#!/usr/bin/env python3
"""
Grafana Panel Data Exporter - Direct Prometheus Query

This version queries Prometheus directly instead of using Grafana's query API.
Works with all Grafana versions.
"""

import json
import csv
import sys
import requests
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any, Optional
import argparse
import re


class GrafanaExporter:
    def __init__(self, grafana_url: str, api_key: str, dashboard_uid: str, 
                 prometheus_url: str, output_dir: str):
        self.grafana_url = grafana_url.rstrip('/')
        self.api_key = api_key
        self.dashboard_uid = dashboard_uid
        self.prometheus_url = prometheus_url.rstrip('/')
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
    
    def get_library_panel(self, uid: str) -> Optional[Dict[str, Any]]:
        """Fetch a library panel definition from Grafana."""
        url = f'{self.grafana_url}/api/library-elements/{uid}'
        try:
            response = requests.get(url, headers=self.headers)
            response.raise_for_status()
            result = response.json()
            return result.get('result', {}).get('model', {})
        except Exception as e:
            print(f"    Warning: Failed to fetch library panel {uid}: {e}")
            return None
    
    def query_prometheus(self, query: str, start: str, end: str, step: str = '30s') -> List[Dict]:
        """Query Prometheus directly for range data."""
        url = f'{self.prometheus_url}/api/v1/query_range'
        params = {
            'query': query,
            'start': start,
            'end': end,
            'step': step
        }
        
        try:
            response = requests.get(url, params=params)
            response.raise_for_status()
            result = response.json()
            
            if result.get('status') == 'success':
                return result.get('data', {}).get('result', [])
            return []
        except Exception as e:
            print(f"    Warning: Prometheus query failed: {e}")
            return []
    
    def apply_variables(self, expr: str, variables: Dict[str, str], step: str = '30s') -> str:
        """Apply dashboard variables to a Prometheus expression."""
        # First, handle Grafana built-in variables
        # $__rate_interval is typically 4x the scrape interval
        # $__interval is the step/resolution
        expr = expr.replace('$__rate_interval', '2m')  # 4x 30s scrape interval
        expr = expr.replace('$__interval', step)
        expr = expr.replace('${__rate_interval}', '2m')
        expr = expr.replace('${__interval}', step)
        
        if not variables:
            return expr
        
        for var_name, var_value in variables.items():
            # Handle both $var and ${var} syntax
            expr = expr.replace(f'${var_name}', var_value)
            expr = expr.replace(f'${{{var_name}}}', var_value)
            # Handle regex patterns like =~"$var"
            expr = re.sub(rf'=~"\\${var_name}"', f'=~"{var_value}"', expr)
            expr = re.sub(rf'=~"\\${{{var_name}}}"', f'=~"{var_value}"', expr)
        
        return expr
    
    def get_panel_data(self, panel: Dict[str, Any], time_from: str, time_to: str,
                      variables: Optional[Dict[str, str]] = None, step: str = '30s') -> Dict[str, List]:
        """Query data for a panel from Prometheus."""
        if 'targets' not in panel or not panel['targets']:
            return {}
        
        all_series = {}
        
        for target in panel['targets']:
            if target.get('hide', False):
                continue
            
            expr = target.get('expr', '')
            if not expr:
                continue
            
            # Apply variables
            expr = self.apply_variables(expr, variables or {}, step)
            
            ref_id = target.get('refId', 'A')
            
            # Query Prometheus
            results = self.query_prometheus(expr, time_from, time_to, step)
            
            if results:
                all_series[ref_id] = results
        
        return all_series
    
    def save_panel_to_csv(self, panel_title: str, data: Dict[str, List], 
                         timestamp: str) -> Optional[str]:
        """Save panel data to CSV."""
        if not data:
            return None
        
        # Sanitize filename
        safe_title = "".join(c if c.isalnum() or c in (' ', '-', '_') else '_' for c in panel_title)
        safe_title = safe_title.strip().replace(' ', '_')
        filename = f"{safe_title}-data-as-joinbyfield-{timestamp}.csv"
        data_dir = self.output_dir / 'data'
        data_dir.mkdir(parents=True, exist_ok=True)
        filepath = data_dir / filename
        
        # Collect all time series
        time_series_map = {}
        headers = ['Time']
        
        for ref_id, series_list in data.items():
            for series in series_list:
                metric = series.get('metric', {})
                values = series.get('values', [])
                
                # Build series name from metric labels
                if metric:
                    series_name = ','.join(f'{k}="{v}"' for k, v in sorted(metric.items()))
                else:
                    series_name = f'Series_{ref_id}'
                
                if series_name not in headers:
                    headers.append(series_name)
                
                # Add values to map
                for timestamp_val, value in values:
                    if timestamp_val not in time_series_map:
                        time_series_map[timestamp_val] = {}
                    time_series_map[timestamp_val][series_name] = value
        
        if not time_series_map:
            return None
        
        # Write CSV
        with open(filepath, 'w', newline='') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow(headers)
            
            for ts in sorted(time_series_map.keys()):
                row = [datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S')]
                for header in headers[1:]:
                    row.append(time_series_map[ts].get(header, ''))
                writer.writerow(row)
        
        return str(filepath)
    
    def convert_time_to_timestamp(self, time_str: str) -> str:
        """Convert time string to Unix timestamp."""
        # If already a timestamp or ISO format, return as is
        if time_str.replace('.', '').replace('-', '').replace(':', '').replace('T', '').replace('Z', '').isdigit():
            # Parse ISO format
            try:
                dt = datetime.fromisoformat(time_str.replace('Z', '+00:00'))
                return str(int(dt.timestamp()))
            except:
                return time_str
        
        # Handle relative times like 'now-6h'
        if 'now' in time_str:
            from datetime import timedelta
            now = datetime.now()
            
            if time_str == 'now':
                return str(int(now.timestamp()))
            
            # Parse relative time
            match = re.match(r'now-(\d+)([smhd])', time_str)
            if match:
                value = int(match.group(1))
                unit = match.group(2)
                
                if unit == 's':
                    delta = timedelta(seconds=value)
                elif unit == 'm':
                    delta = timedelta(minutes=value)
                elif unit == 'h':
                    delta = timedelta(hours=value)
                elif unit == 'd':
                    delta = timedelta(days=value)
                else:
                    return str(int(now.timestamp()))
                
                return str(int((now - delta).timestamp()))
        
        return time_str
    
    def export_all_panels(self, time_from: str = 'now-6h', time_to: str = 'now',
                         variables: Optional[Dict[str, str]] = None) -> List[str]:
        """Export all panels from the dashboard."""
        print(f"Fetching dashboard '{self.dashboard_uid}'...")
        dashboard = self.get_dashboard()
        
        panels = dashboard.get('panels', [])
        timestamp = datetime.now().strftime('%Y-%m-%d %H_%M_%S')
        exported_files = []
        
        # Convert times to timestamps
        start_ts = self.convert_time_to_timestamp(time_from)
        end_ts = self.convert_time_to_timestamp(time_to)
        
        print(f"Found {len(panels)} panels. Starting export...")
        print(f"Time range: {time_from} ({start_ts}) to {time_to} ({end_ts})")
        
        for panel in panels:
            panel_type = panel.get('type', '')
            panel_title = panel.get('title', 'Untitled')
            panel_id = panel.get('id', 0)
            
            # Skip row panels
            if panel_type == 'row':
                print(f"  Skipping row: {panel_title}")
                continue
            
            # Handle library panels - fetch the actual panel definition
            if panel_type == 'library-panel-ref':
                library_panel_uid = panel.get('libraryPanel', {}).get('uid')
                if library_panel_uid:
                    print(f"  Fetching library panel: {panel_title}")
                    library_panel_def = self.get_library_panel(library_panel_uid)
                    if library_panel_def:
                        # Use the library panel definition instead
                        panel = library_panel_def
                        panel_type = panel.get('type', '')
                        # Keep the title from the reference
                    else:
                        print(f"    ⚠ Failed to fetch library panel")
                        continue
                else:
                    print(f"  Skipping library panel: {panel_title} (no UID)")
                    continue
            
            print(f"  Exporting: {panel_title} (ID: {panel_id})")
            
            # Get panel data
            data = self.get_panel_data(panel, start_ts, end_ts, variables)
            
            # Save to CSV
            filepath = self.save_panel_to_csv(panel_title, data, timestamp)
            
            if filepath:
                exported_files.append(filepath)
                print(f"    ✓ Saved to: {filepath}")
            else:
                print(f"    ⚠ No data")
        
        return exported_files


def main():
    parser = argparse.ArgumentParser(
        description='Export panel data from Grafana dashboard (V2 - Direct Prometheus)'
    )
    parser.add_argument('--config', type=str, default='config.json')
    parser.add_argument('--from', dest='time_from', type=str, default='now-6h')
    parser.add_argument('--to', dest='time_to', type=str, default='now')
    parser.add_argument('--var', action='append', dest='variables')
    
    args = parser.parse_args()
    
    # Load configuration
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"Error: Configuration file '{args.config}' not found.")
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
    
    if 'variables' in config:
        variables = {**config['variables'], **variables}
    
    # Get Prometheus URL
    prometheus_url = config.get('prometheus_url', 'http://localhost:9090')
    
    # Create exporter
    exporter = GrafanaExporter(
        grafana_url=config['grafana_url'],
        api_key=config['api_key'],
        dashboard_uid=config['dashboard_uid'],
        prometheus_url=prometheus_url,
        output_dir=config.get('output_dir', './exports')
    )
    
    print(f"\n{'='*60}")
    print(f"Grafana Panel Data Exporter")
    print(f"{'='*60}")
    print(f"Grafana: {config['grafana_url']}")
    print(f"Prometheus: {prometheus_url}")
    if variables:
        print(f"Variables: {variables}")
    print(f"Output: {exporter.output_dir}")
    print(f"{'='*60}\n")
    
    exported_files = exporter.export_all_panels(
        time_from=args.time_from,
        time_to=args.time_to,
        variables=variables
    )
    
    print(f"\n{'='*60}")
    print(f"Export complete! Exported {len(exported_files)} panels")
    print(f"{'='*60}\n")
    
    # Generate README and analysis
    if exported_files:
        print("Generating README and analysis...")
        import subprocess
        
        # Find docker-compose file
        compose_file = Path(__file__).parent.parent.parent / 'docker-compose.rskj.yml'
        
        if compose_file.exists():
            try:
                result = subprocess.run(
                    ['python3', 'generate_readme.py', str(exporter.output_dir), 
                     str(compose_file)] + exported_files,
                    cwd=Path(__file__).parent,
                    capture_output=True,
                    text=True
                )
                
                if result.returncode == 0:
                    print(result.stdout)
                else:
                    print(f"Warning: README generation failed: {result.stderr}")
            except Exception as e:
                print(f"Warning: Could not generate README: {e}")
        else:
            print(f"Warning: docker-compose.yml not found at {compose_file}")


if __name__ == '__main__':
    main()
