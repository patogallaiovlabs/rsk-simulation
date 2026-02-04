# RSK Simulation Environment

This project aims to simulate a local network of RSK miners and nodes running in Docker containers. It provides a modular environment to run stress tests, monitor network performance, and analyze hardware resource usage.

The simulation includes:
- A network of RSKj nodes (Miners and Regular Nodes).
- A suite of monitoring tools (Grafana, Prometheus, Loki).
- A network statistics dashboard (Stats Backend and Agent).
- Integration with a [k6 test suite](https://github.com/rsksmart/rskj-k6-tests) for stress testing the network.

## Architecture

The project follows a modular architecture, allowing you to run different components independently:

- **RSK Network (`docker-compose.rskj.yml`)**: The core of the simulation, consisting of 4 miners and 2 regular nodes.
- **Monitoring Stack (`docker-compose.tools.yml`)**: Infrastructure visibility using Prometheus (metrics), Loki (logs), and Grafana (dashboards). It provides metrics for both hardware usage and node performance (e.g., block processing time).
- **Stats Dashboard (`docker-compose.stats.yml`)**: Real-time network status visualization using the RSK Stats dashboard and agents.

## Setup

### 1. Initialize Submodules
This project uses Git submodules for RSKj and the k6 test suite.
```bash
git submodule update --init --recursive
```

### 2. Stats Dashboard Setup
If you plan to run the stats dashboard, initialize the dependencies for the backend and agent:
```bash
# Stats Backend
cd repos/stats-backend && npm install && cd ../..

# Stats Agent
cd repos/stats-agent && npm install && cd ../..
```

### 3. K6 Stress Tests Setup
To run the stress tests, ensure you have [k6](https://k6.io/docs/getting-started/installation/) installed on your system, then install the project dependencies:
```bash
cd repos/rskj-k6-tests && npm install && cd ../..
```

## Getting Started

First, ensure the shared network exists:
```bash
docker network create rsk-simulation-net 2>/dev/null || true
```

### Start the RSK Network
```bash
docker compose -f docker-compose.rskj.yml up -d
```

### Start Optional Tools (Recommended)
```bash
# Monitoring Stack (Grafana at http://localhost:3002)
docker compose -f docker-compose.tools.yml up -d

# Stats Dashboard (Backend at http://localhost:3001)
docker compose -f docker-compose.stats.yml up -d
```

## Stress Testing

You can run various stress test scenarios using the k6 suite located in `repos/rskj-k6-tests`.

### Example: Running Keccak Random Writes
```bash
cd repos/rskj-k6-tests
npm run test:regtest:keccak-random-writes
```

## Performance Monitoring

- **Grafana**: Access [http://localhost:3002](http://localhost:3002) to view dashboards.
- **Node Metrics**: Includes block processing time, gas consumption, and difficulty.
- **Hardware Metrics**: CPU, memory, Disk I/O, and network traffic per container.

## Interacting with Nodes

Each node exposes RPC ports on the host:
- **Miner 1**: HTTP 4444, WS 4445
- **Miner 2**: HTTP 4446, WS 4447
- **Miner 3**: HTTP 4448, WS 4449
- **Miner 4**: HTTP 4450, WS 4451
- **Node 1**: HTTP 4464, WS 4475
- **Node 2**: HTTP 4465, WS 4476

## Troubleshooting

### Docker Image Pull Issues (GCloud auth)
If `docker compose` fails to pull images because it tries to use `gcloud` as a credential helper, you may need to reset your Docker configuration.
The project includes a clean `config.json` in the `./docker/` directory.
```bash
cp ./docker/config.json ~/.docker/config.json
```

### Port Conflicts
If you get "bind: address already in use" errors, ensure no other services are running on the following ports:
- **3000-3002**: Grafana, Stats Backend.
- **9090-9091**: Prometheus.
- **3100**: Loki.
- **4444-4451**: RSKj RPC ports.

### Containers Cannot Communicate
Ensure the shared network exists:
```bash
docker network ls | grep rsk-simulation-net
```
If not found, create it: `docker network create rsk-simulation-net`.

### Logs Not Showing in Grafana
If logs are missing in Grafana/Loki, check the Promtail container logs. This is often due to Docker API version mismatches or Loki rate limiting.
```bash
docker compose -f docker-compose.tools.yml logs -f promtail
```