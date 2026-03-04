#!/bin/bash
# Manages Claude Code remote-control tmux sessions.
# Usage:
#   start-claude-sessions.sh -c <session-name>   Create a session
#   start-claude-sessions.sh -r <session-name>   Remove a session
# Designed to run inside the dev container.

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
if [ -f "$HOME/.claude-env" ]; then
  set -a
  source "$HOME/.claude-env"
  set +a
fi
LOG_DIR="$HOME/claude-logs"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage:"
  echo "  $0 -c <session-name>   Create a session"
  echo "  $0 -r <session-name>   Remove a session"
  exit 1
}

create_session() {
  local name="$1"
  local log_file="$LOG_DIR/$name.log"

  mkdir -p "$LOG_DIR"

  # Check Claude authentication
  if ! claude --version > /dev/null 2>&1; then
    echo "ERROR: Claude Code CLI not found."
    exit 1
  fi

  if [ ! -d "$HOME/.claude" ] || [ -z "$(ls -A "$HOME/.claude" 2>/dev/null)" ]; then
    echo "WARNING: Claude not authenticated. Run 'claude login' first."
    exit 1
  fi

  if tmux has-session -t "$name" 2>/dev/null; then
    echo "Session '$name' already exists."
    exit 1
  fi

  # Accept workspace trust dialog if not yet trusted
  echo "Accepting workspace trust for $WORKSPACE_DIR..."
  cd "$WORKSPACE_DIR"
  yes | claude -p "exit" > /dev/null 2>&1 || true

  tmux new-session -d -s "$name" -c "$WORKSPACE_DIR"
  tmux send-keys -t "$name" "claude remote-control --permission-mode acceptEdits 2>&1 | tee -a $log_file" Enter

  echo "Session started: $name"

  # Start URL monitor in background
  nohup "$SCRIPT_DIR/monitor-urls.sh" "$LOG_DIR" "$name" > "$LOG_DIR/monitor-$name.log" 2>&1 &

  # Attach to the session
  tmux attach -t "$name"
}

remove_session() {
  local name="$1"

  tmux kill-session -t "$name" 2>/dev/null && echo "Session '$name' removed." || echo "Session '$name' not found."
  rm -f "$LOG_DIR/$name.log" "$LOG_DIR/monitor-$name.log"
}

if [ $# -lt 1 ]; then
  usage
fi

case "$1" in
  -c)
    [ $# -lt 2 ] && usage
    create_session "$2"
    ;;
  -r)
    [ $# -lt 2 ] && usage
    remove_session "$2"
    ;;
  *)
    usage
    ;;
esac
