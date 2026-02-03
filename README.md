# Collection of Helper Scripts

This repository contains various utility scripts for home automation and personal productivity.

## Scripts

### 1. Zigbee2MQTT Setup (`setup-zigbee2mqtt.sh`)

This script turns a fresh Raspberry Pi into a disaster recovery Zigbee2MQTT node using existing NFS-based backups. 

**Features:**
- Installs all dependencies (Node.js, pnpm, git, etc.).
- Clones Zigbee2MQTT.
- Restores the latest backup archive from an NFS share.
- Creates a `systemd` service for automatic startup.
- Installs a daily backup cron job.

**Usage:**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/teropikala/scripts/main/setup-zigbee2mqtt.sh)"
```

---

### 2. Embassy Appointment Checker (`available-embassy-appointment-checker.sh`)

Checks for available passport/ID card appointment slots at the Finnish Embassy in the UK and sends an SMS notification via ClickSend if a slot is found.

**Prerequisites:**
- `curl` and `jq` installed.
- ClickSend account for SMS notifications.
- Credentials for `finlandappointment.fi`.

**Environment Variables:**
- `FIN_APPT_USER`: Username for finlandappointment.fi
- `FIN_APPT_PASS`: Password for finlandappointment.fi
- `CLICKSEND_USER`: ClickSend username
- `CLICKSEND_KEY`: ClickSend API key
- `CLICKSEND_TO`: Destination phone number

**Usage:**
```bash
FIN_APPT_USER="..." FIN_APPT_PASS="..." CLICKSEND_USER="..." CLICKSEND_KEY="..." CLICKSEND_TO="..." ./available-embassy-appointment-checker.sh
```

---

## Maintenance

- [ ] Fix crontab update for backups in `setup-zigbee2mqtt.sh`