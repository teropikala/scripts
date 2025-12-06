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

# Device for your Zigbee adapter (check with `ls /dev/serial/by-id/`)
Z2M_SERIAL_DEVICE="/dev/serial/by-id/usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0"

# Timezone (optional)
TZ="Etc/UTC"

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

echo "=== Adjusting configuration for this host (serial, timezone) ==="
# Optional: patch configuration.yaml to ensure the correct serial port, etc.
# This assumes your configuration.yaml already exists in data/.
# You can comment this section out if you manage these values manually.

CONFIG_FILE="$Z2M_DIR/data/configuration.yaml"

if [ -f "$CONFIG_FILE" ]; then
  # Ensure serial port is set correctly.
  # This is a naive replace; adjust regex if your file structure differs.
  sudo sed -i "s|^  port: .*|  port: ${Z2M_SERIAL_DEVICE}|g" "$CONFIG_FILE" || true

  # Timezone is usually configured via OS, but if you use it in config, you can patch here.
  # Example (commented out):
  # sudo sed -i "s|^timezone: .*|timezone: ${TZ}|g" "$CONFIG_FILE" || true
else
  echo "WARNING: $CONFIG_FILE not found. You may need to create/adjust it manually."
fi

echo "=== Setting final ownership and permissions ==="
sudo chown -R "$Z2M_USER":"$Z2M_USER" "$Z2M_DIR"
sudo chmod -R 755 "$Z2M_DIR"

echo "**** EXIT HERE ***"
exit

echo "=== Creating systemd service for Zigbee2MQTT ==="
SERVICE_FILE="/etc/systemd/system/zigbee2mqtt.service"

sudo bash -c "cat > '$SERVICE_FILE'" <<EOF
[Unit]
Description=Zigbee2MQTT
After=network.target

[Service]
User=$Z2M_USER
Group=$Z2M_USER
WorkingDirectory=$Z2M_DIR
ExecStart=/usr/bin/npm start
Environment=TZ=$TZ
# Ensure Node does not run out of memory on low-RAM devices
Environment=NODE_OPTIONS=--max_old_space_size=256
Restart=on-failure
RestartSec=10
# Give access to the Zigbee adapter
# (device permissions are usually handled via udev; see notes below)

[Install]
WantedBy=multi-user.target
EOF

echo "=== Reloading systemd and enabling Zigbee2MQTT service ==="
sudo systemctl daemon-reload
sudo systemctl enable zigbee2mqtt.service
sudo systemctl start zigbee2mqtt.service

echo "=== Zigbee2MQTT installation complete ==="
echo "Check service status: sudo systemctl status zigbee2mqtt"
echo "Check logs:          journalctl -u zigbee2mqtt -f"
echo "If web UI is enabled in configuration.yaml, open: http://<this-pi-ip>:8080"
