#!/bin/bash
# Usage: send-slack-notification.sh <message>
# Sends a message to Slack via Incoming Webhook.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <message>"
  echo "Example: $0 'Remote Control URL: https://...'"
  exit 1
fi

MESSAGE="$1"
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

if [ -z "$WEBHOOK_URL" ]; then
  echo "[ERROR] SLACK_WEBHOOK_URL is not set."
  exit 1
fi

HOSTNAME=$(hostname)
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" "[$HOSTNAME] $MESSAGE")

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL")

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo "Slack notification sent successfully."
else
  echo "[ERROR] Slack notification failed (HTTP $HTTP_STATUS)."
  exit 1
fi
