#!/bin/bash
# EC2 user_data script: clones app repo, starts its devcontainer, copies scripts in.
# Template variables are injected by Terraform's templatefile().
# Terraform templatefile: use $$$${} to produce literal dollar-brace in output.

set -euo pipefail
exec > >(tee /var/log/claude-setup.log) 2>&1

echo "=== Claude Code Dev Container Setup ==="

# --- System packages ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  curl \
  git \
  jq \
  ca-certificates \
  gnupg

# --- Docker ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu

# --- Node.js 22.x (for devcontainer CLI on host) ---
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# --- devcontainer CLI ---
npm install -g @devcontainers/cli

# --- Environment variables ---
cat > /home/ubuntu/.claude-env << 'ENVEOF'
SLACK_WEBHOOK_URL=${slack_webhook_url}
CLAUDE_SESSION_COUNT=${claude_session_count}
ENVEOF
chown ubuntu:ubuntu /home/ubuntu/.claude-env
chmod 600 /home/ubuntu/.claude-env

# Load env vars in shell profile
cat >> /home/ubuntu/.bashrc << 'BASHEOF'

# Claude Code environment
if [ -f "$HOME/.claude-env" ]; then
  set -a
  source "$HOME/.claude-env"
  set +a
fi
BASHEOF

# --- Clone the application repository ---
echo "Cloning repository: ${git_repo_url}"
git clone "${git_repo_url}" /home/ubuntu/app
chown -R ubuntu:ubuntu /home/ubuntu/app

# --- Create .env from .env.example if needed ---
if [ -f /home/ubuntu/app/.env.example ] && [ ! -f /home/ubuntu/app/.env ]; then
  cp /home/ubuntu/app/.env.example /home/ubuntu/app/.env
  chown ubuntu:ubuntu /home/ubuntu/app/.env
  echo ".env created from .env.example"
fi

# --- Build and start the dev container ---
echo "Starting devcontainer..."
# postCreateCommand may fail (e.g. pre-commit install) but container still starts
sudo -u ubuntu bash -c "cd /home/ubuntu/app && devcontainer up --workspace-folder ." || true

# --- Prepare scripts on host then copy into container ---
SCRIPTS_DIR="/home/ubuntu/scripts"
mkdir -p "$SCRIPTS_DIR"

# send-slack-notification.sh
cat > "$SCRIPTS_DIR/send-slack-notification.sh" << 'SLACKEOF'
#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <message>"
  exit 1
fi

MESSAGE="$1"
WEBHOOK_URL="$${SLACK_WEBHOOK_URL:-}"

if [ -z "$WEBHOOK_URL" ]; then
  echo "[WARN] SLACK_WEBHOOK_URL is not set. Skipping notification."
  exit 0
fi

HOSTNAME=$(hostname)
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" "[$HOSTNAME] $MESSAGE")

HTTP_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL")

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo "Slack notification sent successfully."
else
  echo "[ERROR] Slack notification failed (HTTP $HTTP_STATUS)."
  exit 1
fi
SLACKEOF

# monitor-urls.sh
cat > "$SCRIPTS_DIR/monitor-urls.sh" << 'MONITOREOF'
#!/bin/bash
set -euo pipefail

LOG_DIR="$${1:-$HOME/claude-logs}"
SESSION_COUNT="$${2:-$${CLAUDE_SESSION_COUNT:-8}}"
TIMEOUT=300
POLL_INTERVAL=5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

declare -A NOTIFIED

check_and_notify() {
  local session_name="$1"
  local log_file="$2"

  if [ "$${NOTIFIED[$session_name]:-}" = "1" ]; then
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

echo "Monitoring $SESSION_COUNT sessions for Remote Control URLs (timeout: $${TIMEOUT}s)..."

START_TIME=$(date +%s)

while true; do
  ALL_FOUND=true

  for i in $(seq 1 "$SESSION_COUNT"); do
    SESSION_NAME="claude-$i"
    LOG_FILE="$LOG_DIR/session-$i.log"
    check_and_notify "$SESSION_NAME" "$LOG_FILE"

    if [ "$${NOTIFIED[$SESSION_NAME]:-}" != "1" ]; then
      ALL_FOUND=false
    fi
  done

  if [ "$ALL_FOUND" = true ]; then
    echo "All $SESSION_COUNT URLs detected and notified."
    break
  fi

  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Timeout reached ($${TIMEOUT}s). Some URLs may not have been detected."
    break
  fi

  sleep "$POLL_INTERVAL"
done
MONITOREOF

# start-claude-sessions.sh
cat > "$SCRIPTS_DIR/start-claude-sessions.sh" << 'SESSIONEOF'
#!/bin/bash
set -euo pipefail

SESSION_COUNT="$${CLAUDE_SESSION_COUNT:-8}"
WORKSPACE_BASE="$HOME/workspace"
LOG_DIR="$HOME/claude-logs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$LOG_DIR"

# Kill existing monitor and claude sessions for clean restart
pkill -f monitor-urls.sh 2>/dev/null || true
for i in $(seq 1 "$SESSION_COUNT"); do
  tmux kill-session -t "claude-$i" 2>/dev/null || true
done
rm -f "$LOG_DIR"/session-*.log "$LOG_DIR"/monitor.log

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

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session $SESSION_NAME already exists, skipping."
    continue
  fi

  tmux new-session -d -s "$SESSION_NAME" -c "$WORK_DIR"
  tmux send-keys -t "$SESSION_NAME" "cd $WORK_DIR && [ ! -d .git ] && git init . 2>/dev/null; yes | claude remote-control --dangerously-skip-permissions 2>&1 | tee -a $LOG_FILE" Enter

  echo "Started session: $SESSION_NAME (workspace: $WORK_DIR)"
done

echo "All $SESSION_COUNT sessions started."
echo "Use 'tmux ls' to list sessions."
echo "Use 'tmux attach -t claude-1' to attach to a session."

# Start URL monitor in background
nohup "$SCRIPT_DIR/monitor-urls.sh" "$LOG_DIR" "$SESSION_COUNT" > "$LOG_DIR/monitor.log" 2>&1 &
echo "URL monitor started (PID: $!)."
SESSIONEOF

chmod +x "$SCRIPTS_DIR/"*.sh

# --- Copy scripts into devcontainer ---
CONTAINER_ID=$(docker ps --filter "label=devcontainer.local_folder" --format '{{.ID}}' | head -1)

if [ -n "$CONTAINER_ID" ]; then
  docker exec "$CONTAINER_ID" mkdir -p /root/scripts
  docker cp "$SCRIPTS_DIR/." "$CONTAINER_ID":/root/scripts/
  docker exec "$CONTAINER_ID" chown -R root:root /root/scripts
  docker exec "$CONTAINER_ID" sh -c 'chmod +x /root/scripts/*.sh'

  # Inject auto-start into container's .bashrc
  docker exec "$CONTAINER_ID" bash -c 'cat >> /root/.bashrc << '\''AUTOSTART'\''

# Auto-start Claude remote-control sessions after login
if [ -n "$PS1" ] && command -v claude &>/dev/null; then
  if [ -d "$HOME/.claude" ] && [ -n "$(ls -A "$HOME/.claude" 2>/dev/null)" ]; then
    if ! tmux has-session -t claude-1 2>/dev/null; then
      echo "Claude authenticated. Starting remote-control sessions..."
      set -a
      source /root/.claude-env 2>/dev/null
      set +a
      ~/scripts/start-claude-sessions.sh
    fi
  fi
fi
AUTOSTART'

  # Copy .claude-env into container for session env vars
  docker cp /home/ubuntu/.claude-env "$CONTAINER_ID":/root/.claude-env

  echo "Scripts and auto-start configured in container $CONTAINER_ID"
else
  echo "[WARN] No running devcontainer found. Scripts not copied."
fi

# --- enter-container.sh (convenience script on host) ---
cat > /home/ubuntu/enter-container.sh << 'ENTEREOF'
#!/bin/bash
set -euo pipefail

CONTAINER_ID=$(docker ps --filter "label=devcontainer.local_folder" --format '{{.ID}}' | head -1)

if [ -z "$CONTAINER_ID" ]; then
  echo "No running dev container found. Starting one..."
  cd ~/app
  source ~/.claude-env 2>/dev/null || true
  devcontainer up --workspace-folder .
  CONTAINER_ID=$(docker ps --filter "label=devcontainer.local_folder" --format '{{.ID}}' | head -1)
fi

echo "Entering container $CONTAINER_ID..."
docker exec -it "$CONTAINER_ID" bash
ENTEREOF

chown ubuntu:ubuntu /home/ubuntu/enter-container.sh
chmod +x /home/ubuntu/enter-container.sh

# --- IMDSv2 token helper ---
cat > /home/ubuntu/.imds-helper.sh << 'IMDSEOF'
get_imds_token() {
  curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300"
}
get_metadata() {
  local token
  token=$(get_imds_token)
  curl -s -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1"
}
IMDSEOF
chown ubuntu:ubuntu /home/ubuntu/.imds-helper.sh

# --- Send startup Slack notification from host ---
if [ -n "${slack_webhook_url}" ]; then
  PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unknown")
  PAYLOAD=$(jq -n --arg text "[$PUBLIC_IP] EC2 + Dev Container started. SSH: ssh ubuntu@$PUBLIC_IP then ./enter-container.sh" '{"text": $text}')
  curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "${slack_webhook_url}" || true
fi

echo "=== Setup complete ==="
echo "SSH into the instance, then run: ./enter-container.sh"
echo "Inside the container: claude login (first time), then ~/scripts/start-claude-sessions.sh"
