#!/bin/bash

# Prometheus and Grafana Uninstall Script
# For Amazon Linux 2023 with containerd
# ---------------------------------------

# Set script to exit on error
set -e

# Default values
REMOVE_DATA=false
REMOVE_CONFIGS=false
BACKUP_BEFORE_REMOVE=true

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to display usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -d, --remove-data       Remove all data directories (default: false)"
    echo "  -c, --remove-configs    Remove all configuration files (default: false)"
    echo "  -n, --no-backup         Do not create backup before removal (default: backup is created)"
    echo "  -h, --help              Display this help message"
    echo ""
    echo "WARNING: This script will remove the Prometheus and Grafana monitoring system."
    echo "         Use with caution, especially with the --remove-data option."
    echo ""
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d|--remove-data)
            REMOVE_DATA=true
            shift
            ;;
        -c|--remove-configs)
            REMOVE_CONFIGS=true
            shift
            ;;
        -n|--no-backup)
            BACKUP_BEFORE_REMOVE=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Confirm uninstallation
echo "WARNING: This will uninstall Prometheus and Grafana monitoring system."
echo "         Services will be stopped and containers will be removed."
if [ "$REMOVE_DATA" = true ]; then
    echo "         All data directories will be removed."
fi
if [ "$REMOVE_CONFIGS" = true ]; then
    echo "         All configuration files will be removed."
fi
echo ""
read -p "Are you sure you want to continue? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Create backup if requested
if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
    log "Creating backup before uninstallation..."
    BACKUP_DATE=$(date +%Y%m%d%H%M%S)
    BACKUP_DIR="/root/monitoring-backup-before-uninstall-${BACKUP_DATE}"
    mkdir -p "$BACKUP_DIR"
    
    # Backup Prometheus data
    if [ -d "/data/prometheus" ]; then
        log "Backing up Prometheus data..."
        tar -czf "${BACKUP_DIR}/prometheus-data.tar.gz" -C /data prometheus
    fi
    
    # Backup Grafana data
    if [ -d "/data/grafana" ]; then
        log "Backing up Grafana data..."
        tar -czf "${BACKUP_DIR}/grafana-data.tar.gz" -C /data grafana
    fi
    
    # Backup configurations
    if [ -d "/etc/prometheus" ]; then
        log "Backing up Prometheus configuration..."
        tar -czf "${BACKUP_DIR}/prometheus-config.tar.gz" -C /etc prometheus
    fi
    
    if [ -d "/etc/grafana" ]; then
        log "Backing up Grafana configuration..."
        tar -czf "${BACKUP_DIR}/grafana-config.tar.gz" -C /etc grafana
    fi
    
    if [ -f "/etc/nginx/conf.d/prometheus.conf" ]; then
        log "Backing up Nginx configuration..."
        cp /etc/nginx/conf.d/prometheus.conf "${BACKUP_DIR}/"
    fi
    
    log "Backup created at: ${BACKUP_DIR}"
fi

# Stop and remove containers
log "Stopping and removing containers..."
# Check if monitoring namespace exists
if ctr namespace ls | grep -q monitoring; then
    # Get list of running tasks
    TASKS=$(ctr -n monitoring task ls 2>/dev/null | awk 'NR>1 {print $1}')
    if [ -n "$TASKS" ]; then
        for task in $TASKS; do
            log "Stopping task: $task"
            ctr -n monitoring task kill --signal 9 "$task" || log "Failed to stop task: $task (may already be stopped)"
        done
    else
        log "No running tasks found"
    fi
    
    sleep 2
    
    # Get list of containers
    CONTAINERS=$(ctr -n monitoring container ls 2>/dev/null | awk 'NR>1 {print $1}')
    if [ -n "$CONTAINERS" ]; then
        for container in $CONTAINERS; do
            log "Removing container: $container"
            ctr -n monitoring container rm "$container" || log "Failed to remove container: $container (may not exist)"
        done
    else
        log "No containers found"
    fi
else
    log "Monitoring namespace not found, skipping container removal"
fi

# Remove container images
log "Removing container images..."
# Check if monitoring namespace exists
if ctr namespace ls | grep -q monitoring; then
    # Get list of images
    IMAGES=$(ctr -n monitoring image ls 2>/dev/null | awk 'NR>1 {print $1}')
    if [ -n "$IMAGES" ]; then
        for image in $IMAGES; do
            log "Removing image: $image"
            ctr -n monitoring image rm "$image" || log "Failed to remove image: $image (may be in use or not exist)"
        done
    else
        log "No images found"
    fi
else
    log "Monitoring namespace not found, skipping image removal"
fi

# Stop and disable services
log "Stopping and disabling services..."
# Check if nginx service exists
if systemctl list-unit-files | grep -q nginx.service; then
    systemctl stop nginx || log "Failed to stop nginx service (may already be stopped)"
    systemctl disable nginx || log "Failed to disable nginx service"
    log "Nginx service stopped and disabled"
else
    log "Nginx service not found, skipping"
fi

# Check if node_exporter service exists
if systemctl list-unit-files | grep -q node_exporter.service; then
    systemctl stop node_exporter || log "Failed to stop node_exporter service (may already be stopped)"
    systemctl disable node_exporter || log "Failed to disable node_exporter service"
    log "Node Exporter service stopped and disabled"
else
    log "Node Exporter service not found, skipping"
fi

# Remove Node Exporter systemd service
if [ -f "/etc/systemd/system/node_exporter.service" ]; then
    log "Removing Node Exporter systemd service..."
    rm -f /etc/systemd/system/node_exporter.service
    systemctl daemon-reload
fi

# Remove data directories if requested
if [ "$REMOVE_DATA" = true ]; then
    log "Removing data directories..."
    rm -rf /data/prometheus
    rm -rf /data/grafana
    log "Data directories removed."
else
    log "Data directories preserved at /data/prometheus and /data/grafana"
fi

# Remove configuration files if requested
if [ "$REMOVE_CONFIGS" = true ]; then
    log "Removing configuration files..."
    rm -rf /etc/prometheus
    rm -rf /etc/grafana
    rm -f /etc/nginx/conf.d/prometheus.conf
    rm -f /etc/nginx/.htpasswd
    log "Configuration files removed."
else
    log "Configuration files preserved."
fi

# Remove monitoring namespace if empty
if [ -z "$(ctr -n monitoring container ls 2>/dev/null)" ]; then
    log "Removing monitoring namespace..."
    ctr namespace rm monitoring || true
fi

log "Uninstallation completed."
if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
    log "A backup was created at: ${BACKUP_DIR}"
fi
if [ "$REMOVE_DATA" = false ]; then
    log "Data directories were preserved at /data/prometheus and /data/grafana"
fi
if [ "$REMOVE_CONFIGS" = false ]; then
    log "Configuration files were preserved."
fi

log "To completely remove all packages:"
log "  sudo dnf remove -y containerd nginx"

exit 0