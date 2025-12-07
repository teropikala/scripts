#!/usr/bin/env bash
set -euo pipefail

### CONFIGURATION (EDIT THESE) ########################################

# NFS share with your Zigbee2MQTT backup/config
NFS_SERVER="192.168.1.34"
NFS_EXPORT="/mnt/pool1/backup/zigbee2mqtt"    # remote path on NFS server
NFS_MOUNT="/mnt/zigbee2mqtt-backup"       # local temporary mount point

# Where Zigbee2MQTT will live on this Pi
Z2M_DIR="/opt/zigbee2mqtt"                # Zigbee2MQTT install dir
Z2M_USER="zigbee2mqtt"                    # system user to run service


#######################################################################

echo "=== Updating system and installing dependencies ==="
sudo apt-get update
sudo apt-get -y upgrade

echo "=== Installing build tools, Node.js (LTS via NodeSource), git, NFS client ==="
# Basic tools + NFS
sudo apt-get install -y \
  build-essential \
  python3 \
  python3-pip \
  make \
  gcc \
  g++ \
  nfs-common \
  curl \
  git \
  libsystemd-dev

# Install Node.js LTS from NodeSource (works on Ubuntu on RPi)
# Adjust version (e.g. 20.x) if needed, Zigbee2MQTT supports recent LTS versions.
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

echo "Node version: $(node -v)"
echo "npm version: $(npm -v)"

echo "=== Creating Zigbee2MQTT system user ==="
if ! id "$Z2M_USER" >/dev/null 2>&1; then
  sudo useradd -r -s /usr/sbin/nologin -d "$Z2M_DIR" "$Z2M_USER"
fi

echo "=== Creating directories ==="
sudo mkdir -p "$Z2M_DIR"
sudo mkdir -p "$NFS_MOUNT"

echo "=== Cloning Zigbee2MQTT (if not already present) ==="
sudo git config --global --add safe.directory /opt/zigbee2mqtt
if [ ! -d "$Z2M_DIR/.git" ]; then
  sudo git clone --depth 1 https://github.com/Koenkk/zigbee2mqtt.git "$Z2M_DIR"
else
  echo "Zigbee2MQTT already cloned, pulling latest changes."
  cd "$Z2M_DIR"
  sudo git reset --hard
  sudo git clean -fdx
  sudo git pull
fi

echo "=== Setting ownership of Zigbee2MQTT directory ==="
sudo chown -R "$Z2M_USER":"$Z2M_USER" "$Z2M_DIR"

echo "=== Installing Zigbee2MQTT dependencies (this may take a while) ==="
cd "$Z2M_DIR"
sudo corepack enable
sudo -u "$Z2M_USER" \
  COREPACK_ENABLE_STRICT=0 \
  COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  pnpm install --frozen-lockfile

echo "=== Mounting NFS share for configuration restore ==="
if mountpoint -q "$NFS_MOUNT"; then
  echo "NFS mountpoint $NFS_MOUNT is already mounted, skipping mount."
else
  sudo mount -t nfs "$NFS_SERVER:$NFS_EXPORT" "$NFS_MOUNT"
fi

echo "=== Restoring Zigbee2MQTT configuration from NFS ==="
# Expecting configuration.yaml and possibly data/ directory in the NFS share.
# This copies everything from the NFS backup into the Zigbee2MQTT data dir.

# Zigbee2MQTT by default uses $Z2M_DIR/data for configuration.yaml, etc.
sudo mkdir -p "$Z2M_DIR/data"
latest_backup=$(ls -1t "$NFS_MOUNT"/zigbee2mqtt-*.tar.gz 2>/dev/null | head -n 1)

if [[ -z "${latest_backup}" ]]; then
    echo "No zigbee2mqtt-*.tar.gz backups found in $NFS_MOUNT" >&2
    exit 1
fi

echo "Latest backup: $latest_backup"
echo "Extracting to: $Z2M_DIR/data"

sudo rm -rf "$Z2M_DIR/data"/*
sudo -u "$Z2M_USER" mkdir -p "$Z2M_DIR/data"

sudo -u "$Z2M_USER" tar -xzf "$latest_backup" -C "$Z2M_DIR/data"

echo "Extraction complete."

echo "=== Unmounting NFS share ==="
sudo umount "$NFS_MOUNT"


echo "=== Setting final ownership and permissions ==="
sudo chown -R "$Z2M_USER":"$Z2M_USER" "$Z2M_DIR"
sudo chmod -R 755 "$Z2M_DIR"

echo "=== Creating systemd service for Zigbee2MQTT ==="
SERVICE_FILE="/etc/systemd/system/zigbee2mqtt.service"

sudo bash -c "cat > '$SERVICE_FILE'" <<EOF
[Unit]
Description=Zigbee2MQTT
# Start only after basic network is up
After=network.target

[Service]
########################################################
# ENVIRONMENT & RUNTIME MODE
########################################################
# Run in production mode (enables optimizations)
Environment=NODE_ENV=production
# Limit Node.js memory usage (useful on low-RAM devices)
Environment=NODE_OPTIONS=--max_old_space_size=256

########################################################
# USER / GROUP / PERMISSIONS
########################################################
User=$Z2M_USER
Group=$Z2M_USER

########################################################
# WORKING DIRECTORY
########################################################
WorkingDirectory=$Z2M_DIR

########################################################
# EXECUTION COMMAND
########################################################
ExecStart=/usr/bin/node index.js

########################################################
# OUTPUT / LOGGING
########################################################
# Forward stdout to systemd/journal (visible via journalctl)
StandardOutput=inherit
StandardError=inherit

########################################################
# SERVICE TYPE & WATCHDOG
########################################################
# Expect sd_notify() from Zigbee2MQTT for readiness (if supported)
Type=notify
# Systemd watchdog: restart if no notification within 10 seconds
WatchdogSec=10s

########################################################
# RESTART POLICY
########################################################
Restart=always
RestartSec=10s

[Install]
# Start automatically in normal multi-user (non-graphical) mode
WantedBy=multi-user.target
EOF

echo "=== Reloading systemd and enabling Zigbee2MQTT service ==="
sudo systemctl daemon-reload
sudo systemctl enable zigbee2mqtt.service
sudo systemctl start zigbee2mqtt.service

echo "=== Create backup script ==="
sudo bash -c "cat > '/usr/local/bin/backup_z2m.sh'" <<EOF
#!/bin/bash
set -e

NFS_SERVER="$NFS_SERVER"
NFS_EXPORT="$NFS_EXPORT"
NFS_MOUNT="$NFS_MOUNT"

Z2M_DATA=$Z2M_DIR/data
TIMESTAMP=\$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="${NFS_MOUNT}/zigbee2mqtt-\${TIMESTAMP}.tar.gz"
RETENTION_DAYS=14

# Ensure NFS is mounted
mkdir -p "$NFS_MOUNT"
if mountpoint -q "\$NFS_MOUNT"; then
  echo "NFS mountpoint \$NFS_MOUNT is already mounted, skipping mount."
else
  mount -t nfs "\$NFS_SERVER:\$NFS_EXPORT" "\$NFS_MOUNT"
fi

# Stop Zigbee2MQTT for a consistent backup
systemctl stop zigbee2mqtt

# Create archive
tar -czf "\$BACKUP_FILE" -C "\$Z2M_DATA" .

# Start Zigbee2MQTT
systemctl start zigbee2mqtt

# Cleanup old backups
find "\$NFS_MOUNT" -type f -name "zigbee2mqtt-*.tar.gz" -mtime +\$RETENTION_DAYS -delete

umount "\$NFS_MOUNT"

EOF

echo "=== Schedule daily backup at 2:30am ==="
# Cron entry 
CRON_ENTRY='30 2 * * * /usr/local/bin/backup_z2m.sh >/var/log/backup_z2m.log 2>&1'

# Check if the exact line already exists in the user's crontab
# (using grep -F for a fixed-string match)
if sudo crontab -u root -l 2>/dev/null | grep -Fq "$CRON_ENTRY"; then
    # Already present; nothing to do
    exit 0
fi

# Add the entry:
# - crontab -l 2>/dev/null prints existing crontab if any
# - echo "$CRON_ENTRY" adds the new line
# - crontab - installs the combined crontab
{
    sudo crontab -u root -l 2>/dev/null
    echo "$CRON_ENTRY"
} | sudo crontab -u root -


echo "=== Zigbee2MQTT installation complete ==="
echo "Check service status: sudo systemctl status zigbee2mqtt"
echo "Check logs:          journalctl -u zigbee2mqtt -f"
echo "If web UI is enabled in configuration.yaml, open: http://<this-pi-ip>:8080"

echo "=== Zigbee2MQTT installation complete ==="
echo "Check service status: sudo systemctl status zigbee2mqtt"
echo "Check logs:          journalctl -u zigbee2mqtt -f"
echo "If web UI is enabled in configuration.yaml, open: http://<this-pi-ip>:8080"
