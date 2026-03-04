#!/bin/bash
# Monitors Claude Code log file for Remote Control URL and sends it to Slack.
# Usage: monitor-urls.sh <log_dir> <session-name>

set -euo pipefail

LOG_DIR="${1:-$HOME/claude-logs}"
SESSION_NAME="${2:-claude}"
LOG_FILE="$LOG_DIR/$SESSION_NAME.log"
TIMEOUT=300  # 5 minutes
POLL_INTERVAL=5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Monitoring $SESSION_NAME for Remote Control URL (timeout: ${TIMEOUT}s)..."

START_TIME=$(date +%s)

while true; do
  if [ -f "$LOG_FILE" ]; then
    URL=$(grep -oP 'https://claude\.ai/code/[^\s"]+' "$LOG_FILE" 2>/dev/null | tail -1 || true)

    if [ -n "$URL" ]; then
      echo "[$(date)] $SESSION_NAME: Remote Control URL detected: $URL"
      "$SCRIPT_DIR/send-slack-notification.sh" "$SESSION_NAME Remote Control URL: $URL" || true
      break
    fi
  fi

  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Timeout reached (${TIMEOUT}s). URL not detected."
    break
  fi

  sleep "$POLL_INTERVAL"
done
