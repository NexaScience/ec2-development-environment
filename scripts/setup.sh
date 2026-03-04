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
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
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
REPO_NAME=$(basename "${GIT_REPO_URL}" .git)
REPO_DIR="/home/ubuntu/$REPO_NAME"

echo "Cloning repository: ${GIT_REPO_URL}"
git clone "${GIT_REPO_URL}" "$REPO_DIR"
chown -R ubuntu:ubuntu "$REPO_DIR"

# --- Create .env from .env.example if needed ---
if [ -f "$REPO_DIR/.env.example" ] && [ ! -f "$REPO_DIR/.env" ]; then
  cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
  chown ubuntu:ubuntu "$REPO_DIR/.env"
  echo ".env created from .env.example"
fi

# --- Build and start the dev container ---
echo "Starting devcontainer..."
# postCreateCommand may fail (e.g. pre-commit install) but container still starts
sudo -u ubuntu bash -c "cd $REPO_DIR && devcontainer up --workspace-folder ." || true

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
SESSION_NAME="$${2:-claude}"
LOG_FILE="$LOG_DIR/$SESSION_NAME.log"
TIMEOUT=300
POLL_INTERVAL=5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Monitoring $SESSION_NAME for Remote Control URL (timeout: $${TIMEOUT}s)..."

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
    echo "Timeout reached ($${TIMEOUT}s). URL not detected."
    break
  fi

  sleep "$POLL_INTERVAL"
done
MONITOREOF

# start-claude-sessions.sh
cat > "$SCRIPTS_DIR/start-claude-sessions.sh" << 'SESSIONEOF'
#!/bin/bash
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
SESSIONEOF

chmod +x "$SCRIPTS_DIR/"*.sh

# --- Copy scripts into devcontainer ---
CONTAINER_ID=$(docker ps --filter "label=devcontainer.local_folder" --format '{{.ID}}' | head -1)

if [ -n "$CONTAINER_ID" ]; then
  docker exec "$CONTAINER_ID" mkdir -p /root/scripts
  docker cp "$SCRIPTS_DIR/." "$CONTAINER_ID":/root/scripts/
  docker exec "$CONTAINER_ID" chown -R root:root /root/scripts
  docker exec "$CONTAINER_ID" sh -c 'chmod +x /root/scripts/*.sh'

  # Copy .claude-env into container for session env vars
  docker cp /home/ubuntu/.claude-env "$CONTAINER_ID":/root/.claude-env

  echo "Scripts configured in container $CONTAINER_ID"
else
  echo "[WARN] No running devcontainer found. Scripts not copied."
fi

# --- Send startup Slack notification from host ---
if [ -n "${SLACK_WEBHOOK_URL}" ]; then
  PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unknown")
  PAYLOAD=$(jq -n --arg text "[$PUBLIC_IP] EC2 + Dev Container started. SSH: ssh ubuntu@$PUBLIC_IP" '{"text": $text}')
  curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "${SLACK_WEBHOOK_URL}" || true
fi

echo "=== Setup complete ==="
echo "Inside the container: claude login (first time), then ~/scripts/start-claude-sessions.sh"
