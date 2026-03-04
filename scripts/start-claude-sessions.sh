#!/bin/bash
# Creates a tmux session running Claude Code remote-control.
# Usage: start-claude-sessions.sh <session-name>
# Designed to run inside the dev container.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <session-name>"
  exit 1
fi

SESSION_NAME="$1"
LOG_DIR="$HOME/claude-logs"
LOG_FILE="$LOG_DIR/$SESSION_NAME.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$LOG_DIR"

# Kill existing session for clean restart
pkill -f monitor-urls.sh 2>/dev/null || true
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
rm -f "$LOG_FILE" "$LOG_DIR/monitor.log"

# Check Claude authentication
if ! claude --version > /dev/null 2>&1; then
  echo "ERROR: Claude Code CLI not found."
  exit 1
fi

echo "Checking Claude authentication..."
if [ ! -d "$HOME/.claude" ] || [ -z "$(ls -A "$HOME/.claude" 2>/dev/null)" ]; then
  echo "WARNING: Claude not authenticated. Run 'claude login' first."
  echo "After login, re-run this script."
  exit 1
fi

echo "Starting Claude Code remote-control session: $SESSION_NAME"

tmux new-session -d -s "$SESSION_NAME"
tmux send-keys -t "$SESSION_NAME" "yes | claude remote-control --dangerously-skip-permissions 2>&1 | tee -a $LOG_FILE" Enter

echo "Session started: $SESSION_NAME"
echo "Use 'tmux attach -t $SESSION_NAME' to attach."

# Start URL monitor in background
nohup "$SCRIPT_DIR/monitor-urls.sh" "$LOG_DIR" "$SESSION_NAME" > "$LOG_DIR/monitor.log" 2>&1 &
echo "URL monitor started (PID: $!)."
