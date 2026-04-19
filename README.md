# Claude Code Stats Reporter

家族間で Claude Code の利用状況を共有するツール。

各 PC から日別の利用データを GAS 経由でスプレッドシートに蓄積し、週次ランキングを Slack に送信する。

## 全体構成

```
[各PC] report.sh / report.ps1
    ↓ HTTP POST (JSON)
[GAS] doPost → スプレッドシートに蓄積
    ↓
[GAS] 週次トリガー → ランキング集計 → Slack に送信
```

## セットアップ

### Step 1: GAS 側の準備（1回だけ）

#### 1-1. スプレッドシート作成

1. Google Drive で新規スプレッドシートを作成
2. シート名を `DailyActivity` にリネーム
3. ヘッダー行（1行目）に以下を入力:

| A | B | C | D | E | F | G | H |
|---|---|---|---|---|---|---|---|
| receivedAt | username | hostname | date | messageCount | sessionCount | toolCallCount | tokensByModel |

#### 1-2. Apps Script 設定

1. 「拡張機能 > Apps Script」を開く
2. `gas/code.gs` の内容を貼り付けて保存
3. 「デプロイ > 新しいデプロイ」で以下を設定:
   - 種類: ウェブアプリ
   - アクセスできるユーザー: 全員
4. デプロイして表示される URL をコピー（各 PC のセットアップで使用）

#### 1-3. Slack Webhook 設定

1. Slack App で Incoming Webhook を作成し、送信先チャンネルを選択
2. Webhook URL をコピー
3. Apps Script の画面で「プロジェクトの設定 > スクリプト プロパティ」を開く
4. プロパティを追加:
   - プロパティ: `SLACK_WEBHOOK_URL`
   - 値: コピーした Webhook URL

#### 1-4. 週次トリガー設定

1. Apps Script の画面で左メニューの「トリガー」を開く
2. 「トリガーを追加」をクリック
3. 以下を設定:
   - 実行する関数: `sendWeeklyRanking`
   - イベントのソース: 時間主導型
   - 時間ベースのトリガーのタイプ: 週ベースのタイマー
   - 曜日: 月曜日
   - 時刻: 午前 10 時〜 11 時

### Step 2: 各 PC にインストール

#### macOS / Linux

```bash
curl -sL https://raw.githubusercontent.com/oshou35/claude-stats-reporter/main/install.sh | bash
```

#### Windows

PowerShell を **管理者として** 開き:

```powershell
irm https://raw.githubusercontent.com/oshou35/claude-stats-reporter/main/install.ps1 | iex
```

対話形式で以下を入力:
- **表示名**: ランキングに表示される名前（例: `taro`）
- **GAS URL**: Step 1-2 でコピーした URL

<details>
<summary>git clone 方式（代替）</summary>

```bash
# macOS / Linux
git clone https://github.com/oshou35/claude-stats-reporter.git
cd claude-stats-reporter
bash setup.sh
```

```powershell
# Windows（管理者 PowerShell）
git clone https://github.com/oshou35/claude-stats-reporter.git
cd claude-stats-reporter
powershell -ExecutionPolicy Bypass -File setup.ps1
```

</details>

### 動作確認

インストール後、手動で実行して動作を確認:

```bash
# macOS / Linux
bash ~/.claude-stats-reporter/report.sh
cat ~/.claude-stats-reporter/last_run.log
```

```powershell
# Windows
powershell -File "$env:USERPROFILE\.claude-stats-reporter\report.ps1"
Get-Content "$env:USERPROFILE\.claude-stats-reporter\last_run.log"
```

ログに `OK: sent (HTTP 200)` または `OK: sent (HTTP 302)` と表示されれば成功。

## Slack 通知の例

```
📊 Weekly Claude Code Ranking (2026-04-13 〜 2026-04-19)

🥇 taro — 1,234,567 tokens (342 messages)
🥈 hanako — 987,654 tokens (215 messages)
🥉 jiro — 456,789 tokens (128 messages)
```

## 定期実行

| 対象 | 仕組み | タイミング |
|---|---|---|
| データ送信 (macOS) | LaunchAgent | 毎日 9:30 |
| データ送信 (Windows) | タスクスケジューラ | 毎日 9:30 |
| ランキング通知 | GAS トリガー | 毎週月曜 10:00 頃 |

## アンインストール

### macOS

```bash
launchctl unload ~/Library/LaunchAgents/com.llm-monitor.claude-stats.plist
rm ~/Library/LaunchAgents/com.llm-monitor.claude-stats.plist
rm -rf ~/.claude-stats-reporter
```

### Windows（管理者 PowerShell）

```powershell
Unregister-ScheduledTask -TaskName "ClaudeCodeStatsReporter" -Confirm:$false
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-stats-reporter"
```

## ファイル構成

```
~/work/claude-stats-reporter/    # リポジトリ（配布用）
├── README.md
├── gas/
│   └── code.gs                  # GAS コード（コピペ用）
├── setup.sh                     # macOS/Linux セットアップ
├── setup.ps1                    # Windows セットアップ
├── report.sh                    # macOS/Linux レポートスクリプト
└── report.ps1                   # Windows レポートスクリプト

~/.claude-stats-reporter/        # インストール先（各PC）
├── config / config.ps1          # USERNAME, ENDPOINT_URL
├── report.sh / report.ps1       # 送信スクリプト
├── last_run.log                 # 実行ログ
├── stdout.log                   # LaunchAgent stdout (macOS)
└── stderr.log                   # LaunchAgent stderr (macOS)
```

## 収集データ

`~/.claude/projects/` 配下の JSONL セッションファイルから過去 8 日分を集計:

| 項目 | 説明 |
|---|---|
| messageCount | user + assistant メッセージの合計数 |
| sessionCount | セッション数（サブエージェントを除く） |
| toolCallCount | ツール呼び出し回数 |
| tokensByModel | モデル別の output_tokens 合計 |
