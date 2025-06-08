#!/bin/bash

# Prometheus and Grafana Test Script
# For Amazon Linux 2023 with containerd
# ---------------------------------------

# Set colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function for success messages
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function for warning messages
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function for error messages
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function for info messages
info() {
    echo "[INFO] $1"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

echo "=== Prometheus and Grafana Monitoring System Test ==="
echo "Testing monitoring system components..."
echo ""

# Check if containerd is running
echo "Checking containerd service..."
if systemctl is-active --quiet containerd; then
    success "containerd service is running"
else
    error "containerd service is not running"
    info "Try: systemctl start containerd"
    exit 1
fi

# Check if Nginx is running
echo "Checking Nginx service..."
if systemctl is-active --quiet nginx; then
    success "Nginx service is running"
else
    error "Nginx service is not running"
    info "Try: systemctl start nginx"
    exit 1
fi

# Check if containers are running
echo "Checking monitoring containers..."
PROMETHEUS_RUNNING=$(ctr -n monitoring container ls | grep prometheus || echo "")
GRAFANA_RUNNING=$(ctr -n monitoring container ls | grep grafana || echo "")
NODE_EXPORTER_RUNNING=$(ctr -n monitoring container ls | grep node-exporter || echo "")

if [ -n "$PROMETHEUS_RUNNING" ]; then
    success "Prometheus container is running"
else
    error "Prometheus container is not running"
    info "Check container logs: ctr -n monitoring container ls"
fi

if [ -n "$GRAFANA_RUNNING" ]; then
    success "Grafana container is running"
else
    error "Grafana container is not running"
    info "Check container logs: ctr -n monitoring container ls"
fi

if [ -n "$NODE_EXPORTER_RUNNING" ]; then
    success "Node Exporter container is running"
else
    warning "Node Exporter container is not running"
    info "This might be OK if you're using the systemd service instead"
    
    # Check if Node Exporter is running as a systemd service
    if systemctl is-active --quiet node_exporter; then
        success "Node Exporter systemd service is running"
    else
        warning "Node Exporter systemd service is not running"
        info "This is OK if Node Exporter is running in a container or on separate instances"
    fi
fi

# Test Prometheus API
echo ""
echo "Testing Prometheus API..."
PROMETHEUS_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9090/api/v1/status/config)

if [ "$PROMETHEUS_RESPONSE" = "200" ]; then
    success "Prometheus API is responding correctly"
else
    error "Prometheus API is not responding correctly (HTTP $PROMETHEUS_RESPONSE)"
    info "Check if Prometheus is running on port 9090"
fi

# Test Prometheus metrics
echo "Testing Prometheus metrics collection..."
PROMETHEUS_METRICS=$(curl -s http://localhost:9090/api/v1/query?query=up | grep -o '"result":\[.*\]' || echo "")

if [ -n "$PROMETHEUS_METRICS" ]; then
    success "Prometheus is collecting metrics"
    
    # Count targets
    TARGET_COUNT=$(curl -s http://localhost:9091/api/v1/targets | grep -o '"endpoint":"[^"]*"' | wc -l)
    info "Prometheus is monitoring $TARGET_COUNT target(s)"
else
    error "Prometheus is not collecting metrics"
    info "Check Prometheus configuration and targets"
fi

# Test Nginx authentication for Prometheus
echo "Testing Prometheus authentication via Nginx..."
NGINX_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080)

if [ "$NGINX_RESPONSE" = "401" ]; then
    success "Prometheus authentication is working correctly"
else
    warning "Prometheus authentication might not be configured correctly (HTTP $NGINX_RESPONSE)"
    info "Expected 401 Unauthorized response without credentials"
fi

# Test Grafana API
echo ""
echo "Testing Grafana API..."
GRAFANA_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health)

if [ "$GRAFANA_RESPONSE" = "200" ] || [ "$GRAFANA_RESPONSE" = "401" ]; then
    success "Grafana API is responding"
else
    error "Grafana API is not responding correctly (HTTP $GRAFANA_RESPONSE)"
    info "Check if Grafana is running on port 3000"
fi

# Check Grafana datasources
echo "Checking Grafana data sources..."
if [ -f "/data/grafana/provisioning/datasources/prometheus.yaml" ]; then
    success "Grafana Prometheus datasource configuration exists"
else
    warning "Grafana Prometheus datasource configuration not found"
    info "Check if datasources are configured through the UI instead"
fi

# Check Grafana dashboards
echo "Checking Grafana dashboards..."
if [ -f "/data/grafana/dashboards/node-exporter-dashboard.json" ]; then
    success "Grafana dashboard configuration exists"
else
    warning "Grafana dashboard configuration not found"
    info "Check if dashboards are configured through the UI instead"
fi

# Check persistent storage
echo ""
echo "Checking persistent storage..."
if [ -d "/data/prometheus" ]; then
    PROMETHEUS_DATA_SIZE=$(du -sh /data/prometheus | cut -f1)
    success "Prometheus data directory exists (Size: $PROMETHEUS_DATA_SIZE)"
else
    error "Prometheus data directory not found"
    info "Check if persistent storage is configured correctly"
fi

if [ -d "/data/grafana" ]; then
    GRAFANA_DATA_SIZE=$(du -sh /data/grafana | cut -f1)
    success "Grafana data directory exists (Size: $GRAFANA_DATA_SIZE)"
else
    error "Grafana data directory not found"
    info "Check if persistent storage is configured correctly"
fi

# Get public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unknown")

# Summary
echo ""
echo "=== Monitoring System Summary ==="
echo "Public IP: $PUBLIC_IP"
echo "Prometheus URL: http://$PUBLIC_IP:8080"
echo "Grafana URL: http://$PUBLIC_IP:3000"
echo ""
echo "To access Prometheus:"
echo "  Username: admin"
echo "  Password: secure_prometheus_password (or your custom password)"
echo ""
echo "To access Grafana:"
echo "  Username: admin"
echo "  Password: admin (you'll be prompted to change this on first login)"
echo ""
echo "If you've changed the default passwords, use your custom credentials."
echo "=== Test Complete ==="

exit 0