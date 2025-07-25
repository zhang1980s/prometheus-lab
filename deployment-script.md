# Deployment Script for Prometheus and Grafana

Below is the bash script to deploy Prometheus and Grafana using containerd on Amazon Linux 2023. You can copy this script to a file named `deploy.sh` and make it executable with `chmod +x deploy.sh`.

```bash
#!/bin/bash

# Prometheus and Grafana Deployment Script
# For Amazon Linux 2023 with containerd
# ---------------------------------------

# Set script to exit on error
set -e

# Log file
LOG_FILE="/var/log/prometheus-grafana-deploy.log"

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

log "Starting Prometheus and Grafana deployment"

# Update system
log "Updating system packages..."
dnf update -y
check_status "System update"

# Install required packages
log "Installing required packages..."
dnf install -y wget curl vim jq nginx httpd-tools
check_status "Package installation"

# Install containerd
log "Installing containerd..."
dnf install -y containerd
check_status "containerd installation"

# Start and enable containerd
log "Starting containerd service..."
systemctl start containerd
systemctl enable containerd
check_status "containerd service start"

# Configure containerd
log "Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Modify config if needed for production settings
systemctl restart containerd
check_status "containerd configuration"

# Create directories for persistent storage
log "Creating directories for persistent storage..."
mkdir -p /data/prometheus /data/grafana /etc/prometheus /etc/grafana
chmod 755 /data/prometheus /data/grafana
check_status "Directory creation"

# Create Prometheus configuration
log "Creating Prometheus configuration..."
cat > /etc/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9091']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
      # Add your EC2 instances here
      # - targets: ['ec2-instance-1:9100', 'ec2-instance-2:9100']
EOF
check_status "Prometheus configuration creation"

# Create Nginx configuration for Prometheus
log "Creating Nginx configuration for Prometheus..."
cat > /etc/nginx/conf.d/prometheus.conf << 'EOF'
server {
    listen 9090;
    
    location / {
        auth_basic "Prometheus";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        proxy_pass http://localhost:9091;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
check_status "Nginx configuration for Prometheus"

# Create Prometheus user
log "Creating Prometheus user for authentication..."
htpasswd -bc /etc/nginx/.htpasswd admin secure_prometheus_password
check_status "Prometheus user creation"

# Create Grafana configuration
log "Creating Grafana configuration..."
cat > /etc/grafana/grafana.ini << 'EOF'
[server]
http_port = 3000

[security]
admin_user = admin
admin_password = secure_grafana_password

[auth]
disable_login_form = false

[auth.basic]
enabled = true

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
EOF
check_status "Grafana configuration creation"

# Pull Prometheus image
log "Pulling Prometheus image..."
ctr image pull docker.io/prom/prometheus:latest
check_status "Prometheus image pull"

# Pull Grafana image
log "Pulling Grafana image..."
ctr image pull docker.io/grafana/grafana:latest
check_status "Grafana image pull"

# Pull Node Exporter image
log "Pulling Node Exporter image..."
ctr image pull docker.io/prom/node-exporter:latest
check_status "Node Exporter image pull"

# Create containerd namespace if it doesn't exist
log "Creating containerd namespace..."
ctr namespace ls | grep -q monitoring || ctr namespace create monitoring
check_status "containerd namespace creation"

# Run Node Exporter
log "Starting Node Exporter container..."
ctr -n monitoring run \
    --detach \
    --net-host \
    docker.io/prom/node-exporter:latest \
    node-exporter \
    --path.rootfs=/host
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

# Start and enable Nginx
log "Starting Nginx service..."
systemctl start nginx
systemctl enable nginx
check_status "Nginx service start"

# Configure firewall if it's enabled
if systemctl is-active --quiet firewalld; then
    log "Configuring firewall..."
    firewall-cmd --permanent --add-port=9090/tcp
    firewall-cmd --permanent --add-port=3000/tcp
    firewall-cmd --reload
    check_status "Firewall configuration"
fi

# Create a basic Grafana dashboard configuration
log "Creating Grafana dashboard configuration..."
mkdir -p /data/grafana/dashboards
cat > /data/grafana/dashboards/node-exporter-dashboard.json << 'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": "-- Grafana --",
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "gnetId": null,
  "graphTooltip": 0,
  "id": 1,
  "links": [],
  "panels": [
    {
      "aliasColors": {},
      "bars": false,
      "dashLength": 10,
      "dashes": false,
      "datasource": "Prometheus",
      "fill": 1,
      "fillGradient": 0,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "hiddenSeries": false,
      "id": 2,
      "legend": {
        "avg": false,
        "current": false,
        "max": false,
        "min": false,
        "show": true,
        "total": false,
        "values": false
      },
      "lines": true,
      "linewidth": 1,
      "nullPointMode": "null",
      "options": {
        "dataLinks": []
      },
      "percentage": false,
      "pointradius": 2,
      "points": false,
      "renderer": "flot",
      "seriesOverrides": [],
      "spaceLength": 10,
      "stack": false,
      "steppedLine": false,
      "targets": [
        {
          "expr": "100 - (avg by (instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)",
          "refId": "A"
        }
      ],
      "thresholds": [],
      "timeFrom": null,
      "timeRegions": [],
      "timeShift": null,
      "title": "CPU Usage",
      "tooltip": {
        "shared": true,
        "sort": 0,
        "value_type": "individual"
      },
      "type": "graph",
      "xaxis": {
        "buckets": null,
        "mode": "time",
        "name": null,
        "show": true,
        "values": []
      },
      "yaxes": [
        {
          "format": "percent",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        },
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        }
      ],
      "yaxis": {
        "align": false,
        "alignLevel": null
      }
    },
    {
      "aliasColors": {},
      "bars": false,
      "dashLength": 10,
      "dashes": false,
      "datasource": "Prometheus",
      "fill": 1,
      "fillGradient": 0,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "hiddenSeries": false,
      "id": 4,
      "legend": {
        "avg": false,
        "current": false,
        "max": false,
        "min": false,
        "show": true,
        "total": false,
        "values": false
      },
      "lines": true,
      "linewidth": 1,
      "nullPointMode": "null",
      "options": {
        "dataLinks": []
      },
      "percentage": false,
      "pointradius": 2,
      "points": false,
      "renderer": "flot",
      "seriesOverrides": [],
      "spaceLength": 10,
      "stack": false,
      "steppedLine": false,
      "targets": [
        {
          "expr": "node_memory_MemTotal_bytes - node_memory_MemFree_bytes - node_memory_Buffers_bytes - node_memory_Cached_bytes",
          "refId": "A"
        }
      ],
      "thresholds": [],
      "timeFrom": null,
      "timeRegions": [],
      "timeShift": null,
      "title": "Memory Usage",
      "tooltip": {
        "shared": true,
        "sort": 0,
        "value_type": "individual"
      },
      "type": "graph",
      "xaxis": {
        "buckets": null,
        "mode": "time",
        "name": null,
        "show": true,
        "values": []
      },
      "yaxes": [
        {
          "format": "bytes",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        },
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        }
      ],
      "yaxis": {
        "align": false,
        "alignLevel": null
      }
    },
    {
      "aliasColors": {},
      "bars": false,
      "dashLength": 10,
      "dashes": false,
      "datasource": "Prometheus",
      "fill": 1,
      "fillGradient": 0,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "hiddenSeries": false,
      "id": 6,
      "legend": {
        "avg": false,
        "current": false,
        "max": false,
        "min": false,
        "show": true,
        "total": false,
        "values": false
      },
      "lines": true,
      "linewidth": 1,
      "nullPointMode": "null",
      "options": {
        "dataLinks": []
      },
      "percentage": false,
      "pointradius": 2,
      "points": false,
      "renderer": "flot",
      "seriesOverrides": [],
      "spaceLength": 10,
      "stack": false,
      "steppedLine": false,
      "targets": [
        {
          "expr": "100 - ((node_filesystem_avail_bytes{mountpoint=\"/\"} * 100) / node_filesystem_size_bytes{mountpoint=\"/\"})",
          "refId": "A"
        }
      ],
      "thresholds": [],
      "timeFrom": null,
      "timeRegions": [],
      "timeShift": null,
      "title": "Disk Usage",
      "tooltip": {
        "shared": true,
        "sort": 0,
        "value_type": "individual"
      },
      "type": "graph",
      "xaxis": {
        "buckets": null,
        "mode": "time",
        "name": null,
        "show": true,
        "values": []
      },
      "yaxes": [
        {
          "format": "percent",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        },
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        }
      ],
      "yaxis": {
        "align": false,
        "alignLevel": null
      }
    }
  ],
  "schemaVersion": 22,
  "style": "dark",
  "tags": [],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "",
  "title": "Node Exporter Dashboard",
  "uid": "node-exporter",
  "version": 1
}
EOF
check_status "Grafana dashboard configuration"

# Create Grafana datasource configuration
log "Creating Grafana datasource configuration..."
mkdir -p /data/grafana/provisioning/datasources
cat > /data/grafana/provisioning/datasources/prometheus.yaml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9091
    isDefault: true
EOF
check_status "Grafana datasource configuration"

# Create Grafana dashboard provisioning
log "Creating Grafana dashboard provisioning..."
mkdir -p /data/grafana/provisioning/dashboards
cat > /data/grafana/provisioning/dashboards/default.yaml << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
EOF
check_status "Grafana dashboard provisioning"

# Restart Grafana to apply changes
log "Restarting Grafana container..."
ctr -n monitoring task kill --signal 9 grafana
sleep 5
ctr -n monitoring task start grafana
check_status "Grafana container restart"

# Print access information
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
log "Deployment completed successfully!"
log "--------------------------------------"
log "Access Prometheus: http://$PUBLIC_IP:9090"
log "  Username: admin"
log "  Password: secure_prometheus_password"
log ""
log "Access Grafana: http://$PUBLIC_IP:3000"
log "  Username: admin"
log "  Password: secure_grafana_password"
log "--------------------------------------"
log "IMPORTANT: Change these default passwords immediately!"

# Add target EC2 instances instructions
log ""
log "To add target EC2 instances for monitoring:"
log "1. Install and run node_exporter on each target instance"
log "2. Edit /etc/prometheus/prometheus.yml to add the targets"
log "3. Restart Prometheus container to apply changes"

exit 0
```

## Usage Instructions

1. SSH into your Amazon Linux 2023 EC2 instance
2. Copy the script content above to a file named `deploy.sh`
3. Make the script executable:
   ```bash
   chmod +x deploy.sh
   ```
4. Run the script as root:
   ```bash
   sudo ./deploy.sh
   ```
5. Follow the on-screen instructions after deployment

## Post-Deployment Steps

After running the script:

1. Change the default passwords for both Prometheus and Grafana
2. Add your target EC2 instances to the Prometheus configuration
3. Create additional dashboards in Grafana as needed
4. Set up alerts based on your monitoring requirements

## Security Notes

- The script sets up basic authentication for both Prometheus and Grafana
- Default passwords are included in the script - change these immediately after deployment
- Consider implementing HTTPS/TLS for production environments
- Review and adjust firewall rules as needed for your environment