#!/bin/bash
# twitch_check.sh
# Usage: ./twitch_check.sh <streamer_name>

STREAMER="$1"
CLIENT_ID="Enter Twitch client id"
CLIENT_SECRET="Enter Twitch Secret"
TOKEN_FILE="/tmp/twitch_token.json"
FLAG_FILE="/tmp/${STREAMER}_live.flag"
WEBHOOK_URL="Paste full discord webhook url"

if [ -z "$STREAMER" ]; then
    echo "Usage: $0 <streamer_name>"
    exit 1
fi
# create new twitch.tv token in TOKEN_FILE
get_token() {
    curl -s -X POST "https://id.twitch.tv/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&grant_type=client_credentials" \
        > "$TOKEN_FILE"
}

if [ ! -f "$TOKEN_FILE" ]; then
    get_tokenz
fi

# variable declaration
ACCESS_TOKEN=$(jq -r '.access_token' "$TOKEN_FILE" 2>/dev/null)
EXPIRES_IN=$(jq -r '.expires_in' "$TOKEN_FILE" 2>/dev/null)
OBTAINED_AT=$(stat -c %Y "$TOKEN_FILE" 2>/dev/null)
NOW=$(date +%s)

# check if token is already expired, run get_token()
if [ -z "$ACCESS_TOKEN" ] || [ $((NOW - OBTAINED_AT)) -ge "$EXPIRES_IN" ]; then
    get_token
    ACCESS_TOKEN=$(jq -r '.access_token' "$TOKEN_FILE")
fi

RESPONSE=$(curl -s -H "Client-ID: $CLIENT_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.twitch.tv/helix/streams?user_login=$STREAMER")

# building the payload
IS_LIVE=$(echo "$RESPONSE" | jq -r '.data[0].type')
TITLE=$(echo "$RESPONSE" | jq -r '.data[0].title')
GAME=$(echo "$RESPONSE" | jq -r '.data[0].game_name')
URL="https://twitch.tv/$STREAMER"
THUMBNAIL=$(echo "$RESPONSE" | jq -r '.data[0].thumbnail_url' | sed "s/{width}/1280/; s/{height}/720/")

# check if streamer $1 is live
if [ "$IS_LIVE" == "live" ]; then
    echo "$STREAMER is LIVE: $TITLE ($GAME)"
    # Only send webhook if not already sent
    if [ ! -f "$FLAG_FILE" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
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
            }" \
            # discarding output
            "$WEBHOOK_URL" >/dev/null
        # Create the flag file after sending the webhook
        touch "$FLAG_FILE"
    fi

    # exit success
    exit 0
else
    echo "$STREAMER is OFFLINE"
    # Remove the flag so next live session triggers a new webhook
    [ -f "$FLAG_FILE" ] && rm "$FLAG_FILE"
    
    # exit failure
    exit 1
fi
