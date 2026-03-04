#!/bin/bash
# Creates N tmux sessions, each running Claude Code remote-control in its own workspace.
# Designed to run inside the dev container.

set -euo pipefail

SESSION_COUNT="${CLAUDE_SESSION_COUNT:-8}"
WORKSPACE_BASE="$HOME/workspace"
LOG_DIR="$HOME/claude-logs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$LOG_DIR"

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

echo "Starting $SESSION_COUNT Claude Code remote-control sessions..."

for i in $(seq 1 "$SESSION_COUNT"); do
  SESSION_NAME="claude-$i"
  WORK_DIR="$WORKSPACE_BASE/session-$i"
  LOG_FILE="$LOG_DIR/session-$i.log"

  mkdir -p "$WORK_DIR"

  # Skip if session already exists
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session $SESSION_NAME already exists, skipping."
    continue
  fi

  tmux new-session -d -s "$SESSION_NAME" -c "$WORK_DIR"
  tmux send-keys -t "$SESSION_NAME" "cd $WORK_DIR && [ ! -d .git ] && git init . 2>/dev/null; claude remote-control --dangerously-skip-permissions 2>&1 | tee -a $LOG_FILE" Enter

  echo "Started session: $SESSION_NAME (workspace: $WORK_DIR)"
done

echo "All $SESSION_COUNT sessions started."
echo "Use 'tmux ls' to list sessions."
echo "Use 'tmux attach -t claude-1' to attach to a session."

# Start URL monitor in background
nohup "$SCRIPT_DIR/monitor-urls.sh" "$LOG_DIR" "$SESSION_COUNT" > "$LOG_DIR/monitor.log" 2>&1 &
echo "URL monitor started (PID: $!)."
