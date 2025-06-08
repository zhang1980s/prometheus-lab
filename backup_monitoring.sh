#!/bin/bash

# Prometheus and Grafana Backup Script
# For Amazon Linux 2023 with containerd
# ---------------------------------------

# Set script to exit on error
set -e

# Default values
BACKUP_DIR="/root/monitoring-backups"
RETENTION_COUNT=7
COMPRESS=true

# Log file
LOG_FILE="/var/log/monitoring-backup.log"

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

# Function to display usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -d, --directory DIR    Backup directory (default: $BACKUP_DIR)"
    echo "  -r, --retention NUM    Number of backups to keep (default: $RETENTION_COUNT)"
    echo "  -n, --no-compress      Do not compress backups"
    echo "  -h, --help             Display this help message"
    echo ""
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d|--directory)
            BACKUP_DIR="$2"
            shift
            shift
            ;;
        -r|--retention)
            RETENTION_COUNT="$2"
            shift
            shift
            ;;
        -n|--no-compress)
            COMPRESS=false
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

# Create log file
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log "Starting Prometheus and Grafana backup"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"
check_status "Backup directory creation"

# Generate timestamp
BACKUP_DATE=$(date +%Y%m%d%H%M%S)
BACKUP_NAME="monitoring-backup-${BACKUP_DATE}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Create temporary directory
mkdir -p "${BACKUP_PATH}"
check_status "Temporary directory creation"

# Backup Prometheus data
log "Backing up Prometheus data..."
if [ "$COMPRESS" = true ]; then
    tar -czf "${BACKUP_PATH}/prometheus-data.tar.gz" -C /data prometheus
else
    mkdir -p "${BACKUP_PATH}/prometheus"
    cp -r /data/prometheus/* "${BACKUP_PATH}/prometheus/"
fi
check_status "Prometheus data backup"

# Backup Prometheus configuration
log "Backing up Prometheus configuration..."
mkdir -p "${BACKUP_PATH}/config/prometheus"
cp -r /etc/prometheus/* "${BACKUP_PATH}/config/prometheus/"
check_status "Prometheus configuration backup"

# Backup Grafana data
log "Backing up Grafana data..."
if [ "$COMPRESS" = true ]; then
    tar -czf "${BACKUP_PATH}/grafana-data.tar.gz" -C /data grafana
else
    mkdir -p "${BACKUP_PATH}/grafana"
    cp -r /data/grafana/* "${BACKUP_PATH}/grafana/"
fi
check_status "Grafana data backup"

# Backup Grafana configuration
log "Backing up Grafana configuration..."
mkdir -p "${BACKUP_PATH}/config/grafana"
cp -r /etc/grafana/* "${BACKUP_PATH}/config/grafana/"
check_status "Grafana configuration backup"

# Backup Nginx configuration
log "Backing up Nginx configuration..."
mkdir -p "${BACKUP_PATH}/config/nginx"
cp /etc/nginx/conf.d/prometheus.conf "${BACKUP_PATH}/config/nginx/"
check_status "Nginx configuration backup"

# Create final archive
if [ "$COMPRESS" = true ]; then
    log "Creating final backup archive..."
    tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" -C "${BACKUP_DIR}" "${BACKUP_NAME}"
    check_status "Final archive creation"
    
    # Remove temporary directory
    rm -rf "${BACKUP_PATH}"
    check_status "Temporary directory cleanup"
    
    FINAL_BACKUP="${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
else
    FINAL_BACKUP="${BACKUP_PATH}"
fi

# Implement retention policy
if [ "$RETENTION_COUNT" -gt 0 ]; then
    log "Implementing retention policy (keeping $RETENTION_COUNT backups)..."
    
    if [ "$COMPRESS" = true ]; then
        # List all backup archives, sort by date (oldest first)
        BACKUPS=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | sort -r)
    else
        # List all backup directories, sort by date (oldest first)
        BACKUPS=$(ls -td "${BACKUP_DIR}"/monitoring-backup-* 2>/dev/null | sort -r)
    fi
    
    # Count backups
    BACKUP_COUNT=$(echo "$BACKUPS" | wc -l)
    
    # Remove old backups
    if [ "$BACKUP_COUNT" -gt "$RETENTION_COUNT" ]; then
        REMOVE_COUNT=$((BACKUP_COUNT - RETENTION_COUNT))
        log "Removing $REMOVE_COUNT old backup(s)..."
        
        REMOVE_LIST=$(echo "$BACKUPS" | tail -n "$REMOVE_COUNT")
        echo "$REMOVE_LIST" | xargs rm -rf
        check_status "Old backups removal"
    fi
fi

# Calculate backup size
if [ "$COMPRESS" = true ]; then
    BACKUP_SIZE=$(du -h "${FINAL_BACKUP}" | cut -f1)
else
    BACKUP_SIZE=$(du -sh "${FINAL_BACKUP}" | cut -f1)
fi

log "Backup completed successfully!"
log "--------------------------------------"
log "Backup location: ${FINAL_BACKUP}"
log "Backup size: ${BACKUP_SIZE}"
log "--------------------------------------"
log "To restore this backup, use:"
if [ "$COMPRESS" = true ]; then
    log "1. Extract the archive: tar -xzf ${BACKUP_NAME}.tar.gz"
    log "2. Restore Prometheus data: cp -r ${BACKUP_NAME}/prometheus/* /data/prometheus/"
    log "3. Restore Grafana data: cp -r ${BACKUP_NAME}/grafana/* /data/grafana/"
    log "4. Restore configurations if needed from ${BACKUP_NAME}/config/"
else
    log "1. Restore Prometheus data: cp -r ${BACKUP_NAME}/prometheus/* /data/prometheus/"
    log "2. Restore Grafana data: cp -r ${BACKUP_NAME}/grafana/* /data/grafana/"
    log "3. Restore configurations if needed from ${BACKUP_NAME}/config/"
fi
log "4. Restart services: systemctl restart nginx && ./update_monitoring.sh"

exit 0