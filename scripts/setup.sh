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
REPO_NAME=$(basename "${GIT_REPO_URL}" .git)
cat > /home/ubuntu/.claude-env << ENVEOF
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
WORKSPACE_DIR=/workspaces/$REPO_NAME
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

# --- Clone the infrastructure repository ---
INFRA_DIR="/home/ubuntu/ec2-development-environment"
echo "Cloning infrastructure repository: ${INFRA_REPO_URL}"
git clone "${INFRA_REPO_URL}" "$INFRA_DIR"
chown -R ubuntu:ubuntu "$INFRA_DIR"

# --- Copy scripts into devcontainer ---
CONTAINER_ID=$(docker ps --filter "label=devcontainer.local_folder" --format '{{.ID}}' | head -1)

if [ -n "$CONTAINER_ID" ]; then
  docker exec "$CONTAINER_ID" mkdir -p /root/scripts
  docker cp "$INFRA_DIR/scripts/." "$CONTAINER_ID":/root/scripts/
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
