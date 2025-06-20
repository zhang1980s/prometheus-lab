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

# Check if curl or curl-minimal is already installed
if command -v curl &> /dev/null; then
    log "curl is already available, skipping installation"
    CURL_INSTALLED=true
else
    CURL_INSTALLED=false
fi

# Install packages individually to handle potential conflicts
log "Installing wget..."
dnf install -y wget
check_status "wget installation"

# Only install curl if not already available
if [ "$CURL_INSTALLED" = false ]; then
    log "Installing curl..."
    # Try to install curl, but don't fail if it doesn't work
    dnf install -y curl || log "Failed to install curl, continuing with curl-minimal"
fi

log "Installing vim..."
dnf install -y vim
check_status "vim installation"

log "Installing jq..."
dnf install -y jq
check_status "jq installation"

log "Installing httpd-tools..."
dnf install -y httpd-tools
check_status "httpd-tools installation"

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
mkdir -p /data/prometheus /data/grafana /data/nginx /etc/prometheus /etc/grafana
chmod 777 /data/prometheus /data/grafana /data/nginx  # More permissive to allow container write access
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
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
      # Add your EC2 instances here
      # - targets: ['ec2-instance-1:9100', 'ec2-instance-2:9100']
EOF
check_status "Prometheus configuration creation"

# Create Nginx configuration directory
mkdir -p /data/nginx/conf.d

# Create optimized Nginx main config
log "Creating optimized Nginx configuration..."
cat > /data/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;  # Use all available cores
worker_cpu_affinity auto;  # Automatically distribute across CPUs

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF
check_status "Nginx main configuration creation"

# Create Nginx configuration for Prometheus
log "Creating Nginx configuration for Prometheus..."
cat > /data/nginx/conf.d/prometheus.conf << 'EOF'
server {
    listen 8080;
    
    location / {
        auth_basic "Prometheus";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        proxy_pass http://localhost:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
check_status "Nginx configuration for Prometheus"

# Create Prometheus user
log "Creating Prometheus user for authentication..."
htpasswd -bc /data/nginx/.htpasswd admin secure_prometheus_password
check_status "Prometheus user creation"

# Create minimal Grafana configuration
log "Creating minimal Grafana configuration..."
mkdir -p /etc/grafana
cat > /etc/grafana/grafana.ini << 'EOF'
[server]
http_port = 3000

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
EOF
check_status "Grafana configuration creation"

# Create containerd namespace if it doesn't exist
log "Creating containerd namespace..."
ctr namespace ls | grep -q monitoring || ctr namespace create monitoring
check_status "containerd namespace creation"

# Pull Prometheus image
log "Pulling Prometheus image..."
ctr -n monitoring image pull docker.io/prom/prometheus:latest
check_status "Prometheus image pull"

# Pull Grafana image
log "Pulling Grafana image..."
ctr -n monitoring image pull docker.io/grafana/grafana:latest
check_status "Grafana image pull"

# Pull Node Exporter image
log "Pulling Node Exporter image..."
ctr -n monitoring image pull docker.io/prom/node-exporter:latest
check_status "Node Exporter image pull"

# Pull Nginx image
log "Pulling Nginx image..."
ctr -n monitoring image pull docker.io/library/nginx:latest
check_status "Nginx image pull"

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
    --env PROMETHEUS_ARGS="" \
    docker.io/prom/prometheus:latest \
    prometheus
check_status "Prometheus container start"

# Run Grafana
log "Starting Grafana container..."

# Set very permissive permissions on Grafana data directory
log "Setting permissions on Grafana data directory..."
chmod -R 777 /data/grafana
check_status "Grafana permissions set"

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
    grafana
check_status "Grafana container start"

# Wait for Grafana to start up
log "Waiting for Grafana to start up..."
sleep 10

# Create Nginx mime.types file
log "Creating Nginx mime.types file..."
mkdir -p /data/nginx/etc
# Create a basic mime.types file
cat > /data/nginx/etc/mime.types << 'EOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    application/javascript                js;
    application/json                      json;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/x-icon                          ico;
    application/pdf                       pdf;
}
EOF
check_status "Nginx mime.types setup"

# Update Nginx configuration to use the local mime.types file
log "Updating Nginx configuration to use local mime.types..."
sed -i 's|include /etc/nginx/mime.types|include /etc/nginx/etc/mime.types|g' /data/nginx/nginx.conf
check_status "Nginx configuration update"

# Run Nginx container
log "Starting Nginx container..."
ctr -n monitoring run \
    --detach \
    --net-host \
    --mount type=bind,src=/data/nginx/nginx.conf,dst=/etc/nginx/nginx.conf,options=rbind:ro \
    --mount type=bind,src=/data/nginx/conf.d,dst=/etc/nginx/conf.d,options=rbind:ro \
    --mount type=bind,src=/data/nginx/.htpasswd,dst=/etc/nginx/.htpasswd,options=rbind:ro \
    --mount type=bind,src=/data/nginx/etc/mime.types,dst=/etc/nginx/etc/mime.types,options=rbind:ro \
    docker.io/library/nginx:latest \
    nginx
check_status "Nginx container start"

# Configure firewall if it's enabled
if systemctl is-active --quiet firewalld; then
    log "Configuring firewall..."
    firewall-cmd --permanent --add-port=8080/tcp
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
    url: http://localhost:9090
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

# Verify containers are running
log "Verifying containers are running..."

# Check Grafana
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

# Check Nginx
NGINX_STATUS=$(ctr -n monitoring task ls | grep nginx | awk '{print $3}')
if [ "$NGINX_STATUS" == "RUNNING" ]; then
    log "SUCCESS: Nginx is running properly"
else
    log "WARNING: Nginx may not be running properly. Status: $NGINX_STATUS"
    log "Attempting to restart Nginx..."
    ctr -n monitoring task kill --signal 9 nginx || true
    sleep 5
    ctr -n monitoring task start nginx || log "Failed to restart Nginx container"
fi

log "IMPORTANT: When first accessing Grafana, log in with:"
log "  Username: admin"
log "  Password: admin"
log "You will be prompted to change the password on first login."

# Print access information
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "your-instance-ip")
log "Deployment completed successfully!"
log "--------------------------------------"
log "Access Prometheus: http://$PUBLIC_IP:8080"
log "  Username: admin"
log "  Password: secure_prometheus_password"
log ""
log "Access Grafana: http://$PUBLIC_IP:3000"
log "  Username: admin"
log "  Password: admin (you'll be prompted to change this on first login)"
log "--------------------------------------"
log "IMPORTANT: Change these default passwords immediately!"

# Add target EC2 instances instructions
log ""
log "To add target EC2 instances for monitoring:"
log "1. Install and run node_exporter on each target instance"
log "2. Edit /etc/prometheus/prometheus.yml to add the targets"
log "3. Restart Prometheus container to apply changes"

exit 0