#!/bin/bash
# install.sh - Install oni Bitcoin node on a Linux system
#
# Usage:
#   sudo ./install.sh [mainnet|testnet|regtest]
#
# Prerequisites:
#   - Erlang/OTP 26+ installed
#   - Gleam 1.0+ installed (for building from source)
#
# This script:
#   1. Creates oni user and group
#   2. Creates required directories
#   3. Installs systemd service
#   4. Creates default configuration
#   5. Enables and starts the service

set -euo pipefail

NETWORK="${1:-mainnet}"
ONI_USER="oni"
ONI_GROUP="oni"
ONI_HOME="/opt/oni"
ONI_DATA="/var/lib/oni"
ONI_LOG="/var/log/oni"
ONI_CONF="/etc/oni"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi

info "Installing oni Bitcoin node for $NETWORK network"

# Create oni user and group
if ! getent group "$ONI_GROUP" > /dev/null 2>&1; then
    info "Creating group: $ONI_GROUP"
    groupadd --system "$ONI_GROUP"
fi

if ! getent passwd "$ONI_USER" > /dev/null 2>&1; then
    info "Creating user: $ONI_USER"
    useradd --system \
        --gid "$ONI_GROUP" \
        --home-dir "$ONI_HOME" \
        --shell /usr/sbin/nologin \
        --comment "oni Bitcoin Node" \
        "$ONI_USER"
fi

# Create directories
info "Creating directories..."

mkdir -p "$ONI_HOME"
mkdir -p "$ONI_DATA"
mkdir -p "$ONI_LOG"
mkdir -p "$ONI_CONF"

# Adjust for network-specific data directory
if [[ "$NETWORK" != "mainnet" ]]; then
    ONI_DATA="/var/lib/oni-$NETWORK"
    mkdir -p "$ONI_DATA"
fi

# Set ownership
chown -R "$ONI_USER:$ONI_GROUP" "$ONI_HOME"
chown -R "$ONI_USER:$ONI_GROUP" "$ONI_DATA"
chown -R "$ONI_USER:$ONI_GROUP" "$ONI_LOG"
chown root:root "$ONI_CONF"
chmod 755 "$ONI_CONF"

# Copy application files (assumes built release is in current directory)
if [[ -d "build/erlang-shipment" ]]; then
    info "Installing application files..."
    cp -r build/erlang-shipment/* "$ONI_HOME/"
    chown -R "$ONI_USER:$ONI_GROUP" "$ONI_HOME"
else
    warn "No build found. Run 'make build' first, then re-run install."
fi

# Create configuration file
info "Creating configuration file..."
CONF_FILE="$ONI_CONF/oni.conf"

if [[ ! -f "$CONF_FILE" ]]; then
    cat > "$CONF_FILE" << EOF
# oni Bitcoin Node Configuration
# Generated on $(date)

# Network: mainnet, testnet, signet, regtest
ONI_NETWORK=$NETWORK

# Data directory
ONI_DATA_DIR=$ONI_DATA

# Logging level: trace, debug, info, warn, error
ONI_LOG_LEVEL=info

# RPC Configuration
ONI_RPC_PORT=8332
# ONI_RPC_USER=your_username
# ONI_RPC_PASSWORD=your_secure_password_here

# P2P Configuration
ONI_P2P_PORT=8333

# Metrics
ONI_METRICS_PORT=9100
ONI_METRICS_ENABLED=true

# Performance tuning
ONI_MAX_CONNECTIONS=125
ONI_DB_CACHE_MB=450
EOF

    chmod 600 "$CONF_FILE"
    info "Configuration file created: $CONF_FILE"
    warn "Please edit $CONF_FILE to set RPC credentials before starting"
else
    info "Configuration file already exists: $CONF_FILE"
fi

# Install systemd service
info "Installing systemd service..."

SERVICE_FILE="oni.service"
if [[ "$NETWORK" != "mainnet" ]]; then
    SERVICE_FILE="oni-$NETWORK.service"
fi

# Update service file paths based on install location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/$SERVICE_FILE" ]]; then
    cp "$SCRIPT_DIR/$SERVICE_FILE" "/etc/systemd/system/"
else
    cp "$SCRIPT_DIR/oni.service" "/etc/systemd/system/$SERVICE_FILE"
    # Update paths in the copied service file
    sed -i "s|/var/lib/oni|$ONI_DATA|g" "/etc/systemd/system/$SERVICE_FILE"
    sed -i "s|ONI_NETWORK=mainnet|ONI_NETWORK=$NETWORK|g" "/etc/systemd/system/$SERVICE_FILE"
fi

# Reload systemd
systemctl daemon-reload

# Enable service
info "Enabling service..."
systemctl enable "$SERVICE_FILE"

info "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Edit configuration: sudo nano $ONI_CONF/oni.conf"
echo "  2. Set RPC credentials in the configuration file"
echo "  3. Start the service: sudo systemctl start ${SERVICE_FILE%.service}"
echo "  4. Check status: sudo systemctl status ${SERVICE_FILE%.service}"
echo "  5. View logs: sudo journalctl -u ${SERVICE_FILE%.service} -f"
echo ""
echo "Useful commands:"
echo "  Stop:    sudo systemctl stop ${SERVICE_FILE%.service}"
echo "  Restart: sudo systemctl restart ${SERVICE_FILE%.service}"
echo "  Disable: sudo systemctl disable ${SERVICE_FILE%.service}"
