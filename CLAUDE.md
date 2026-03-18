# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A personal collection of bash automation scripts across four domains:
- **Embassy appointment tracking** — auth, polling, SMS alerts, and data logging for Finnish Embassy appointments
- **Zigbee2MQTT setup** — full Raspberry Pi deployment and backup/recovery automation
- **Web content analysis** — scraping and format extraction from sopimusmallit.com
- **UniFi network maintenance** — cleaning ghost/phantom clients from a UniFi controller

## Running Scripts

All bash scripts use `set -euo pipefail`. Run them directly:

```bash
# Embassy appointment checker (requires env vars)
FIN_APPT_USER=x FIN_APPT_PASS=x CLICKSEND_USER=x CLICKSEND_KEY=x CLICKSEND_TO=x \
  bash embassy-appointments/available-embassy-appointment-checker.sh

# Embassy appointment logger (requires FIN_APPT_USER, FIN_APPT_PASS)
FIN_APPT_USER=x FIN_APPT_PASS=x bash embassy-appointments/available-embassy-appointment-logger.sh

# Enable debug output with DEBUG=1
DEBUG=1 bash embassy-appointments/available-embassy-appointment-logger.sh

# Zigbee2MQTT setup (run on target Raspberry Pi, not locally)
bash setup-zigbee2mqtt.sh
```

## Python Data Processing

```bash
cd embassy-appointments
python3 -m venv venv && source venv/bin/activate
pip install pandas
python3 process_per_hour.py   # outputs output.csv aggregated by hour
python3 process_per_day.py    # outputs output.csv aggregated by day
```

Both scripts read `available-embassy-appointment-logger.csv` and produce pivot tables (rows = time units, columns = embassy locations) using `max()` aggregation.

## Architecture

### Embassy Appointment Flow

Both `available-embassy-appointment-checker.sh` and `available-embassy-appointment-logger.sh` implement the same OAuth2/OIDC auth flow against finlandappointment.fi (AWS Cognito):
1. Fetch login page → extract CSRF token
2. POST credentials → follow redirects → extract session cookies
3. Use session to call `/api/customer/servicelocation/{ID}/freeslotrange`

The **checker** targets one location (London, ID 8) and sends an SMS via ClickSend when slots are found. The **logger** polls 6 locations and appends results to `available-embassy-appointment-logger.csv`.

### Date Handling

Logger scripts use dynamic date ranges covering the next full calendar month. Both macOS (BSD `date`) and Linux (GNU `date`) are supported via conditional branches.

### Zigbee2MQTT Setup

`setup-zigbee2mqtt.sh` generates and installs:
- A systemd service unit (`/etc/systemd/system/zigbee2mqtt.service`)
- A backup script (`/usr/local/bin/backup_z2m.sh`) with NFS mount/unmount and 14-day retention
- A crontab entry for daily 2:30am backups

Key config at top of the file:
```bash
NFS_SERVER="192.168.1.34"
NFS_EXPORT="/mnt/pool1/backup/zigbee2mqtt"
```

### UniFi Ghost Client Cleanup

`unifi-clean-ghost-clients.sh` removes phantom wired clients that UniFi logs from transient/spoofed MAC addresses (typically Wi-Fi management frames). It:
1. Logs in via `/api/auth/login` and extracts the CSRF token from response headers
2. Fetches full client history via the v2 history API
3. Identifies ghosts: `type == "WIRED"`, empty OUI, no IP, not noted
4. Forgets matching MACs via the `forget-sta` stamgr command

Requires `curl` and `jq`. Set `DRY_RUN=1` to preview without deleting. Configure `UNIFI_HOST`, `UNIFI_USER`, and `UNIFI_PASS` at the top of the script.

### Web Scraping

`sopimusmallit.com/extract_formats.sh` operates on a **local wget mirror** of the site (not live HTTP requests). It searches for product pages and extracts document format support (DOCX, DOC, RTF, ODT) from HTML.
