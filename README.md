# RSK Consolidated Stack

This project provides a unified, modular Docker environment for running RSKj nodes, stats monitoring, and infrastructure visibility tools.

## Architecture

The environment is split into specialized Docker Compose projects to allow for visual grouping in your Docker UI:

- **`docker-compose.tools.yml`**: (`rsk-tools`) Monitoring stack (Prometheus, Grafana, Loki, etc.).
- **`docker-compose.rskj.yml`**: (`rsk-nodes`) RSKj nodes (4 miners and 2 regular nodes).
- **`docker-compose.stats.yml`**: (`rsk-stats`) Network stats dashboard and agents.

### Start the Stack

You have two ways to manage the stack:

#### Option 1: Unified Management (Convenience)
Groups everything under a single project in Docker.
```bash
docker network create rsk-simulation-net # Only needed once
docker compose up -d
```

#### Option 2: Grouped Management (Visual Organization)
Maintains visual separation in Docker UI (Recommended for monitoring).
```bash
docker network create rsk-simulation-net # Only needed once
docker compose -f docker-compose.tools.yml up -d
docker compose -f docker-compose.rskj.yml up -d
docker compose -f docker-compose.stats.yml up -d
```

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

## Grafana Dashboard

- **Grafana**: [http://localhost:3002](http://localhost:3002)
- **Dashboard**: [grafana-dashboard.json](grafana-dashboard.json)
- **Data Source**: [prometheus](http://host.docker.internal:9091)
- **Data Source**: [loki](http://host.docker.internal:3100)