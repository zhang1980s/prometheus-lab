#!/bin/bash

# Setup Cron Job for Automated Monitoring Backups
# For Amazon Linux 2023
# ---------------------------------------

# Default values
BACKUP_SCRIPT="/root/prometheus-lab/backup_monitoring.sh"
BACKUP_DIR="/root/monitoring-backups"
RETENTION_COUNT=7
COMPRESS=true
SCHEDULE="0 2 * * *"  # Default: 2:00 AM daily

# Function to display usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -s, --script PATH       Path to backup script (default: $BACKUP_SCRIPT)"
    echo "  -d, --directory DIR     Backup directory (default: $BACKUP_DIR)"
    echo "  -r, --retention NUM     Number of backups to keep (default: $RETENTION_COUNT)"
    echo "  -n, --no-compress       Do not compress backups"
    echo "  -t, --time SCHEDULE     Cron schedule (default: '$SCHEDULE' - 2:00 AM daily)"
    echo "  -h, --help              Display this help message"
    echo ""
    echo "Schedule examples:"
    echo "  '0 2 * * *'             Daily at 2:00 AM"
    echo "  '0 2 * * 0'             Weekly on Sunday at 2:00 AM"
    echo "  '0 2 1 * *'             Monthly on the 1st at 2:00 AM"
    echo "  '0 */6 * * *'           Every 6 hours"
    echo ""
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -s|--script)
            BACKUP_SCRIPT="$2"
            shift
            shift
            ;;
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
        -t|--time)
            SCHEDULE="$2"
            shift
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

# Check if backup script exists
if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo "Backup script not found at $BACKUP_SCRIPT" >&2
    echo "Please provide the correct path using the -s option" >&2
    exit 1
fi

# Make sure backup script is executable
chmod +x "$BACKUP_SCRIPT"

# Build the backup command
BACKUP_CMD="$BACKUP_SCRIPT --directory $BACKUP_DIR --retention $RETENTION_COUNT"
if [ "$COMPRESS" = false ]; then
    BACKUP_CMD="$BACKUP_CMD --no-compress"
fi

# Create the cron job
CRON_JOB="$SCHEDULE $BACKUP_CMD > /var/log/monitoring-backup-cron.log 2>&1"

# Check if crontab exists for root
CRONTAB=$(crontab -l 2>/dev/null || echo "")

# Check if the job already exists
if echo "$CRONTAB" | grep -q "$BACKUP_SCRIPT"; then
    echo "A cron job for the backup script already exists."
    echo "Current cron jobs:"
    echo "$CRONTAB" | grep "$BACKUP_SCRIPT"
    
    read -p "Do you want to replace it? (y/n): " REPLACE
    if [ "$REPLACE" != "y" ] && [ "$REPLACE" != "Y" ]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Remove existing job
    CRONTAB=$(echo "$CRONTAB" | grep -v "$BACKUP_SCRIPT")
fi

# Add the new job
CRONTAB="${CRONTAB}
${CRON_JOB}"

# Install the crontab
echo "$CRONTAB" | crontab -

echo "Cron job installed successfully!"
echo "Schedule: $SCHEDULE"
echo "Command: $BACKUP_CMD"
echo ""
echo "To view all cron jobs:"
echo "  crontab -l"
echo ""
echo "To edit cron jobs:"
echo "  crontab -e"
echo ""
echo "To test the backup script immediately:"
echo "  $BACKUP_CMD"

exit 0