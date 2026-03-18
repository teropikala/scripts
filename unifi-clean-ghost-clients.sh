#!/usr/bin/env bash
set -euo pipefail

################################################################################
#
# This script automatically cleans up “ghost” clients from a 
# UniFi Network deployment running on UniFi OS (CloudKey Gen2, UDM, etc.). 
#
# UniFi sometimes logs transient or spoofed MAC addresses—often caused 
# by Wi-Fi management frames—as wired clients, leaving clutter in the Clients view. 
#
# The script logs into the controller using the modern api/auth/login endpoint, 
# extracts the CSRF token from response headers, fetches the full client history, 
# and identifies ghost entries based on predictable characteristics (wired type, empty OUI, no IP). 
# Matching MAC addresses are then removed using the UniFi OS forget-sta API call. 
#
# The script supports dry-run mode and requires only curl and jq to operate.
#
################################################################################

########################################
# CONFIG – EDIT THESE
########################################

UNIFI_HOST="https://cloudkey.lan.pikala.com"
SITE="default"

# UniFi controller credentials
UNIFI_USER="xxx"
UNIFI_PASS="xxx"

HISTORY_ENDPOINT="/proxy/network/v2/api/site/${SITE}/clients/history?onlyNonBlocked=true&includeUnifiDevices=false&withinHours=0"

# 1 = dry run, 0 = actually forget
DRY_RUN=0

########################################

COOKIE_JAR="$(mktemp)"
HEADER_FILE="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$HEADER_FILE"' EXIT

########################################
# LOGIN (UniFi OS)
########################################
login() {
  echo "Logging in..."

  # This will set TOKEN cookie + csrf_token
  curl -sk -D "$HEADER_FILE" \
    -c "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${UNIFI_USER}\",\"password\":\"${UNIFI_PASS}\"}" \
    "${UNIFI_HOST}/api/auth/login" \
    > /dev/null

  # Try X-Csrf-Token first
  CSRF="$(grep -i '^X-Csrf-Token:' "$HEADER_FILE" | awk '{print $2}' | tr -d '\r')"

  # Fallback to X-Updated-Csrf-Token if needed
  if [[ -z "${CSRF}" ]]; then
    CSRF="$(grep -i '^X-Updated-Csrf-Token:' "$HEADER_FILE" | awk '{print $2}' | tr -d '\r')"
  fi

  if [[ -z "${CSRF}" ]]; then
    echo "ERROR: Could not extract CSRF token from headers:"
    cat "$HEADER_FILE"
    exit 1
  fi

}

########################################
# GET CLIENT HISTORY
########################################
get_history() {
  curl -sk -b "$COOKIE_JAR" "${UNIFI_HOST}${HISTORY_ENDPOINT}"
}

########################################
# FORGET CLIENT
########################################
forget_client() {
  local mac="$1"
  echo "  Forgetting ${mac} ..."

  curl -sk \
    -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "X-CSRF-Token: ${CSRF}" \
    -d "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac}\"]}" \
    "${UNIFI_HOST}/proxy/network/api/s/${SITE}/cmd/stamgr" \
    > /dev/null
}

########################################
# MAIN
########################################

login

echo "Fetching client history..."
JSON=$(get_history)

# Select ghost entries:
#  - type == "WIRED"
#  - is_wired == true
#  - empty oui
#  - no last_ip
#  - not noted
MACS=$(echo "$JSON" | jq -r '
  .[]
  | select(.type == "WIRED")
  | select(.is_wired == true)
  | select((.last_ip // "") == "")
  | select((.oui // "") == "")
  | select(.noted == false)
  | .mac
' | sort -u)

if [[ -z "$MACS" ]]; then
  echo "No ghost clients found."
  exit 0
fi

echo "Ghost clients found:"
echo "$MACS" | sed 's/^/  - /'

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "DRY_RUN=1 → Not deleting anything."
  exit 0
fi

echo
echo "Deleting ghost clients..."
while read -r mac; do
  [[ -n "$mac" ]] && forget_client "$mac"
done <<< "$MACS"

echo "Done."
