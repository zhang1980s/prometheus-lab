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
    node-exporter
check_status "Node Exporter container start"

# Run Prometheus
log "Starting Prometheus container..."
ctr -n monitoring run \
    --detach \
    --mount type=bind,src=/etc/prometheus,dst=/etc/prometheus,options=rbind:ro \
    --mount type=bind,src=/data/prometheus,dst=/prometheus,options=rbind:rw \
    --net-host \
    docker.io/prom/prometheus:latest \
    prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --web.listen-address=:9091 \
    --web.enable-lifecycle
check_status "Prometheus container start"

# Run Grafana
log "Starting Grafana container..."
ctr -n monitoring run \
    --detach \
    --mount type=bind,src=/etc/grafana/grafana.ini,dst=/etc/grafana/grafana.ini,options=rbind:ro \
    --mount type=bind,src=/data/grafana,dst=/var/lib/grafana,options=rbind:rw \
    --net-host \
    --env GF_SECURITY_ADMIN_USER=admin \
    --env GF_SECURITY_ADMIN_PASSWORD=secure_grafana_password \
    docker.io/grafana/grafana:latest \
    grafana
check_status "Grafana container start"

# Restart Nginx
log "Restarting Nginx service..."
systemctl restart nginx
check_status "Nginx service restart"

# Print access information
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
log "Update completed successfully!"
log "--------------------------------------"
log "Access Prometheus: http://$PUBLIC_IP:9090"
log "Access Grafana: http://$PUBLIC_IP:3000"
log "--------------------------------------"
log "Backup files are stored in /root/monitoring-backups/"
log "Prometheus backup: prometheus-data-${BACKUP_DATE}.tar.gz"
log "Grafana backup: grafana-data-${BACKUP_DATE}.tar.gz"

exit 0