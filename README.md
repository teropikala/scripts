# scripts
Setup scripts for personal use. 



# Zigbee2MQTT 

Configure Rasberry Pi with Zigbee2MQTT and restore latest backups

bash -c "$(curl -fsSL https://raw.githubusercontent.com/teropikala/scripts/refs/heads/main/setup-zigbee2mqtt.sh)"

30 2 * * * /usr/local/bin/backup_z2m.sh >/var/log/backup_z2m.log 2>&1





