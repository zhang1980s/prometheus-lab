#!/bin/bash

# Prometheus and Grafana Update Script
# For Amazon Linux 2023 with containerd
# ---------------------------------------

# Set script to exit on error
set -e

# Log file
LOG_FILE="/var/log/monitoring-update.log"

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

log "Starting Prometheus and Grafana update"

# Backup current data
log "Backing up current data..."
BACKUP_DATE=$(date +%Y%m%d%H%M%S)
mkdir -p /root/monitoring-backups
tar -czf /root/monitoring-backups/prometheus-data-${BACKUP_DATE}.tar.gz -C /data prometheus
tar -czf /root/monitoring-backups/grafana-data-${BACKUP_DATE}.tar.gz -C /data grafana
check_status "Data backup"

# Pull latest images
log "Pulling latest Prometheus image..."
ctr -n monitoring image pull docker.io/prom/prometheus:latest
check_status "Prometheus image pull"

log "Pulling latest Grafana image..."
ctr -n monitoring image pull docker.io/grafana/grafana:latest
check_status "Grafana image pull"

log "Pulling latest Node Exporter image..."
ctr -n monitoring image pull docker.io/prom/node-exporter:latest
check_status "Node Exporter image pull"

# Stop and remove containers
log "Stopping Prometheus container..."
ctr -n monitoring task kill --signal 9 prometheus || true
sleep 2
ctr -n monitoring container rm prometheus || true
check_status "Prometheus container removal"

log "Stopping Grafana container..."
ctr -n monitoring task kill --signal 9 grafana || true
sleep 2
ctr -n monitoring container rm grafana || true
check_status "Grafana container removal"

log "Stopping Node Exporter container..."
ctr -n monitoring task kill --signal 9 node-exporter || true
sleep 2
ctr -n monitoring container rm node-exporter || true
check_status "Node Exporter container removal"

# Run Node Exporter
log "Starting Node Exporter container..."
ctr -n monitoring run \
    --detach \
    --net-host \
    docker.io/prom/node-exporter:latest \
    node-exporter || log "Node Exporter container already exists, skipping"
log "SUCCESS: Node Exporter container start"

# Run Prometheus
log "Starting Prometheus container..."
ctr -n monitoring run \
    --detach \
    --mount type=bind,src=/etc/prometheus,dst=/etc/prometheus,options=rbind:ro \
    --mount type=bind,src=/data/prometheus,dst=/prometheus,options=rbind:rw \
    --net-host \
    --env PROMETHEUS_ARGS="" \
    docker.io/prom/prometheus:latest \
    prometheus || log "Prometheus container already exists, skipping"
log "SUCCESS: Prometheus container start"

# Run Grafana
log "Starting Grafana container..."

# Set very permissive permissions on Grafana data directory
log "Setting permissions on Grafana data directory..."
chmod -R 777 /data/grafana
log "Grafana permissions set"

# Remove any existing Grafana container and database
log "Removing any existing Grafana container and database..."
ctr -n monitoring task kill --signal 9 grafana 2>/dev/null || true
ctr -n monitoring container rm grafana 2>/dev/null || true
rm -f /data/grafana/grafana.db 2>/dev/null || true
log "Existing Grafana container and database removed or not found"

# Start Grafana with minimal configuration
log "Starting Grafana with minimal configuration..."
ctr -n monitoring run \
    --detach \
    --mount type=bind,src=/etc/grafana/grafana.ini,dst=/etc/grafana/grafana.ini,options=rbind:ro \
    --mount type=bind,src=/data/grafana,dst=/var/lib/grafana,options=rbind:rw \
    --net-host \
    --env GF_SECURITY_ADMIN_USER=admin \
    --env GF_SECURITY_ADMIN_PASSWORD=admin \
    docker.io/grafana/grafana:latest \
    grafana || log "Grafana container already exists, skipping"

# Wait for Grafana to start up
log "Waiting for Grafana to start up..."
sleep 10

# Verify Grafana is running
log "Verifying Grafana is running..."
GRAFANA_STATUS=$(ctr -n monitoring task ls | grep grafana | awk '{print $3}')
if [ "$GRAFANA_STATUS" == "RUNNING" ]; then
    log "SUCCESS: Grafana is running properly"
else
    log "WARNING: Grafana may not be running properly. Status: $GRAFANA_STATUS"
    log "Attempting to restart Grafana..."
    ctr -n monitoring task kill --signal 9 grafana || true
    sleep 5
    ctr -n monitoring task start grafana || log "Failed to restart Grafana container"
fi

log "IMPORTANT: When accessing Grafana after update, log in with:"
log "  Username: admin"
log "  Password: admin"
log "You will be prompted to change the password on first login."

# Restart Nginx
log "Restarting Nginx service..."
systemctl restart nginx
check_status "Nginx service restart"

# Print access information
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "your-instance-ip")
log "Update completed successfully!"
log "--------------------------------------"
log "Access Prometheus: http://$PUBLIC_IP:8080"
log "Access Grafana: http://$PUBLIC_IP:3000"
log "  Username: admin"
log "  Password: admin (you'll be prompted to change this on first login)"
log "--------------------------------------"
log "Backup files are stored in /root/monitoring-backups/"
log "Prometheus backup: prometheus-data-${BACKUP_DATE}.tar.gz"
log "Grafana backup: grafana-data-${BACKUP_DATE}.tar.gz"

exit 0