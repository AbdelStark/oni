# oni Node Deployment Guide

This guide covers deploying oni in production environments.

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Quick Start](#quick-start)
3. [Docker Deployment](#docker-deployment)
4. [Native Deployment](#native-deployment)
5. [Configuration](#configuration)
6. [Security](#security)
7. [Monitoring](#monitoring)
8. [Maintenance](#maintenance)
9. [Troubleshooting](#troubleshooting)

## System Requirements

### Minimum Requirements (Pruned Node)

- **CPU**: 2 cores
- **RAM**: 4 GB
- **Storage**: 50 GB SSD
- **Network**: 10 Mbps

### Recommended Requirements (Full Node)

- **CPU**: 4+ cores
- **RAM**: 8+ GB
- **Storage**: 1 TB SSD (NVMe recommended)
- **Network**: 100+ Mbps

### Software Requirements

- Docker 20.10+ (for containerized deployment)
- OR Erlang/OTP 26+ and Gleam 1.4+ (for native deployment)

## Quick Start

### Using Docker (Recommended)

```bash
# Clone the repository
git clone https://github.com/AbdelStark/oni.git
cd oni

# Create environment file
cat > .env << EOF
ONI_NETWORK=mainnet
ONI_RPC_USER=your_username
ONI_RPC_PASSWORD=$(openssl rand -base64 32)
EOF

# Start the node
docker-compose up -d

# Check status
docker-compose logs -f oni
```

### Using Docker Hub (Coming Soon)

```bash
docker run -d \
  --name oni-node \
  -p 8333:8333 \
  -p 127.0.0.1:8332:8332 \
  -v oni-data:/data \
  -e ONI_RPC_USER=user \
  -e ONI_RPC_PASSWORD=password \
  oni/oni:latest
```

## Docker Deployment

### Building the Image

```bash
# Build with default settings
docker build -t oni .

# Build with specific Gleam version
docker build --build-arg GLEAM_VERSION=1.4.1 -t oni .
```

### Running with Docker Compose

#### Development Mode

```bash
docker-compose up
```

#### Production Mode

```bash
# Create production overrides
cat > docker-compose.prod.yml << EOF
version: "3.8"
services:
  oni:
    environment:
      - ONI_LOG_LEVEL=info
    deploy:
      resources:
        limits:
          cpus: "8"
          memory: 16G
EOF

# Start with production config
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### Data Persistence

Data is stored in a Docker volume by default:

```bash
# List volumes
docker volume ls

# Inspect data volume
docker volume inspect oni-data

# Backup data
docker run --rm -v oni-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/oni-backup-$(date +%Y%m%d).tar.gz /data
```

## Native Deployment

### Prerequisites

```bash
# Install Erlang/OTP (Ubuntu/Debian)
sudo apt-get install erlang

# Install Gleam
curl -L https://github.com/gleam-lang/gleam/releases/download/v1.4.1/gleam-v1.4.1-x86_64-unknown-linux-musl.tar.gz \
  | sudo tar xzf - -C /usr/local/bin
```

### Building

```bash
# Clone and build
git clone https://github.com/AbdelStark/oni.git
cd oni
make build

# Create release
gleam export erlang-shipment
```

### Running as a Service

Pre-configured systemd service files are provided in the `deploy/` directory:

```bash
# Install using the provided script
cd deploy
sudo ./install.sh mainnet  # or testnet, regtest

# Or manually install the service file
sudo cp deploy/oni.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable oni
sudo systemctl start oni
```

The provided service files include:
- `oni.service` - Mainnet configuration
- `oni-testnet.service` - Testnet configuration

These service files include comprehensive security hardening:
- Strict filesystem protection
- Capability restrictions
- System call filtering
- Memory limits
- Automatic restart on failure

Key service management commands:

```bash
# View service status
sudo systemctl status oni

# View logs
sudo journalctl -u oni -f

# Restart service
sudo systemctl restart oni

# Stop service
sudo systemctl stop oni
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ONI_NETWORK` | `mainnet` | Bitcoin network (mainnet, testnet, signet, regtest) |
| `ONI_DATA_DIR` | `/data` | Data directory path |
| `ONI_RPC_USER` | - | RPC username (required in production) |
| `ONI_RPC_PASSWORD` | - | RPC password (required in production) |
| `ONI_RPC_PORT` | `8332` | RPC server port |
| `ONI_P2P_PORT` | `8333` | P2P network port |
| `ONI_LOG_LEVEL` | `info` | Log level (trace, debug, info, warn, error) |
| `ONI_MAX_CONNECTIONS` | `125` | Maximum peer connections |
| `ONI_DB_CACHE_MB` | `450` | Database cache size in MB |

### Configuration File

Create `oni.conf` for advanced configuration:

```ini
# Network
network=mainnet
listen=1
maxconnections=125

# RPC
rpcuser=your_username
rpcpassword=your_secure_password
rpcbind=127.0.0.1
rpcport=8332

# Storage
datadir=/var/lib/oni
dbcache=4096
txindex=0
prune=0

# Logging
debug=0
printtoconsole=1

# Performance
sigcachesize=500000
maxorphantx=100
```

## Security

### Network Security

1. **Firewall Configuration**

```bash
# Allow P2P traffic
sudo ufw allow 8333/tcp

# Allow RPC only from localhost
sudo ufw allow from 127.0.0.1 to any port 8332
```

2. **RPC Security**
   - Always use strong passwords
   - Bind RPC to localhost only
   - Use TLS for remote access (via reverse proxy)

3. **Reverse Proxy with TLS**

```nginx
# /etc/nginx/sites-available/oni-rpc
server {
    listen 443 ssl http2;
    server_name rpc.example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8332;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        # Basic auth (in addition to RPC auth)
        auth_basic "Restricted";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}
```

### Data Security

1. **Backup Strategy**
   - Regular backups of chainstate
   - Offsite backup storage
   - Test restore procedures

2. **Disk Encryption**
   - Use LUKS for disk encryption
   - Secure key management

## Monitoring

A complete monitoring stack is provided in the `monitoring/` directory.

### Quick Start with Monitoring

```bash
# Start oni with Prometheus and Grafana
docker-compose --profile monitoring up -d

# Access Grafana
open http://localhost:3000
# Default credentials: admin / (password from .env)

# Access Prometheus
open http://localhost:9090
```

### Health Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Overall health status |
| `GET /health/live` | Liveness probe (Kubernetes) |
| `GET /health/ready` | Readiness probe (Kubernetes) |
| `GET /metrics` | Prometheus metrics |

### Prometheus Integration

Pre-configured Prometheus configuration is provided in `monitoring/prometheus.yml`:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'oni'
    static_configs:
      - targets: ['oni:9100']
    scrape_interval: 15s
```

### Key Metrics

- `oni_block_height` - Current block height
- `oni_peer_count` - Connected peers
- `oni_mempool_size` - Mempool transaction count
- `oni_mempool_bytes` - Mempool size in bytes
- `oni_rpc_requests_total` - Total RPC requests
- `oni_blocks_validated_total` - Blocks validated

### Grafana Dashboard

Import the provided dashboard from `monitoring/grafana/dashboards/oni.json`.

### Alerting

Example alerting rules:

```yaml
# alerts.yml
groups:
  - name: oni
    rules:
      - alert: NodeDown
        expr: up{job="oni"} == 0
        for: 5m
        labels:
          severity: critical

      - alert: LowPeerCount
        expr: oni_peer_count < 3
        for: 10m
        labels:
          severity: warning

      - alert: SyncStalled
        expr: increase(oni_block_height[1h]) == 0
        for: 1h
        labels:
          severity: warning
```

## Maintenance

### Upgrading

```bash
# Docker upgrade
docker-compose pull
docker-compose up -d

# Native upgrade
git pull
make build
sudo systemctl restart oni
```

### Log Rotation

Logs are automatically rotated when using Docker. For native deployments, configure logrotate:

```
# /etc/logrotate.d/oni
/var/log/oni/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 oni oni
    postrotate
        systemctl reload oni
    endscript
}
```

### Database Maintenance

```bash
# Check database integrity
oni-cli verifychain

# Reindex (if needed)
oni-cli reindex
```

## Troubleshooting

### Common Issues

1. **Node won't start**
   - Check logs: `docker-compose logs oni`
   - Verify port availability: `netstat -tlnp | grep 8333`
   - Check disk space: `df -h`

2. **Slow sync**
   - Increase `dbcache` value
   - Check network connectivity
   - Verify SSD performance

3. **High memory usage**
   - Reduce `sigcachesize`
   - Enable pruning
   - Reduce `maxconnections`

4. **Connection issues**
   - Check firewall rules
   - Verify DNS resolution
   - Check peer list

### Debug Mode

```bash
# Enable debug logging
export ONI_LOG_LEVEL=debug
docker-compose up

# Or for native
./oni --debug
```

### Getting Help

- GitHub Issues: https://github.com/AbdelStark/oni/issues
- Documentation: https://oni.dev/docs
