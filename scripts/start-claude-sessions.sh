#!/bin/bash
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
REPO_DIR="/workspaces/airas"
BACKEND_CMD_TEMPLATE="uv run uvicorn api.main:app --host 0.0.0.0 --port __PORT__ --log-level debug --reload"
FRONTEND_CMD_TEMPLATE="npx vite --port __PORT__ --host 0.0.0.0"

# 環境変数の読み込み（リポジトリの .env を使用）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${REPO_DIR}/.env"
SLACK_WEBHOOK_URL=""
if [[ -f "$ENV_FILE" ]]; then
    SLACK_WEBHOOK_URL=$(grep -oP '^TF_VAR_SLACK_WEBHOOK_URL="\K[^"]+' "$ENV_FILE" \
        || grep -oP '^TF_VAR_SLACK_WEBHOOK_URL=\K[^\s]+' "$ENV_FILE" || true)
fi
if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
    echo "ERROR: TF_VAR_SLACK_WEBHOOK_URL is not set in $ENV_FILE"
    exit 1
fi

# ============================================================
# Usage
# ============================================================
usage() {
    echo "Usage: $0 -c <branch-name>   # Create session"
    echo "       $0 -r <branch-name>   # Remove session and all resources"
    echo ""
    echo "Options:"
    echo "  -c  Create a new Claude Code session with tmux, ttyd, cloudflare tunnels"
    echo "  -r  Remove session: kill processes, remove worktree, delete user"
    echo ""
    echo "Environment variables:"
    echo "  SLACK_WEBHOOK_URL  Slack Incoming Webhook URL"
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

MODE="$1"
BRANCH_NAME="$2"
SESSION_NAME="claude-${BRANCH_NAME}"
USER_NAME="develop-${BRANCH_NAME}"
STATE_DIR="/tmp/claude-session-${BRANCH_NAME}"
TUNNEL_LOG_DIR="${STATE_DIR}/tunnels"

# ============================================================
# Helper: find a free port
# ============================================================
find_free_port() {
    local port
    while true; do
        port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
        # 他セッションで既に使用予定のポートと衝突しないか確認
        if ! grep -rq "=${port}$" /tmp/claude-session-*/ports 2>/dev/null; then
            echo "$port"
            return 0
        fi
    done
}

# ============================================================
# Validate prerequisites
# ============================================================
validate_prereqs() {
    for cmd in tmux ttyd cloudflared claude git curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: $cmd is not installed"
            exit 1
        fi
    done
}

# ============================================================
# Slack notification helper
# ============================================================
send_slack() {
    local message="$1"
    curl -s -X POST -H 'Content-type: application/json' \
        --data "$message" \
        "$SLACK_WEBHOOK_URL" || echo "[slack] Warning: Failed to send Slack notification"
}

# ============================================================
# Remove mode (-r)
# ============================================================
do_remove() {
    echo "============================================================"
    echo "  Removing session: ${BRANCH_NAME}"
    echo "============================================================"

    # 1. Kill tmux session
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "[remove] Killing tmux session '${SESSION_NAME}'..."
        tmux kill-session -t "$SESSION_NAME"
    else
        echo "[remove] tmux session '${SESSION_NAME}' not found (already stopped)"
    fi

    # 3. Kill processes via saved PID files
    for pidfile in "${STATE_DIR}"/*.pid; do
        if [[ -f "$pidfile" ]]; then
            local pid
            pid=$(cat "$pidfile")
            local name
            name=$(basename "$pidfile" .pid)
            if kill -0 "$pid" 2>/dev/null; then
                echo "[remove] Killing ${name} (PID: ${pid})..."
                kill "$pid" 2>/dev/null || true
                sleep 1
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    done

    # 4. Kill any processes owned by the user
    if id "$USER_NAME" &>/dev/null; then
        echo "[remove] Killing all processes owned by '${USER_NAME}'..."
        pkill -u "$USER_NAME" 2>/dev/null || true
        sleep 1
        pkill -9 -u "$USER_NAME" 2>/dev/null || true
    fi

    # 5. Remove git worktree
    echo "[remove] Removing git worktree..."
    cd "$REPO_DIR"
    WORKTREE_DIR=$(git worktree list 2>/dev/null | grep "${BRANCH_NAME}" | awk '{print $1}') || true
    if [[ -n "$WORKTREE_DIR" ]]; then
        echo "[remove] Removing worktree at ${WORKTREE_DIR}..."
        git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
    else
        echo "[remove] No worktree found for branch '${BRANCH_NAME}'"
    fi

    # 6. Delete branch (local only)
    if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}" 2>/dev/null; then
        echo "[remove] Deleting local branch '${BRANCH_NAME}'..."
        git branch -D "$BRANCH_NAME" 2>/dev/null || true
    fi

    # 7. Delete Linux user
    if id "$USER_NAME" &>/dev/null; then
        echo "[remove] Deleting user '${USER_NAME}' and home directory..."
        userdel -r "$USER_NAME" 2>/dev/null || true
    else
        echo "[remove] User '${USER_NAME}' not found (already deleted)"
    fi

    # 8. Clean up state directory
    if [[ -d "$STATE_DIR" ]]; then
        echo "[remove] Removing state directory ${STATE_DIR}..."
        rm -rf "$STATE_DIR"
    fi

    # 9. Slack notification
    echo "[slack] Sending stop notification..."
    send_slack "$(cat <<SLACKEOF
{
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "[STOPPED] Claude Code Session: ${BRANCH_NAME}"
            }
        },
        {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": "*Status:*\nSession terminated. All resources removed."
                },
                {
                    "type": "mrkdwn",
                    "text": "*Branch:*\n\`${BRANCH_NAME}\`"
                },
                {
                    "type": "mrkdwn",
                    "text": "*User:*\n\`${USER_NAME}\` (deleted)"
                }
            ]
        }
    ]
}
SLACKEOF
    )"

    echo ""
    echo "[done] All resources for '${BRANCH_NAME}' have been removed."
}

# ============================================================
# Create mode (-c)
# ============================================================
do_create() {
    validate_prereqs


    # ============================================================
    # Allocate free ports
    # ============================================================
    BACKEND_PORT=$(find_free_port)
    FRONTEND_PORT=$(find_free_port)
    TTYD_PORT=$(find_free_port)

    BACKEND_CMD="${BACKEND_CMD_TEMPLATE/__PORT__/$BACKEND_PORT}"
    FRONTEND_CMD="${FRONTEND_CMD_TEMPLATE/__PORT__/$FRONTEND_PORT}"

    echo "[ports] Backend: ${BACKEND_PORT}, Frontend: ${FRONTEND_PORT}, ttyd: ${TTYD_PORT}"

    # State directory for PID files and logs
    mkdir -p "$STATE_DIR" "$TUNNEL_LOG_DIR"

    # Save port info for reference
    cat > "${STATE_DIR}/ports" <<EOF
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}
TTYD_PORT=${TTYD_PORT}
EOF

    # ============================================================
    # Create Linux user
    # ============================================================
    if id "$USER_NAME" &>/dev/null; then
        echo "[setup] User '${USER_NAME}' already exists."
    else
        echo "[setup] Creating user '${USER_NAME}'..."
        useradd -m -s /bin/bash "$USER_NAME"
    fi

    # リポジトリおよび親ディレクトリへのアクセス権を付与
    echo "[setup] Granting repo access to '${USER_NAME}'..."
    REPO_PARENT_DIR="$(dirname "$REPO_DIR")"
    usermod -aG "$(stat -c '%G' "$REPO_PARENT_DIR")" "$USER_NAME" 2>/dev/null || true
    usermod -aG "$(stat -c '%G' "$REPO_DIR")" "$USER_NAME" 2>/dev/null || true
    chmod g+rwx "$REPO_DIR" 2>/dev/null || true
    # .git ディレクトリを全ユーザーから書き込み可能にする
    # refs/, worktrees/, packed-refs 等への書込みがブランチ操作に必要
    chmod -R a+rwx "${REPO_DIR}/.git" 2>/dev/null || true
    # git が新規作成するファイルも全ユーザーに書込み権限を付与する設定
    git -C "$REPO_DIR" config core.sharedRepository world 2>/dev/null || true

    # claude コマンドが /root/.local/bin にあるため、他ユーザーからアクセスできるようにする
    echo "[setup] Ensuring claude command is accessible to '${USER_NAME}'..."
    chmod 755 /root 2>/dev/null || true
    chmod 755 /root/.local 2>/dev/null || true
    chmod 755 /root/.local/bin 2>/dev/null || true

    # ユーザーの .bashrc に PATH と認証情報を追加（重複追加しない）
    USER_BASHRC="/home/${USER_NAME}/.bashrc"
    if ! grep -q '/root/.local/bin' "$USER_BASHRC" 2>/dev/null; then
        echo 'export PATH="/root/.local/bin:$PATH"' >> "$USER_BASHRC"
    fi

    # CLAUDE_CODE_OAUTH_TOKEN を .env から読み込んでセッションユーザーに設定
    CLAUDE_OAUTH_TOKEN=$(grep -oP '^CLAUDE_CODE_OAUTH_TOKEN="\K[^"]+' "$ENV_FILE" 2>/dev/null \
        || grep -oP '^CLAUDE_CODE_OAUTH_TOKEN=\K[^\s]+' "$ENV_FILE" 2>/dev/null || true)
    if [[ -n "$CLAUDE_OAUTH_TOKEN" ]] && ! grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$USER_BASHRC" 2>/dev/null; then
        echo "export CLAUDE_CODE_OAUTH_TOKEN=\"${CLAUDE_OAUTH_TOKEN}\"" >> "$USER_BASHRC"
    fi

    chown "$USER_NAME":"$USER_NAME" "$USER_BASHRC"

    # Claude Code の認証情報をユーザーにコピー
    # コピー元: 現在のユーザー（root）の設定を使用
    CLAUDE_CONFIG_SRC_DIR="${HOME}/.claude"
    CLAUDE_CONFIG_SRC_FILE="${HOME}/.claude.json"
    USER_HOME="/home/${USER_NAME}"

    if [[ -f "$CLAUDE_CONFIG_SRC_FILE" ]]; then
        echo "[setup] Copying Claude config to '${USER_NAME}'..."
        cp "$CLAUDE_CONFIG_SRC_FILE" "${USER_HOME}/.claude.json"
        chown "$USER_NAME":"$USER_NAME" "${USER_HOME}/.claude.json"
    fi

    if [[ -d "$CLAUDE_CONFIG_SRC_DIR" ]]; then
        echo "[setup] Copying Claude credentials to '${USER_NAME}'..."
        rm -rf "${USER_HOME}/.claude" 2>/dev/null || true
        cp -r "$CLAUDE_CONFIG_SRC_DIR" "${USER_HOME}/.claude"
        chown -R "$USER_NAME":"$USER_NAME" "${USER_HOME}/.claude"
    fi

    # ============================================================
    # Git safe.directory 設定（別ユーザーでの操作に必要）
    # ============================================================
    git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
    su -s /bin/bash "$USER_NAME" -c "git config --global --add safe.directory '$REPO_DIR'" 2>/dev/null || true

    # ============================================================
    # Create git worktree and install dependencies
    # ============================================================
    cd "$REPO_DIR"
    WORKTREE_DIR="${REPO_DIR}/.worktrees/${BRANCH_NAME}"

    # worktree が既に存在するか確認
    EXISTING_WORKTREE=$(git worktree list 2>/dev/null | grep "${BRANCH_NAME}" | awk '{print $1}') || true
    if [[ -n "$EXISTING_WORKTREE" && -d "$EXISTING_WORKTREE" ]]; then
        WORKTREE_DIR="$EXISTING_WORKTREE"
        echo "[setup] Worktree already exists at: ${WORKTREE_DIR}"
    else
        echo "[setup] Creating worktree at ${WORKTREE_DIR}..."
        mkdir -p "$(dirname "$WORKTREE_DIR")"
        # ブランチが既に存在する場合はチェックアウト、なければ新規作成
        if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}" 2>/dev/null; then
            git worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
        else
            git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" develop
        fi
    fi

    # worktree の所有権と safe.directory を設定
    chown -R "$USER_NAME":"$USER_NAME" "$WORKTREE_DIR" 2>/dev/null || true
    # メインリポジトリ内の worktree メタデータ (.git/worktrees/<name>) の所有権も変更
    # これがないとセッションユーザーが git checkout / git switch できない
    GIT_WORKTREE_META="${REPO_DIR}/.git/worktrees/${BRANCH_NAME}"
    if [[ -d "$GIT_WORKTREE_META" ]]; then
        chown -R "$USER_NAME":"$USER_NAME" "$GIT_WORKTREE_META" 2>/dev/null || true
    fi
    git config --global --add safe.directory "$WORKTREE_DIR" 2>/dev/null || true
    su -s /bin/bash "$USER_NAME" -c "git config --global --add safe.directory '$WORKTREE_DIR'" 2>/dev/null || true

    # メインリポジトリの gitignore されたファイルをシンボリックリンクで共有
    GITIGNORED_FILES=(
        ".env"
        ".claude/CLAUDE.local.md"
        ".claude/settings.local.json"
    )
    for rel_path in "${GITIGNORED_FILES[@]}"; do
        if [[ -f "${REPO_DIR}/${rel_path}" && ! -e "${WORKTREE_DIR}/${rel_path}" ]]; then
            mkdir -p "$(dirname "${WORKTREE_DIR}/${rel_path}")"
            echo "[setup] Linking ${rel_path} from main repo to worktree..."
            ln -s "${REPO_DIR}/${rel_path}" "${WORKTREE_DIR}/${rel_path}"
        fi
    done

    # 依存関係のインストール
    echo "[setup] Installing backend dependencies in worktree..."
    (cd "${WORKTREE_DIR}/backend" && uv sync 2>&1 | tail -3) || true

    echo "[setup] Installing frontend dependencies in worktree..."
    (cd "${WORKTREE_DIR}/frontend" && npm install 2>&1 | tail -3) || true

    # ============================================================
    # Deploy tmux config
    # ============================================================
    TMUX_CONF_SRC="${SCRIPT_DIR}/../configs/.tmux.conf"
    if [[ -f "$TMUX_CONF_SRC" ]]; then
        echo "[setup] Deploying .tmux.conf..."
        cp "$TMUX_CONF_SRC" /root/.tmux.conf
        cp "$TMUX_CONF_SRC" "${USER_HOME}/.tmux.conf"
        chown "$USER_NAME":"$USER_NAME" "${USER_HOME}/.tmux.conf"
    fi

    # ============================================================
    # Kill existing tmux session if it exists
    # ============================================================
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "[setup] Killing existing tmux session '${SESSION_NAME}'..."
        tmux kill-session -t "$SESSION_NAME"
    fi

    # ============================================================
    # Create tmux session with claude, backend, frontend windows
    # ============================================================

    # Window 0: Claude Code（worktree 内で起動）
    echo "[setup] Creating tmux session '${SESSION_NAME}'..."
    tmux new-session -d -s "$SESSION_NAME" -n "claude" -c "$WORKTREE_DIR"
    tmux send-keys -t "${SESSION_NAME}:claude" "su - ${USER_NAME}" C-m
    sleep 2
    tmux send-keys -t "${SESSION_NAME}:claude" "cd ${WORKTREE_DIR} && claude --dangerously-skip-permissions" C-m

    # Bypass Permissions の確認画面で「2. Yes, I accept」を自動選択
    sleep 3
    tmux send-keys -t "${SESSION_NAME}:claude" "2" Enter

    # ============================================================
    # Auth URL watcher: 認証URLをSlackに送信（バックグラウンド常駐）
    # 通常は30秒間隔で軽く監視し、認証キーワード検出時のみ3秒間隔に切替
    # ============================================================
    (
        AUTH_INTERVAL_IDLE=30
        AUTH_INTERVAL_ACTIVE=3
        AUTH_LAST_SENT=""
        while tmux has-session -t "${SESSION_NAME}" 2>/dev/null; do
            PANE_CONTENT=$(tmux capture-pane -t "${SESSION_NAME}:claude" -p -J 2>/dev/null) || true
            # 認証関連のキーワードが画面にあるか確認
            if echo "$PANE_CONTENT" | grep -qiP '(login|auth|sign.?in|oauth|verify)'; then
                # 各行の末尾空白を除去→全行結合→URLを抽出（折り返しで分断されたURLを復元）
                AUTH_URL=$(echo "$PANE_CONTENT" \
                    | sed 's/[[:space:]]*$//' \
                    | tr -d '\n' \
                    | grep -oP 'https://[A-Za-z0-9_.~:/?#@!$&()*+,;%=\-]+' \
                    | head -1) || true
                if [[ -n "$AUTH_URL" && "$AUTH_URL" != "$AUTH_LAST_SENT" ]]; then
                    send_slack "$(cat <<AUTHEOF
{
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "[AUTH] Claude Code: ${BRANCH_NAME}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "認証が必要です。以下のURLをタップしてください:\n<${AUTH_URL}|認証URLを開く>"
            }
        }
    ]
}
AUTHEOF
                    )"
                    AUTH_LAST_SENT="$AUTH_URL"
                    echo "[auth-watcher] Auth URL sent to Slack: ${AUTH_URL}"
                fi
                sleep "$AUTH_INTERVAL_ACTIVE"
            else
                sleep "$AUTH_INTERVAL_IDLE"
            fi
        done
        echo "[auth-watcher] Session ended. Stopping watcher."
    ) &
    echo $! > "${STATE_DIR}/auth-watcher.pid"

    # Window 1: Backend
    tmux new-window -t "$SESSION_NAME" -n "backend" -c "${WORKTREE_DIR}/backend"
    echo "[backend] Starting backend on port ${BACKEND_PORT}..."
    tmux send-keys -t "${SESSION_NAME}:backend" \
        "cd ${WORKTREE_DIR}/backend && ${BACKEND_CMD}" C-m

    # Window 2: Frontend (cloudflare URL取得後に起動)
    tmux new-window -t "$SESSION_NAME" -n "frontend" -c "${WORKTREE_DIR}/frontend"
    tmux send-keys -t "${SESSION_NAME}:frontend" \
        "echo 'Waiting for backend cloudflare URL...'" C-m

    # ============================================================
    # Start cloudflared tunnels (background)
    # ============================================================
    echo "[cloudflare] Starting tunnel for ttyd (port ${TTYD_PORT})..."
    cloudflared tunnel --url "http://localhost:${TTYD_PORT}" \
        --no-autoupdate \
        2>"${TUNNEL_LOG_DIR}/ttyd.log" &
    echo $! > "${STATE_DIR}/cloudflared-ttyd.pid"

    echo "[cloudflare] Starting tunnel for backend (port ${BACKEND_PORT})..."
    cloudflared tunnel --url "http://localhost:${BACKEND_PORT}" \
        --no-autoupdate \
        2>"${TUNNEL_LOG_DIR}/backend.log" &
    echo $! > "${STATE_DIR}/cloudflared-backend.pid"

    echo "[cloudflare] Starting tunnel for frontend (port ${FRONTEND_PORT})..."
    cloudflared tunnel --url "http://localhost:${FRONTEND_PORT}" \
        --no-autoupdate \
        2>"${TUNNEL_LOG_DIR}/frontend.log" &
    echo $! > "${STATE_DIR}/cloudflared-frontend.pid"

    # ============================================================
    # Wait for tunnel URLs
    # ============================================================
    get_tunnel_url() {
        local log_file="$1"
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local url
            url=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1) || true
            if [[ -n "$url" ]]; then
                echo "$url"
                return 0
            fi
            sleep 1
            waited=$((waited + 1))
        done
        echo ""
        return 1
    }

    echo "[cloudflare] Waiting for tunnel URLs..."

    TTYD_URL=$(get_tunnel_url "${TUNNEL_LOG_DIR}/ttyd.log") || true
    BACKEND_URL=$(get_tunnel_url "${TUNNEL_LOG_DIR}/backend.log") || true
    FRONTEND_URL=$(get_tunnel_url "${TUNNEL_LOG_DIR}/frontend.log") || true

    echo "[cloudflare] ttyd URL:     ${TTYD_URL:-FAILED}"
    echo "[cloudflare] Backend URL:  ${BACKEND_URL:-FAILED}"
    echo "[cloudflare] Frontend URL: ${FRONTEND_URL:-FAILED}"

    # Save URLs for reference
    cat > "${STATE_DIR}/urls" <<EOF
TTYD_URL=${TTYD_URL:-}
BACKEND_URL=${BACKEND_URL:-}
FRONTEND_URL=${FRONTEND_URL:-}
EOF

    # ============================================================
    # Start frontend with backend URL
    # ============================================================
    tmux send-keys -t "${SESSION_NAME}:frontend" C-c
    sleep 1
    if [[ -n "$BACKEND_URL" ]]; then
        echo "[frontend] Starting frontend with VITE_API_URL=${BACKEND_URL}..."
        tmux send-keys -t "${SESSION_NAME}:frontend" \
            "VITE_API_URL=${BACKEND_URL} ${FRONTEND_CMD}" C-m
    else
        echo "[frontend] Warning: Backend URL not available. Starting frontend without API URL..."
        tmux send-keys -t "${SESSION_NAME}:frontend" "${FRONTEND_CMD}" C-m
    fi

    # ============================================================
    # Start ttyd → Claude Code 専用セッションのみ公開
    # ============================================================
    echo "[ttyd] Starting ttyd on port ${TTYD_PORT}..."
    tmux select-window -t "${SESSION_NAME}:claude"
    ttyd -p "$TTYD_PORT" -W tmux attach-session -t "${SESSION_NAME}:claude" &
    echo $! > "${STATE_DIR}/ttyd.pid"

    # ============================================================
    # Send Slack notification (開始)
    # ============================================================
    echo "[slack] Sending start notification..."
    send_slack "$(cat <<SLACKEOF
{
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "[STARTED] Claude Code Session: ${BRANCH_NAME}"
            }
        },
        {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": "*Terminal (Claude Code):*\n<${TTYD_URL:-N/A}|Open Terminal>"
                },
                {
                    "type": "mrkdwn",
                    "text": "*Frontend:*\n<${FRONTEND_URL:-N/A}|Open Frontend>"
                },
                {
                    "type": "mrkdwn",
                    "text": "*Backend API:*\n<${BACKEND_URL:-N/A}|Open API>"
                },
                {
                    "type": "mrkdwn",
                    "text": "*Branch:*\n\`${BRANCH_NAME}\`"
                }
            ]
        }
    ]
}
SLACKEOF
    )"

    # ============================================================
    # Summary and attach to Claude Code session
    # ============================================================
    echo ""
    echo "============================================================"
    echo "  Session '${BRANCH_NAME}' is ready!"
    echo "  User:     ${USER_NAME}"
    echo "  Terminal: ${TTYD_URL:-N/A}"
    echo "  Frontend: ${FRONTEND_URL:-N/A}"
    echo "  Backend:  ${BACKEND_URL:-N/A}"
    echo "  Ports:    ttyd=${TTYD_PORT} backend=${BACKEND_PORT} frontend=${FRONTEND_PORT}"
    echo ""
    echo "  tmux attach -t ${SESSION_NAME}"
    echo "============================================================"
    echo ""

    # Claude Code セッションにアタッチ（フルスクリーンで Claude Code のみ表示）
    exec tmux attach-session -t "${SESSION_NAME}:claude"
}

# ============================================================
# Main dispatch
# ============================================================
case "$MODE" in
    -c)
        do_create
        ;;
    -r)
        do_remove
        ;;
    *)
        usage
        ;;
esac
