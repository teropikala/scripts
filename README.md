# Zigbee2MQTT 

This script turns a fresh Raspberry Pi into a disaster recovery Zigbee2MQTT node using existing NFS-based backups. It installs all dependencies, clones Zigbee2MQTT, restores the latest backup archive from NFS share, and creates a systemd service so Zigbee2MQTT runs automatically on boot. 

It also installs a daily backup job that stops Zigbee2MQTT, archives `/opt/zigbee2mqtt/data` to NFS, then restarts the service.

Usage:

`bash -c "$(curl -fsSL https://raw.githubusercontent.com/teropikala/scripts/refs/heads/main/setup-zigbee2mqtt.sh)"`

