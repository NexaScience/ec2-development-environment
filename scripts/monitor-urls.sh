#!/bin/bash
# Monitors Claude Code log files for Remote Control URLs and sends them to Slack.
# Usage: monitor-urls.sh <log_dir> <session_count>

set -euo pipefail

LOG_DIR="${1:-$HOME/claude-logs}"
SESSION_COUNT="${2:-${CLAUDE_SESSION_COUNT:-8}}"
TIMEOUT=300  # 5 minutes
POLL_INTERVAL=5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

declare -A NOTIFIED

check_and_notify() {
  local session_name="$1"
  local log_file="$2"

  if [ "${NOTIFIED[$session_name]:-}" = "1" ]; then
    return
  fi

  if [ ! -f "$log_file" ]; then
    return
  fi

  local url
  url=$(grep -oP 'https://claude\.ai/code/[^\s"]+' "$log_file" 2>/dev/null | tail -1 || true)

  if [ -n "$url" ]; then
    NOTIFIED[$session_name]="1"
    echo "[$(date)] $session_name: Remote Control URL detected: $url"
    "$SCRIPT_DIR/send-slack-notification.sh" "$session_name Remote Control URL: $url" || true
  fi
}

echo "Monitoring $SESSION_COUNT sessions for Remote Control URLs (timeout: ${TIMEOUT}s)..."

START_TIME=$(date +%s)

while true; do
  ALL_FOUND=true

  for i in $(seq 1 "$SESSION_COUNT"); do
    SESSION_NAME="claude-$i"
    LOG_FILE="$LOG_DIR/session-$i.log"
    check_and_notify "$SESSION_NAME" "$LOG_FILE"

    if [ "${NOTIFIED[$SESSION_NAME]:-}" != "1" ]; then
      ALL_FOUND=false
    fi
  done

  if [ "$ALL_FOUND" = true ]; then
    echo "All $SESSION_COUNT URLs detected and notified."
    break
  fi

  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Timeout reached (${TIMEOUT}s). Some URLs may not have been detected."
    break
  fi

  sleep "$POLL_INTERVAL"
done
