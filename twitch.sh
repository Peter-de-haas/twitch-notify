#!/bin/bash
# twitch_check.sh
# Usage: ./twitch_check.sh <streamer_name>
# Hardened version with logging, retries, and credential file
# Token/flag auto-cleanup included

set -euo pipefail
IFS=$'\n\t'

# ------------------------------
# CONFIG
# ------------------------------

STREAMER="$1"
CRED_FILE="/home/cronrunner/credentials/twitch-sh-credentials.conf"
LOG_FILE="$HOME/twitch_check.log"

# Temp files
TOKEN_FILE="/tmp/twitch_${STREAMER}_token.json"
FLAG_FILE="/tmp/${STREAMER}_live.flag"

# Cleanup config (seconds)
TOKEN_MAX_AGE=$((24*60*60)) # 24 hours
FLAG_MAX_AGE=$((48*60*60))  # 48 hours

# ------------------------------
# FUNCTIONS
# ------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

error_exit() {
    log "ERROR: $*"
    echo "ERROR: $*" >&2
    exit 1
}

retry_curl() {
    local url="$1"
    shift
    local retries=3
    local delay=2
    local attempt=1
    local response
    while [ $attempt -le $retries ]; do
        response=$(curl --fail -s "$@" "$url") && echo "$response" && return 0
        log "Curl attempt $attempt failed, retrying in $delay seconds..."
        sleep $delay
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
    error_exit "Curl failed after $retries attempts: $url"
}

get_token() {
    log "Requesting new Twitch token..."
    retry_curl "https://id.twitch.tv/oauth2/token" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&grant_type=client_credentials" \
        > "$TOKEN_FILE"
}

cleanup_old_files() {
    # Remove old token files
    if [ -f "$TOKEN_FILE" ] && [ $(( $(date +%s) - $(stat -c %Y "$TOKEN_FILE") )) -ge $TOKEN_MAX_AGE ]; then
        rm -f "$TOKEN_FILE"
        log "Old token file removed."
    fi
    # Remove old flag files
    if [ -f "$FLAG_FILE" ] && [ $(( $(date +%s) - $(stat -c %Y "$FLAG_FILE") )) -ge $FLAG_MAX_AGE ]; then
        rm -f "$FLAG_FILE"
        log "Old flag file removed."
    fi
}

# ------------------------------
# VALIDATION
# ------------------------------

if [ -z "${STREAMER}" ]; then
    echo "Usage: $0 <streamer_name>"
    exit 1
fi

if [ ! -f "$CRED_FILE" ]; then
    error_exit "Credential file not found: $CRED_FILE"
fi

source "$CRED_FILE"

: "${CLIENT_ID:?Missing CLIENT_ID in $CRED_FILE}"
: "${CLIENT_SECRET:?Missing CLIENT_SECRET in $CRED_FILE}"
: "${WEBHOOK_URL:?Missing WEBHOOK_URL in $CRED_FILE}"

# ------------------------------
# CLEANUP
# ------------------------------

cleanup_old_files

# ------------------------------
# TOKEN MANAGEMENT
# ------------------------------

if [ ! -f "$TOKEN_FILE" ]; then
    get_token
fi

ACCESS_TOKEN=$(jq -r '.access_token // empty' "$TOKEN_FILE")
EXPIRES_IN=$(jq -r '.expires_in // 0' "$TOKEN_FILE")
OBTAINED_AT=$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s)

if [ -z "$ACCESS_TOKEN" ] || [ $((NOW - OBTAINED_AT)) -ge "$EXPIRES_IN" ]; then
    get_token
    ACCESS_TOKEN=$(jq -r '.access_token // empty' "$TOKEN_FILE")
fi

# ------------------------------
# CALL TWITCH API
# ------------------------------

RESPONSE=$(retry_curl "https://api.twitch.tv/helix/streams?user_login=$STREAMER" \
    -H "Client-ID: $CLIENT_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN"
)

if ! echo "$RESPONSE" | jq -e '.data' >/dev/null 2>&1; then
    error_exit "Invalid Twitch API response: $RESPONSE"
fi

# ------------------------------
# PARSE STREAM DATA
# ------------------------------

IS_LIVE=$(echo "$RESPONSE" | jq -r '.data[0].type // empty')
TITLE=$(echo "$RESPONSE" | jq -r '.data[0].title // empty')
GAME=$(echo "$RESPONSE" | jq -r '.data[0].game_name // empty')
URL="https://twitch.tv/$STREAMER"
THUMBNAIL=$(echo "$RESPONSE" | jq -r '.data[0].thumbnail_url // empty' | sed "s/{width}/1280/; s/{height}/720/")

# ------------------------------
# LIVE / OFFLINE HANDLING
# ------------------------------

if [ "$IS_LIVE" = "live" ]; then
    log "$STREAMER is LIVE: $TITLE ($GAME)"

    if [ ! -f "$FLAG_FILE" ]; then
        retry_curl "$WEBHOOK_URL" \
            -X POST -H "Content-Type: application/json" \
            -d "{
                \"content\": \":skull: @everyone $STREAMER is actief aan het stromen op Twitch!\",
                \"embeds\": [
                    {
                        \"title\": \"$TITLE\",
                        \"description\": \"Spel: $GAME\n[Kijk hier]($URL)\",
                        \"color\": 16711680,
                        \"image\": { \"url\": \"$THUMBNAIL\" }
                    }
                ]
            }" >/dev/null

        touch "$FLAG_FILE"
        log "Webhook sent and flag file created."
    fi

    exit 0
else
    log "$STREAMER is OFFLINE"
    [ -f "$FLAG_FILE" ] && rm "$FLAG_FILE" && log "Flag file removed."
    exit 1
fi