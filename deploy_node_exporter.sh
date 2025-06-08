#!/bin/bash

# Node Exporter Deployment Script
# For Amazon Linux 2023
# ---------------------------------------

# Set script to exit on error
set -e

# Log file
LOG_FILE="/var/log/node-exporter-deploy.log"

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check if command succeeded
check_status() {
    if [ $? -eq 0 ]; then
        log "SUCCESS: $1"
    else
        log "ERROR: $1"
        exit 1
    fi
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Create log file
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log "Starting Node Exporter deployment"

# Update system
log "Updating system packages..."
dnf update -y
check_status "System update"

# Install required packages
log "Installing required packages..."
dnf install -y wget
check_status "Package installation"

# Download and install Node Exporter
log "Downloading Node Exporter..."
NODE_EXPORTER_VERSION="1.5.0"
wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
check_status "Node Exporter download"

log "Extracting Node Exporter..."
tar xvfz node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
check_status "Node Exporter extraction"

log "Installing Node Exporter..."
cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
check_status "Node Exporter installation"

# Create systemd service
log "Creating systemd service..."
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF
check_status "Systemd service creation"

# Start and enable service
log "Starting Node Exporter service..."
systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter
check_status "Node Exporter service start"

# Clean up
log "Cleaning up..."
rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64 node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
check_status "Cleanup"

# Get instance IP
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "Not available")

log "Node Exporter deployment completed successfully!"
log "--------------------------------------"
log "Node Exporter is running on port 9100"
log "Private IP: $INSTANCE_IP"
if [ "$PUBLIC_IP" != "Not available" ]; then
    log "Public IP: $PUBLIC_IP"
fi
log "--------------------------------------"
log "To add this instance to Prometheus, update the prometheus.yml file on your Prometheus server:"
log ""
log "  - job_name: 'node'"
log "    static_configs:"
log "      - targets: ['localhost:9100']"
log "      - targets: ['$INSTANCE_IP:9100']  # Add this line"
log ""
log "Then restart the Prometheus container:"
log "sudo ctr -n monitoring task kill --signal 9 prometheus"
log "sudo ctr -n monitoring task start prometheus"

# Verify service is running
if systemctl is-active --quiet node_exporter; then
    log "Node Exporter is running correctly"
else
    log "WARNING: Node Exporter service is not running. Please check the logs."
fi

exit 0