# Prometheus and Grafana Deployment Guide

This guide provides detailed instructions for deploying Prometheus and Grafana on an Amazon Linux 2023 EC2 instance using containerd.

## Prerequisites

### EC2 Instance Requirements

1. **Instance Type**: 
   - Minimum: t3.medium (2 vCPU, 4GB RAM)
   - Recommended for production: t3.large or better

2. **Storage**:
   - Root volume: At least 20GB for OS and container images
   - Additional EBS volume: 50GB+ for persistent storage (recommended)

3. **Operating System**:
   - Amazon Linux 2023 AMI

### Security Group Configuration

Create a security group with the following inbound rules:

| Type        | Protocol | Port Range | Source                      | Description                |
|-------------|----------|------------|-----------------------------|-----------------------------|
| SSH         | TCP      | 22         | Your IP address or range    | SSH access                  |
| Custom TCP  | TCP      | 8080       | Your IP address or range    | Prometheus web interface    |
| Custom TCP  | TCP      | 3000       | Your IP address or range    | Grafana web interface       |

For production environments, consider restricting access to specific IP ranges or using a VPN/bastion host.

## Deployment Steps

### 1. Launch EC2 Instance

1. Log in to the AWS Management Console
2. Navigate to EC2 service
3. Click "Launch Instance"
4. Choose "Amazon Linux 2023" as the AMI
5. Select instance type (t3.medium or better)
6. Configure instance details as needed
7. Add storage:
   - Root volume: 20GB gp3
   - Add an additional EBS volume (50GB+ gp3) for persistent data
8. Add tags as needed
9. Configure the security group as described above
10. Launch the instance with your key pair

### 2. Connect to the EC2 Instance

```bash
ssh -i your-key.pem ec2-user@your-instance-public-ip
```

### 3. Prepare the Instance

1. Update the system:
   ```bash
   sudo dnf update -y
   ```

2. Format and mount the additional EBS volume (if added):
   ```bash
   # Find the device name
   lsblk
   
   # Format the volume (assuming it's /dev/xvdf)
   sudo mkfs -t xfs /dev/xvdf
   
   # Create mount point
   sudo mkdir -p /data
   
   # Mount the volume
   sudo mount /dev/xvdf /data
   
   # Make it persistent
   echo '/dev/xvdf /data xfs defaults,nofail 0 2' | sudo tee -a /etc/fstab
   ```

### 4. Transfer Files to the EC2 Instance

#### Option 1: Using SCP

From your local machine:

```bash
scp -i your-key.pem README.md deploy.sh ec2-user@your-instance-public-ip:~
```

#### Option 2: Using Git

On the EC2 instance:

```bash
# Install git
sudo dnf install -y git

# Clone the repository
git clone https://github.com/zhang1980s/prometheus-lab.git
cd prometheus-lab
```

#### Option 3: Create Files Directly

On the EC2 instance:

```bash
# Create deploy.sh
nano deploy.sh
# Paste the script content and save (Ctrl+O, Enter, Ctrl+X)

# Make it executable
chmod +x deploy.sh
```

### 5. Run the Deployment Script

```bash
sudo ./deploy.sh
```

The script will:
- Install and configure containerd
- Set up Prometheus and Grafana with persistent storage
- Configure basic authentication via containerized Nginx
- Deploy containers for Prometheus, Grafana, Node Exporter, and Nginx
- Configure Nginx for multi-CPU support
- Create a basic dashboard for system metrics
- Display access information when complete

### 6. Access the Services

After successful deployment, you can access:

- **Prometheus**: http://your-instance-public-ip:8080
  - Username: admin
  - Password: secure_prometheus_password

- **Grafana**: http://your-instance-public-ip:3000
  - Username: admin
  - Password: admin (you'll be prompted to change this on first login)

## Post-Deployment Configuration

### 1. Change Default Passwords

#### For Prometheus:

```bash
sudo htpasswd -c /data/nginx/.htpasswd admin
sudo ctr -n monitoring task kill --signal 9 nginx
sudo ctr -n monitoring task start nginx
```

#### For Grafana:

When you first log in to Grafana with the default credentials (admin/admin), you'll be automatically prompted to change your password. This is a security feature of Grafana to ensure you don't continue using the default password.

After setting your new password, you'll be logged in and can start using Grafana.

### 2. Add Target EC2 Instances for Monitoring

1. Install Node Exporter on each target instance:
   ```bash
   # On each target instance
   sudo dnf install -y wget
   wget https://github.com/prometheus/node_exporter/releases/download/v1.5.0/node_exporter-1.5.0.linux-amd64.tar.gz
   tar xvfz node_exporter-1.5.0.linux-amd64.tar.gz
   cd node_exporter-1.5.0.linux-amd64
   sudo cp node_exporter /usr/local/bin/
   
   # Create systemd service
   sudo tee /etc/systemd/system/node_exporter.service > /dev/null << EOF
   [Unit]
   Description=Node Exporter
   After=network.target
   
   [Service]
   Type=simple
   User=nobody
   ExecStart=/usr/local/bin/node_exporter
   
   [Install]
   WantedBy=multi-user.target
   EOF
   
   # Start and enable the service
   sudo systemctl daemon-reload
   sudo systemctl start node_exporter
   sudo systemctl enable node_exporter
   ```

2. Update Prometheus configuration on the main instance:
   ```bash
   sudo nano /etc/prometheus/prometheus.yml
   ```

3. Add the target instances to the `node` job:
   ```yaml
   - job_name: 'node'
     static_configs:
       - targets: ['localhost:9100']
       - targets: ['target-instance-1:9100']
       - targets: ['target-instance-2:9100']
   ```

4. Restart Prometheus container:
   ```bash
   sudo ctr -n monitoring task kill --signal 9 prometheus
   sudo ctr -n monitoring task start prometheus
   ```

### 3. Create Additional Dashboards

1. Log in to Grafana
2. Click "+ Create" > "Dashboard"
3. Click "+ Add visualization"
4. Select "Prometheus" as the data source
5. Create panels as needed

Alternatively, import community dashboards:
1. Go to "+" > "Import"
2. Enter a dashboard ID (e.g., 1860 for Node Exporter Full)
3. Click "Load"
4. Select "Prometheus" as the data source
5. Click "Import"

## Troubleshooting

### Common Issues

#### 1. Services Not Starting

Check the status of containerd:
```bash
sudo systemctl status containerd
```

Check container status:
```bash
sudo ctr -n monitoring container ls
```

#### 2. Cannot Access Prometheus/Grafana

Check if Nginx container is running:
```bash
sudo ctr -n monitoring task ls | grep nginx
```

Check firewall status:
```bash
sudo systemctl status firewalld
```

#### 3. No Metrics in Prometheus

Check if Node Exporter is running:
```bash
curl http://localhost:9100/metrics
```

Check Prometheus targets:
1. Access Prometheus web interface
2. Go to Status > Targets
3. Check for any errors

#### 4. Deployment Script Errors

Check the log file:
```bash
sudo cat /var/log/prometheus-grafana-deploy.log
```

## Maintenance

### Updating Containers

To update Prometheus:
```bash
sudo ctr -n monitoring image pull docker.io/prom/prometheus:latest
sudo ctr -n monitoring task kill --signal 9 prometheus
sudo ctr -n monitoring container rm prometheus
# Re-run the container creation command from deploy.sh
```

To update Grafana:
```bash
sudo ctr -n monitoring image pull docker.io/grafana/grafana:latest
sudo ctr -n monitoring task kill --signal 9 grafana
sudo ctr -n monitoring container rm grafana
# Re-run the container creation command from deploy.sh
```

To update Nginx:
```bash
sudo ctr -n monitoring image pull docker.io/nginx:latest
sudo ctr -n monitoring task kill --signal 9 nginx
sudo ctr -n monitoring container rm nginx
# Re-run the container creation command from deploy.sh
```

### Backing Up Data

Backup Prometheus data:
```bash
sudo tar -czvf prometheus-backup.tar.gz /data/prometheus
```

Backup Grafana data:
```bash
sudo tar -czvf grafana-backup.tar.gz /data/grafana
```

## Security Considerations

For production environments, consider:

1. Implementing HTTPS/TLS for both Prometheus and Grafana
2. Using more complex authentication mechanisms
3. Setting up proper network segmentation
4. Implementing regular security updates
5. Setting up monitoring for the monitoring system itself

## Additional Resources

- [Prometheus Documentation](https://prometheus.io/docs/introduction/overview/)
- [Grafana Documentation](https://grafana.com/docs/)
- [containerd Documentation](https://containerd.io/docs/)
- [Node Exporter Documentation](https://github.com/prometheus/node_exporter)