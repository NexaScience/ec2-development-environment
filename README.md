# EC2 Development Environment

AWS EC2上にClaude Codeの並列開発環境を自動構築するTerraformプロジェクト。

指定したアプリケーションリポジトリをEC2にクローンし、そのリポジトリのDevcontainer内でClaude Codeセッションを複数同時に起動する。各セッションはttyd + cloudflared Quick Tunnelでブラウザからアクセス可能になり、URLはSlackに自動通知される。

## アーキテクチャ

```
┌──────────────────────────────────────────────────────────────┐
│ EC2 Instance (Ubuntu 24.04)                                  │
│                                                              │
│  /home/ubuntu/app ← git clone (アプリリポジトリ)               │
│  /home/ubuntu/ec2-development-environment ← インフラ           │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │ Dev Container (アプリ側の .devcontainer/)             │     │
│  │                                                     │     │
│  │  tmux session: feature-xyz                          │     │
│  │    ├── window claude   ─► claude (acceptEdits)      │     │
│  │    ├── window backend  ─► uvicorn (port auto)       │     │
│  │    └── window frontend ─► npm run dev (port auto)   │     │
│  │                                                     │     │
│  │  ttyd ─► tmux session ─► cloudflared ─► ブラウザ     │     │
│  │  cloudflared ─► backend tunnel                      │     │
│  │  cloudflared ─► frontend tunnel                     │     │
│  │                                                     │     │
│  │  Slack通知: ttyd URL + frontend URL                 │     │
│  └─────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

## 前提条件

- Terraform >= 1.5.0
- AWSアカウントとアクセスキー
- SSHキーペア
- 対象アプリケーションリポジトリに `.devcontainer/` が含まれていること
  - コンテナ内に以下がインストールされていること: Claude Code CLI, tmux, ttyd, cloudflared
- Slack Incoming Webhook URL

## セットアップ

### 1. 変数の設定

`.env` ファイルにAWSクレデンシャルとTerraform変数を設定する。

```bash
cp .env.example .env
# .env を編集
```

`.env` の内容:

```bash
# AWS credentials
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"

# Terraform variables (TF_VAR_ prefix)
TF_VAR_ALLOWED_SSH_CIDR="203.0.113.0/32"
TF_VAR_SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."
TF_VAR_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T.../B.../..."
TF_VAR_GIT_REPO_URL="https://github.com/your-org/your-app.git"
TF_VAR_INFRA_REPO_URL="https://github.com/your-org/ec2-development-environment.git"
TF_VAR_INSTANCE_TYPE="t3.xlarge"
TF_VAR_ROOT_VOLUME_SIZE="100"
```

Terraform実行前に環境変数をエクスポートする:

```bash
set -a && source .env && set +a
```

### 2. 変数一覧

| .env変数名 | 説明 | デフォルト | 必須 |
|------------|------|-----------|------|
| `AWS_ACCESS_KEY_ID` | AWSアクセスキーID | - | **必須** |
| `AWS_SECRET_ACCESS_KEY` | AWSシークレットアクセスキー | - | **必須** |
| `TF_VAR_ALLOWED_SSH_CIDR` | SSH接続を許可するCIDR | - | **必須** |
| `TF_VAR_SSH_PUBLIC_KEY` | EC2アクセス用SSH公開鍵 | - | **必須** |
| `TF_VAR_GIT_REPO_URL` | クローンするアプリリポジトリURL（`.devcontainer/` を含むこと） | - | **必須** |
| `TF_VAR_INFRA_REPO_URL` | このインフラリポジトリのURL（EC2にクローンしスクリプトを利用） | - | **必須** |
| `TF_VAR_SLACK_WEBHOOK_URL` | Slack通知用Webhook URL | - | **必須** |
| `TF_VAR_INSTANCE_TYPE` | EC2インスタンスタイプ | `t3.xlarge` | - |
| `TF_VAR_ROOT_VOLUME_SIZE` | ルートEBSボリュームサイズ (GB) | `100` | - |

### 3. デプロイ

```bash
set -a && source .env && set +a
terraform init
terraform apply
```

## 使い方

### 1. VS CodeからSSHでEC2に接続

VS Codeの Remote-SSH 拡張機能でEC2インスタンスに接続し、Devcontainerを起動する。

### 2. Claude Codeの認証（初回のみ）

```bash
claude login
```

### 3. セッション起動

```bash
# セッション作成
~/scripts/start-claude-sessions.sh -c <session-name>

# セッション削除
~/scripts/start-claude-sessions.sh -r <session-name>
```

`-c` により以下が実行される:

1. tmuxセッション `<session-name>` を作成（3ウィンドウ構成）
   - `claude`: `claude --permission-mode acceptEdits` を起動
   - `backend`: uvicornでバックエンドを起動（空きポート自動検出）
   - `frontend`: `npm run dev` でフロントエンドを起動（`VITE_API_BASE_URL` にバックエンドtunnel URLを自動設定）
2. ttydでtmuxセッションをWebターミナルとして公開
3. cloudflared Quick Tunnelでttyd / backend / frontendをそれぞれ公開
4. Claude操作用URL（ttyd）とフロントエンドURLをSlackに通知
5. `.claude/CLAUDE.local.md` を自動生成（Claude Codeがバックエンド/フロントエンドのログを `tmux capture-pane` で参照できるようにする）

`-r` により以下が実行される:

- tmuxセッション、ttyd、cloudflared全プロセスをkill
- 関連ログファイルを削除

### 4. セッションの確認

```bash
# tmuxセッションにアタッチ
tmux attach -t <session-name>

# ウィンドウ切替: Ctrl+B → 0(claude), 1(backend), 2(frontend)

# デタッチして戻る: Ctrl+B → D
```

### 5. Claude Codeからログを確認

Claude Codeは同一tmuxセッション内の他ウィンドウのログを読み取れる:

```bash
# バックエンドのログをキャプチャ
tmux capture-pane -t <session-name>:backend -p

# フロントエンドのログをキャプチャ
tmux capture-pane -t <session-name>:frontend -p
```

## 自動処理の流れ

EC2インスタンス起動時に `user_data` で以下が自動実行される:

1. システムパッケージのインストール（curl, git, jq, etc.）
2. Docker Engineのインストール
3. Node.js 22 + `@devcontainers/cli` のインストール
4. 環境変数ファイル（`.claude-env`）の作成（`WORKSPACE_DIR` を自動算出）
5. アプリリポジトリのクローン（`/home/ubuntu/<repo-name>`）
6. `devcontainer up` でDevcontainerをビルド・起動
7. コンテナ内にインフラリポジトリをクローン（`/root/ec2-development-environment`）
8. `~/scripts` → インフラリポの `scripts/` へシンボリックリンク作成
9. Slack起動通知の送信

### Slack通知

以下のタイミングでSlackに通知が送られる:

- **EC2起動時**: インスタンスのIPアドレスとSSH接続コマンド
- **セッション起動時**: Claude操作用URL（ttyd）とフロントエンドURL

## スクリプト一覧

| スクリプト | 場所 | 説明 |
|-----------|------|------|
| `setup.sh` | EC2 user_data | インスタンス初期化（Terraformテンプレート） |
| `start-claude-sessions.sh` | コンテナ内 `~/scripts/` | tmuxセッションでClaude Code + FE/BEを起動し、ttyd + cloudflaredで公開 |
| `send-slack-notification.sh` | コンテナ内 `~/scripts/` | Slack Webhookへのメッセージ送信 |

## GitHub Actions

`.github/workflows/ec2.yml` により、GitHub Actionsから手動でインスタンスの作成・破棄が可能。

### 必要なSecrets

| Secret名 | 説明 |
|----------|------|
| `AWS_ACCESS_KEY_ID` | AWSアクセスキーID |
| `AWS_SECRET_ACCESS_KEY` | AWSシークレットアクセスキー |
| `TF_VAR_ALLOWED_SSH_CIDR` | SSH許可CIDR |
| `TF_VAR_SSH_PUBLIC_KEY` | SSH公開鍵 |
| `TF_VAR_SLACK_WEBHOOK_URL` | Slack Webhook URL |
| `TF_VAR_GIT_REPO_URL` | アプリリポジトリURL |
| `TF_VAR_INFRA_REPO_URL` | インフラリポジトリURL |

### 実行方法

GitHub上で **Actions** > **EC2 Instance Management** > **Run workflow** から `create` または `destroy` を選択して実行。

## AWSリソース

Terraformで作成されるリソース:

- VPC + パブリックサブネット + インターネットゲートウェイ
- セキュリティグループ（SSH: 指定CIDR、アウトバウンド: 全許可）
- EC2インスタンス（Ubuntu 24.04 LTS, gp3暗号化EBS, IMDSv2強制）
- キーペア

## 注意事項

- `user_data` はインスタンスの **初回起動時のみ** 実行される。Terraform変数の変更後は `terraform apply` でインスタンスを再作成する必要がある
- スクリプトの変更は `git pull` で反映可能（シンボリックリンク経由で `~/scripts/` が自動的に更新される）
- `.env` は `.gitignore` に含まれており、リポジトリにはコミットされない
- `--permission-mode acceptEdits` によりClaude Codeはファイル編集を自動承認する。Bashコマンドは都度確認を求める
