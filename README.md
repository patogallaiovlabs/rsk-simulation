# RSK Consolidated Stack

This project provides a unified, modular Docker environment for running RSKj nodes, stats monitoring, and infrastructure visibility tools.

## Architecture

The environment is split into specialized Docker Compose files:

- **`docker-compose.yml`**: The main entry point that includes all other configurations.
- **`docker-compose.rskj.yml`**: Manages RSKj nodes (4 miners and 2 regular nodes).
- **`docker-compose.stats.yml`**: Manages the `stats-backend` and `stats-agent` for each node.
- **`docker-compose.tools.yml`**: Manages the monitoring stack (Prometheus, Grafana, Loki, etc.).

## Getting Started

### Prerequisites

- Docker and Docker Compose (ver 2.20+ recommended for `include` support)

### Start the Stack

```bash
docker compose up -d
```

This will build the necessary images (RSKj, Stats-Agent, Stats-Backend) and start all containers.

## Accessing Dashboards

- **Grafana**: [http://localhost:3002](http://localhost:3002)
  - Pre-configured with dashboards for Docker and system monitoring.
- **Stats Backend**: [http://localhost:3001](http://localhost:3001)
  - Real-time visualization of the RSK network status.

## Interacting with RSKj Nodes

Each node exposes RPC (HTTP/WS) and JMX ports on the host.

### Miner 1 (Default)
- **HTTP RPC**: `http://localhost:4444`
- **WS RPC**: `ws://localhost:4445`
- **JMX**: `localhost:9101`

### Other Miners & Nodes
Ports follow a stable scheme:
- **Miner 2**: HTTP 4446, WS 4447, JMX 9102
- **Miner 3**: HTTP 4448, WS 4449, JMX 9103
- **Miner 4**: HTTP 4450, WS 4451, JMX 9104
- **Node 1**: HTTP 4464, WS 4475, JMX 9201
- **Node 2**: HTTP 4465, WS 4476, JMX 9202

## Monitoring & Logs

- **Prometheus**: Scrapes metrics from `cadvisor`, `node-exporter`, and custom metrics parsed from logs.
- **Loki & Promtail**: Collects logs from all containers. Promtail is configured to extract block metrics from RSKj logs.
- **cAdvisor**: Provides container resource usage metrics.
