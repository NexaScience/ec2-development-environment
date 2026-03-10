#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/workspaces/airas"
WORKTREE_DIR="${REPO_DIR}/.worktrees"
SESSION_PREFIX="claude"

BACKEND_PORT_DEFAULT=8000
FRONTEND_PORT_DEFAULT=5173
TTYD_PORT_DEFAULT=7681

usage() {
  echo ""
  echo "Usage:"
  echo "  $0 -c <branch>"
  echo "  $0 -r <branch>"
  echo "  $0 -a <branch>"
  echo ""
  exit 1
}

[[ $# -lt 2 ]] && usage

MODE="$1"
BRANCH="$2"

SESSION="${SESSION_PREFIX}-${BRANCH}"
WT="${WORKTREE_DIR}/${BRANCH}"

CF_BACKEND_LOG="/tmp/cf-backend-${BRANCH}.log"
CF_FRONTEND_LOG="/tmp/cf-frontend-${BRANCH}.log"
CF_TTYD_LOG="/tmp/cf-ttyd-${BRANCH}.log"
TTYD_PID_FILE="/tmp/ttyd-${BRANCH}.pid"
TTYD_LOG="/tmp/ttyd-${BRANCH}.log"

check_deps() {
  for cmd in tmux git uv npm claude cloudflared ttyd; do
    command -v "$cmd" >/dev/null || {
      echo "Missing dependency: $cmd"
      exit 1
    }
  done
}

create_worktree() {
  git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

  mkdir -p "$WORKTREE_DIR"

  if [[ -d "$WT" ]]; then
    echo "Worktree exists: $WT"
    return
  fi

  git -C "$REPO_DIR" fetch origin develop
  echo "Creating worktree for $BRANCH"

  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_DIR" worktree add "$WT" "$BRANCH"
  else
    git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WT" origin/develop
  fi

  git config --global --add safe.directory "$WT" || true

  # Link gitignored files from main repo into worktree
  local shared_files=(".env" ".claude/CLAUDE.local.md" ".claude/settings.local.json")
  for rel_path in "${shared_files[@]}"; do
    local src="${REPO_DIR}/${rel_path}" dst="${WT}/${rel_path}"
    if [[ -f "$src" && ! -e "$dst" ]]; then
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
    fi
  done
}

find_free_port() {
  local port=$1
  while ss -tlnp 2>/dev/null | grep -qE ":${port}( |\b)"; do
    ((port++))
  done
  echo "$port"
}

wait_for_cf_url() {
  local log_file=$1
  local max_wait=${2:-60}
  local elapsed=0
  local url=""

  while [[ -z "$url" && $elapsed -lt $max_wait ]]; do
    url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1)
    sleep 1
    ((elapsed++))
  done

  echo "$url"
}

start_tunnel() {
  local name=$1 port=$2 log_file=$3
  tmux new-window -t "$SESSION" -n "tunnel-${name}" -c "$WT"
  tmux send-keys -t "$SESSION:tunnel-${name}" \
    "cloudflared tunnel --url http://localhost:${port} 2>&1 | tee ${log_file}" C-m
}

load_slack_webhook() {
  grep -oP '(?<=TF_VAR_SLACK_WEBHOOK_URL=")[^"]+' "${REPO_DIR}/.env" 2>/dev/null \
    || grep -oP '(?<=TF_VAR_SLACK_WEBHOOK_URL=)[^\s"]+' "${REPO_DIR}/.env" 2>/dev/null \
    || true
}

notify_slack() {
  local msg=$1
  local webhook
  webhook=$(load_slack_webhook)
  if [[ -n "$webhook" ]]; then
    SLACK_WEBHOOK_URL="$webhook" \
      /workspaces/ec2-development-environment/scripts/send-slack-notification.sh "$msg" || true
  fi
}

create_tmux_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session already exists"
    return
  fi

  local backend_port frontend_port ttyd_port
  backend_port=$(find_free_port "$BACKEND_PORT_DEFAULT")
  frontend_port=$(find_free_port "$FRONTEND_PORT_DEFAULT")
  ttyd_port=$(find_free_port "$TTYD_PORT_DEFAULT")

  rm -f "$CF_BACKEND_LOG" "$CF_FRONTEND_LOG" "$CF_TTYD_LOG"

  echo "Creating tmux session: $SESSION"
  echo "  Backend  port: $backend_port"
  echo "  Frontend port: $frontend_port"
  echo "  ttyd     port: $ttyd_port"

  tmux new-session -d -s "$SESSION" -n claude -c "$WT"
  tmux send-keys -t "$SESSION:claude" "cd $WT && claude --dangerously-skip-permissions" C-m

  tmux new-window -t "$SESSION" -n backend -c "$WT/backend"
  tmux send-keys -t "$SESSION:backend" \
    "source $WT/backend/.venv/bin/activate && uv run uvicorn api.main:app --host 0.0.0.0 --port ${backend_port} --reload" C-m

  # Backend tunnel must resolve first — its URL is needed for VITE_API_BASE_URL
  start_tunnel backend "$backend_port" "$CF_BACKEND_LOG"
  echo "Waiting for backend Cloudflare tunnel URL..."
  local backend_cf_url
  backend_cf_url=$(wait_for_cf_url "$CF_BACKEND_LOG")
  if [[ -z "$backend_cf_url" ]]; then
    echo "ERROR: Failed to get backend Cloudflare URL within 60 seconds"
    exit 1
  fi
  echo "  Backend CF URL: $backend_cf_url"

  tmux new-window -t "$SESSION" -n frontend -c "$WT/frontend"
  tmux send-keys -t "$SESSION:frontend" \
    "VITE_API_BASE_URL=${backend_cf_url} npm run dev -- --port ${frontend_port}" C-m

  # ttyd attaches to this session so must run outside it as a background process
  ttyd --port "$ttyd_port" tmux attach-session -t "$SESSION" >"$TTYD_LOG" 2>&1 &
  echo $! > "$TTYD_PID_FILE"

  # Start frontend and ttyd tunnels simultaneously, then wait for both
  start_tunnel frontend "$frontend_port" "$CF_FRONTEND_LOG"
  start_tunnel ttyd "$ttyd_port" "$CF_TTYD_LOG"

  echo "Waiting for frontend and ttyd Cloudflare tunnel URLs..."
  local frontend_cf_url ttyd_cf_url
  frontend_cf_url=$(wait_for_cf_url "$CF_FRONTEND_LOG")
  ttyd_cf_url=$(wait_for_cf_url "$CF_TTYD_LOG")

  echo ""
  echo "============================================"
  echo "  Frontend URL: ${frontend_cf_url:-"(check tunnel-frontend window)"}"
  echo "  Backend  URL: ${backend_cf_url}"
  echo "  Claude   URL: ${ttyd_cf_url:-"(check tunnel-ttyd window)"}"
  echo "============================================"
  echo ""

  local msg="[$BRANCH]"
  [[ -n "$frontend_cf_url" ]] && msg+=" Frontend: ${frontend_cf_url}"
  [[ -n "$ttyd_cf_url" ]] && msg+=" | Claude: ${ttyd_cf_url}"
  notify_slack "$msg"
}

create() {
  check_deps
  create_worktree
  create_tmux_session

  echo ""
  echo "Session ready. Attaching..."
  echo ""

  tmux attach -t "${SESSION}:claude"
}

remove() {
  # Kill ttyd before the session it attaches to
  if [[ -f "$TTYD_PID_FILE" ]]; then
    kill "$(cat "$TTYD_PID_FILE")" 2>/dev/null || true
    rm -f "$TTYD_PID_FILE"
  fi

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
  fi

  if git -C "$REPO_DIR" worktree list | grep -q "$WT"; then
    git -C "$REPO_DIR" worktree remove -f "$WT"
  fi

  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_DIR" branch -D "$BRANCH" || true
  fi

  rm -f "$CF_BACKEND_LOG" "$CF_FRONTEND_LOG" "$CF_TTYD_LOG" "$TTYD_LOG"

  echo "Removed $BRANCH"
}

attach() {
  tmux attach -t "$SESSION"
}

case "$MODE" in
  -c) create ;;
  -r) remove ;;
  -a) attach ;;
  *)  usage ;;
esac
