#!/bin/bash
# Launch Claude Code dev session with ttyd + cloudflared tunnel + frontend/backend.
#
# Usage:
#   start-claude-sessions.sh -c <session-name>   Create a session
#   start-claude-sessions.sh -r <session-name>   Remove a session
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/claude-logs"
CLOUDFLARED="cloudflared"
TTYD="ttyd"

# ── Load environment ──
ENV_FILE="$SCRIPT_DIR/../.env"
SLACK_WEBHOOK_URL=""
if [ -f "$ENV_FILE" ]; then
  SLACK_WEBHOOK_URL=$(grep -oP '^TF_VAR_SLACK_WEBHOOK_URL="\K[^"]+' "$ENV_FILE" || true)
fi
export SLACK_WEBHOOK_URL

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces/airas}"

# ── Usage ──
usage() {
  echo "Usage:"
  echo "  $0 -c <session-name>   Create a session"
  echo "  $0 -r <session-name>   Remove a session"
  exit 1
}

# ── Utilities ──
find_free_port() {
  local port="${1:-7681}"
  while (echo >/dev/tcp/localhost/$port) 2>/dev/null; do
    port=$((port + 1))
  done
  echo "$port"
}

wait_for_port() {
  local port="$1"
  local timeout="${2:-30}"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if curl -s -o /dev/null "http://localhost:$port" 2>/dev/null; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_for_tunnel_url() {
  local log_file="$1"
  local timeout="${2:-30}"
  local url=""
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if [ -f "$log_file" ]; then
      url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1 || true)
      if [ -n "$url" ]; then
        echo "$url"
        return 0
      fi
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

save_session_info() {
  local name="$1"
  local ttyd_port="$2"
  local backend_port="$3"
  local frontend_port="$4"
  local ttyd_pid="$5"
  local cloudflared_ttyd_pid="$6"
  local cloudflared_backend_pid="$7"
  local cloudflared_frontend_pid="$8"

  mkdir -p "$LOG_DIR"
  local info_file="$LOG_DIR/${name}.session"
  cat > "$info_file" <<EOF
TTYD_PORT=$ttyd_port
BACKEND_PORT=$backend_port
FRONTEND_PORT=$frontend_port
TTYD_PID=$ttyd_pid
CLOUDFLARED_TTYD_PID=$cloudflared_ttyd_pid
CLOUDFLARED_BACKEND_PID=$cloudflared_backend_pid
CLOUDFLARED_FRONTEND_PID=$cloudflared_frontend_pid
EOF
}

# ── Create Session ──
create_session() {
  local name="$1"
  local work_dir="$WORKSPACE_DIR"

  mkdir -p "$LOG_DIR"

  # Prevent nested tmux
  unset TMUX 2>/dev/null || true
  unset CLAUDECODE 2>/dev/null || true

  # Validate
  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    echo "ERROR: TF_VAR_SLACK_WEBHOOK_URL not set in $ENV_FILE"
    exit 1
  fi

  if ! env -u CLAUDECODE claude --version > /dev/null 2>&1; then
    echo "ERROR: Claude Code CLI not found."
    exit 1
  fi

  # Find free ports
  local ttyd_port backend_port frontend_port
  ttyd_port=$(find_free_port 7681)
  backend_port=$(find_free_port 8000)
  frontend_port=$(find_free_port 5173)

  echo "Ports: ttyd=$ttyd_port, backend=$backend_port, frontend=$frontend_port"

  # Kill previous session if exists
  tmux kill-session -t "$name" 2>/dev/null || true

  # ── 1. Create tmux session with Claude Code ──
  echo "Starting Claude Code in tmux session '$name'..."
  tmux new-session -d -s "$name" -n claude -c "$work_dir" \
    "exec env -u CLAUDECODE claude --dangerously-skip-permissions"

  # ── 2. Start backend in a new window ──
  echo "Starting backend on port $backend_port..."
  tmux new-window -t "$name" -n backend -c "$work_dir/backend" \
    "exec bash -lc 'uv run uvicorn api.main:app --host 0.0.0.0 --port $backend_port 2>&1 | tee $LOG_DIR/${name}-backend.log'"

  # ── 3. Wait for backend, then start cloudflared for backend ──
  echo "Waiting for backend (port $backend_port)..."
  if ! wait_for_port "$backend_port" 60; then
    echo "WARN: Backend did not start within 60s. Continuing anyway..."
  fi

  echo "Starting cloudflared tunnel for backend..."
  $CLOUDFLARED tunnel --url "http://localhost:$backend_port" --no-autoupdate \
    > "$LOG_DIR/${name}-tunnel-backend.log" 2>&1 &
  local cloudflared_backend_pid=$!

  echo "Waiting for backend tunnel URL..."
  local backend_url=""
  backend_url=$(wait_for_tunnel_url "$LOG_DIR/${name}-tunnel-backend.log" 30) || true
  if [ -z "$backend_url" ]; then
    echo "WARN: Backend tunnel URL not detected within 30s."
  else
    echo "Backend tunnel: $backend_url"
  fi

  # ── 4. Start frontend with VITE_API_BASE_URL pointing to backend tunnel ──
  echo "Starting frontend on port $frontend_port..."
  tmux new-window -t "$name" -n frontend -c "$work_dir/frontend" \
    "exec bash -lc 'VITE_API_BASE_URL=$backend_url npm run dev -- --port $frontend_port 2>&1 | tee $LOG_DIR/${name}-frontend.log'"

  echo "Waiting for frontend (port $frontend_port)..."
  if ! wait_for_port "$frontend_port" 30; then
    echo "WARN: Frontend did not start within 30s. Continuing anyway..."
  fi

  # ── 5. Start cloudflared tunnel for frontend ──
  echo "Starting cloudflared tunnel for frontend..."
  $CLOUDFLARED tunnel --url "http://localhost:$frontend_port" --no-autoupdate \
    > "$LOG_DIR/${name}-tunnel-frontend.log" 2>&1 &
  local cloudflared_frontend_pid=$!

  echo "Waiting for frontend tunnel URL..."
  local frontend_url=""
  frontend_url=$(wait_for_tunnel_url "$LOG_DIR/${name}-tunnel-frontend.log" 30) || true
  if [ -z "$frontend_url" ]; then
    echo "WARN: Frontend tunnel URL not detected within 30s."
  fi

  # ── 6. Start ttyd exposing the tmux session ──
  echo "Starting ttyd on port $ttyd_port..."
  $TTYD -p "$ttyd_port" -W \
    -t fontSize=18 \
    -t 'fontFamily="Menlo, Courier New, monospace"' \
    -t disableLeaveAlert=true \
    tmux attach -t "$name":claude \
    > "$LOG_DIR/${name}-ttyd.log" 2>&1 &
  local ttyd_pid=$!

  # ── 7. Start cloudflared tunnel for ttyd ──
  echo "Starting cloudflared tunnel for ttyd..."
  $CLOUDFLARED tunnel --url "http://localhost:$ttyd_port" --no-autoupdate \
    > "$LOG_DIR/${name}-tunnel-ttyd.log" 2>&1 &
  local cloudflared_ttyd_pid=$!

  echo "Waiting for ttyd tunnel URL..."
  local ttyd_url=""
  ttyd_url=$(wait_for_tunnel_url "$LOG_DIR/${name}-tunnel-ttyd.log" 30) || true
  if [ -z "$ttyd_url" ]; then
    echo "WARN: ttyd tunnel URL not detected within 30s."
  fi

  # ── 8. Save session info for cleanup ──
  save_session_info "$name" "$ttyd_port" "$backend_port" "$frontend_port" \
    "$ttyd_pid" "$cloudflared_ttyd_pid" "$cloudflared_backend_pid" "$cloudflared_frontend_pid"

  # ── 9. Generate CLAUDE.local.md ──
  local claude_local="$work_dir/.claude/CLAUDE.local.md"
  mkdir -p "$(dirname "$claude_local")"
  cat > "$claude_local" <<EOF
# CLAUDE Local Development Guide

回答は全て日本語で行ってください。

## Error Capture
\`backend\` と \`frontend\` はtmux sessionsで起動しています。エラーが発生した場合、以下のコマンドでエラー内容をキャプチャできます。

- \`backend\` window:

    \`\`\`bash
    tmux capture-pane -t ${name}:backend -p
    \`\`\`

- \`frontend\` window:

    \`\`\`bash
    tmux capture-pane -t ${name}:frontend -p
    \`\`\`
EOF

  # ── 10. Slack notification ──
  local slack_msg="Session: $name"
  if [ -n "$ttyd_url" ]; then
    slack_msg="$slack_msg\nClaude (ttyd): $ttyd_url"
  fi
  if [ -n "$frontend_url" ]; then
    slack_msg="$slack_msg\nFrontend: $frontend_url"
  fi

  echo ""
  echo "=== Session '$name' started ==="
  echo "  Claude (ttyd): ${ttyd_url:-not available}"
  echo "  Frontend:      ${frontend_url:-not available}"
  echo "  Backend:       ${backend_url:-not available}"
  echo ""
  echo "  tmux attach -t $name"
  echo "==============================="

  "$SCRIPT_DIR/send-slack-notification.sh" "$(echo -e "$slack_msg")" || true

  # Attach to the tmux claude window so the terminal shows Claude Code
  exec tmux attach -t "$name":claude
}

# ── Remove Session ──
remove_session() {
  local name="$1"
  unset TMUX 2>/dev/null || true

  local info_file="$LOG_DIR/${name}.session"
  if [ -f "$info_file" ]; then
    source "$info_file"
    # Kill background processes
    kill "$TTYD_PID" 2>/dev/null || true
    kill "$CLOUDFLARED_TTYD_PID" 2>/dev/null || true
    kill "$CLOUDFLARED_BACKEND_PID" 2>/dev/null || true
    kill "$CLOUDFLARED_FRONTEND_PID" 2>/dev/null || true
    rm -f "$info_file"
  fi

  # Kill tmux session
  tmux kill-session -t "$name" 2>/dev/null && echo "Session '$name' removed." || echo "Session '$name' not found."

  # Clean up logs
  rm -f "$LOG_DIR/${name}"*.log
}

# ── Parse args ──
if [ $# -lt 2 ]; then
  usage
fi

case "$1" in
  -c) create_session "$2" ;;
  -r) remove_session "$2" ;;
  *)  usage ;;
esac
