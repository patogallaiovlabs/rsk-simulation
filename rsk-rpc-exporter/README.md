# RSK RPC Exporter

A lightweight Prometheus exporter that scrapes mempool metrics from RSKj nodes via JSON-RPC.

## Features

- Scrapes `txpool_status` to get pending transaction counts.
- Fallback to `eth_getBlockTransactionCount` for compatibility.
- Exposes standard Prometheus gauges.
- Supports multi-node scraping.

## Metrics

| Metric Name | Type | Labels | Description |
| :--- | :--- | :--- | :--- |
| `rsk_txpool_pending_transactions` | Gauge | `node` | Number of pending transactions in the mempool. |

## Quick Start (with Docker)

Integration into `docker-compose.tools.yml`:

```yaml
  rsk-rpc-exporter:
    build:
      context: ./rsk-rpc-exporter
      dockerfile: Dockerfile
    container_name: rsk-rpc-exporter
    networks:
      - rsk-simulation-net
    environment:
      - RPC_URLS=http://rskj-miner1:4444,http://rskj-miner2:4444...
    ports:
      - "9092:9090"
```

## Configuration

| Environment Variable | Default | Description |
| :--- | :--- | :--- |
| `RPC_URLS` | `http://rskj-miner1:4444` | Comma-separated list of RSKj RPC endpoints. |
| `PORT` | `9090` | Internal port for the metrics server. |

## Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: "rsk-rpc-exporter"
    static_configs:
      - targets: ["rsk-rpc-exporter:9090"]
```
