#!/usr/bin/env bash
set -euo pipefail

# Check for available passport appointment slots at Finnish Embassy in UK.
#
# Environment Variables:
#  FIN_APPT_USER: Username for https://finlandappointment.fi/
#  FIN_APPT_PASS: Password for https://finlandappointment.fi/
#  CLICKSEND_USER: Username for sending SMS messages via ClickSend
#  CLICKSEND_KEY: Authentication key for ClickSend
#  CLICKSEND_TO: Phone number to send messages to.
#  DEBUG: Set to 1 to print debugging output
#  CURL_VERBOSE: Set to 1 to display curl output (very verbose!)
#
# Usage:
#  FIN_APPT_USER="..." FIN_APPT_PASS="..." CLICKSEND_USER="..." CLICKSEND_KEY="..." CLICKSEND_TO="..." ./available-embassy-appointment-checker.sh
#
# NOTE: Please do not run this too frequently (e.g., more than once every 15-30 minutes)
# to be respectful to the service and avoid having your username or IP address blocked.

USER="${FIN_APPT_USER:-}"
PASS="${FIN_APPT_PASS:-}"
CLICKSEND_USER="${CLICKSEND_USER:-}"
CLICKSEND_KEY="${CLICKSEND_KEY:-}"
CLICKSEND_TO="${CLICKSEND_TO:-}"
COOKIE_JAR="${FIN_APPT_COOKIE_JAR:-/tmp/finlandappointment.cookies.txt}"

DEBUG="${DEBUG:-0}"
CURL_VERBOSE="${CURL_VERBOSE:-0}"

if [[ -z "$USER" || -z "$PASS" ]]; then
  echo "ERROR: Set FIN_APPT_USER and FIN_APPT_PASS environment variables." >&2
  exit 2
fi

if [[ -z "$CLICKSEND_USER" || -z "$CLICKSEND_KEY" || -z "$CLICKSEND_TO" ]]; then
  echo "ERROR: Set CLICKSEND_USER, CLICKSEND_KEY and CLICKSEND_TO environment variables." >&2
  exit 2
fi

command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 2; }
command -v jq   >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

BASE_URL="https://finlandappointment.fi"
AFTER_LOGIN_URL="${BASE_URL}/?country=GB&lang=en&servicetype=passportid"
BOOKING_URL="${BASE_URL}/booking?country=GB&lang=en&servicetype=passportid"
SLOTS_URL="${BASE_URL}/api/customer/servicelocation/8/freeslot?service=PASSPORT_OR_ID_CARD&participantCount=1"

ts() {
  # Portable timestamp (macOS + Linux)
  date "+%Y-%m-%dT%H:%M:%S%z"
}

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    printf '[%s] %s\n' "$(ts)" "$*" >&2
  fi
}

send_sms() {
  local message="$1"
  debug "Sending SMS to $CLICKSEND_TO: $message"

  local payload
  payload="$(jq -n --arg body "$message" --arg to "$CLICKSEND_TO" '{messages: [{body: $body, to: $to}]}')"

  local response
  response="$(curl -sS -u "${CLICKSEND_USER}:${CLICKSEND_KEY}" \
    -H "Content-Type: application/json" \
    -X POST "https://rest.clicksend.com/v3/sms/send" \
    -d "$payload")"

  if echo "$response" | jq -e '.response_code == "SUCCESS"' >/dev/null; then
    debug "SMS sent successfully."
  else
    echo "ERROR: Failed to send SMS via ClickSend: $response" >&2
  fi
}


curl_common=(
  -sS
  -c "$COOKIE_JAR" -b "$COOKIE_JAR"
  -A "Mozilla/5.0"
)

if [[ "$CURL_VERBOSE" == "1" ]]; then
  curl_common=(-v "${curl_common[@]}")
fi

rm -f "$COOKIE_JAR"
touch "$COOKIE_JAR"

debug "COOKIE_JAR=$COOKIE_JAR"
debug "AFTER_LOGIN_URL=$AFTER_LOGIN_URL"
debug "BOOKING_URL=$BOOKING_URL"
debug "SLOTS_URL=$SLOTS_URL"

# Step A: Start on finlandappointment and trigger OIDC flow
debug "Step A: Triggering OIDC flow via /api/customer/login/finlandvisa"
A_HEADERS="$(curl "${curl_common[@]}" -D - -o /dev/null "https://finlandappointment.fi/api/customer/login/finlandvisa" || true)"

# The above returns a 302 to auth.*.fi/oauth2/authorize
AUTH_AUTHORIZE_URL="$(echo "$A_HEADERS" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tail -n1)"

if [[ -z "${AUTH_AUTHORIZE_URL:-}" ]]; then
  echo "ERROR: Could not get authorize URL from /api/customer/login/finlandvisa" >&2
  exit 1
fi

debug "Following authorize URL: $AUTH_AUTHORIZE_URL"
B_HEADERS="$(curl "${curl_common[@]}" -D - -o /dev/null "$AUTH_AUTHORIZE_URL" || true)"

LOGIN_URL="$(echo "$B_HEADERS" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tail -n1)"

# If LOGIN_URL is relative, we need to prepend the host
if [[ "$LOGIN_URL" == /* ]]; then
  AUTH_HOST="$(echo "$AUTH_AUTHORIZE_URL" | grep -oE 'https://[^/]+' | head -n1)"
  LOGIN_URL="${AUTH_HOST}${LOGIN_URL}"
fi

if [[ -z "${LOGIN_URL:-}" ]]; then
  echo "ERROR: Could not discover auth login redirect URL." >&2
  exit 1
fi

debug "Discovered LOGIN_URL=$LOGIN_URL"

# Step C: Fetch the login page
debug "Step C: Fetching login page HTML"
C_TEMP_FILE="$(mktemp)"
C_HEADERS="$(curl "${curl_common[@]}" -D - "$LOGIN_URL" -o "$C_TEMP_FILE" || true)"

# Extract form action (Cognito uses a POST to /login with query params)
FORM_ACTION="$(grep -oE '<form action="[^"]+"' "$C_TEMP_FILE" | head -n1 | sed -E 's/<form action="([^"]+)"/\1/' | sed 's/&amp;/\&/g' | tr -d '\r\n' || true)"

if [[ -z "$FORM_ACTION" ]]; then
  LOGIN_POST_URL="$LOGIN_URL"
elif [[ "$FORM_ACTION" == http* ]]; then
  LOGIN_POST_URL="$FORM_ACTION"
else
  AUTH_HOST="$(echo "$LOGIN_URL" | grep -oE 'https://[^/]+' | head -n1)"
  LOGIN_POST_URL="${AUTH_HOST}${FORM_ACTION}"
fi

# URL encode spaces and remove all newlines/carriage returns
LOGIN_POST_URL="$(echo "$LOGIN_POST_URL" | sed 's/ /%20/g' | tr -d '\r\n')"

debug "LOGIN_POST_URL=$LOGIN_POST_URL"

# Extract CSRF token
CSRF_TOKEN="$(grep -oE 'name="_csrf" value="[^"]+"' "$C_TEMP_FILE" | head -n1 | sed -E 's/.*value="([^"]+)".*/\1/' || true)"
rm -f "$C_TEMP_FILE"
if [[ -n "$CSRF_TOKEN" ]]; then
  debug "Extracted CSRF token (length=${#CSRF_TOKEN})"
fi

# Step D: Post credentials
debug "Step D: Posting credentials to LOGIN_POST_URL"
POST_DATA=(
  --data-urlencode "username=${USER}"
  --data-urlencode "password=${PASS}"
  --data-urlencode "signInSubmitButton=Sign in"
)
if [[ -n "$CSRF_TOKEN" ]]; then
  POST_DATA+=( --data-urlencode "_csrf=${CSRF_TOKEN}" )
fi

D_HEADERS="$(curl "${curl_common[@]}" -L -D - \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -X POST "${POST_DATA[@]}" \
  "$LOGIN_POST_URL" \
  -o /dev/null || true)"

# Step E: Visit the final destination to ensure all site cookies are established
debug "Step E: Visiting $AFTER_LOGIN_URL"
E_HEADERS="$(curl "${curl_common[@]}" -L -D - "$AFTER_LOGIN_URL" -o /dev/null || true)"

# Step F: Call the freeslot API
debug "Step F: Calling slots API"
F_HEADERS="$(curl "${curl_common[@]}" -L -D - \
  -H "Accept: application/json" \
  "$SLOTS_URL" || true)"
SLOTS_JSON="$(echo "$F_HEADERS" | sed '1,/^\r\{0,1\}$/d')"

if [[ "$DEBUG" == "1" ]]; then
  debug "Slots API response status line: $(echo "$F_HEADERS" | head -n1 | tr -d '\r')"
  debug "Slots API response body: $SLOTS_JSON"
fi

# Validate JSON
if ! echo "$SLOTS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: API did not return valid JSON (likely not authenticated)." >&2
  exit 1
fi

if [[ "$(echo "$SLOTS_JSON" | jq 'length')" -gt 0 ]]; then
  echo "Slots available; SMS notification will be sent"
  send_sms "Passport appointment slots available!"
else
  echo "No slots available"
fi