#!/bin/bash
# Claude Code Stats Reporter - ワンライナーインストーラー (macOS/Linux)
# 使い方: curl -sL https://raw.githubusercontent.com/xxx/claude-stats-reporter/main/install.sh | bash
set -euo pipefail

INSTALL_DIR="$HOME/.claude-stats-reporter"
PLIST_NAME="com.llm-monitor.claude-stats"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
ENDPOINT_URL="https://script.google.com/macros/s/AKfycbw5wNq1UEzjpQSiMn7s50y5vcbKbI9HHsH8IV8vErvrIFx27tq91IMe_OMQ3QuqIvfDww/exec"

echo "=== Claude Code Stats Reporter セットアップ ==="
echo ""

# 既存インストールの確認
if [[ -d "$INSTALL_DIR" ]]; then
    echo "既存のインストールが見つかりました: $INSTALL_DIR"
    read -rp "上書きしますか？ (y/N): " overwrite
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
        echo "中止しました。"
        exit 0
    fi
fi

# USERNAME の入力
read -rp "表示名を入力してください (例: taro): " input_username
if [[ -z "$input_username" ]]; then
    echo "エラー: 表示名は必須です。"
    exit 1
fi

input_endpoint="$ENDPOINT_URL"

# インストールディレクトリ作成
mkdir -p "$INSTALL_DIR"

# config 作成
cat > "$INSTALL_DIR/config" << EOF
USERNAME="$input_username"
ENDPOINT_URL="$input_endpoint"
EOF

# report.sh を埋め込み生成
cat > "$INSTALL_DIR/report.sh" << 'REPORT_SCRIPT'
#!/bin/bash
# Claude Code Stats Reporter - daily sender (macOS/Linux)
set -euo pipefail

source "$HOME/.claude-stats-reporter/config"
export USERNAME

LOG_FILE="$HOME/.claude-stats-reporter/last_run.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

PAYLOAD=$(python3 << 'PYEOF'
import json, os, glob, socket
from datetime import datetime, timedelta
from collections import defaultdict

projects_dir = os.path.expanduser("~/.claude/projects")
cutoff = (datetime.now() - timedelta(days=8)).strftime("%Y-%m-%d")
cutoff_ts = (datetime.now() - timedelta(days=8)).timestamp()

all_files = []
if os.path.isdir(projects_dir):
    for project_dir in glob.glob(os.path.join(projects_dir, "*/")):
        all_files.extend(glob.glob(os.path.join(project_dir, "*.jsonl")))
        all_files.extend(glob.glob(os.path.join(project_dir, "*/subagents/*.jsonl")))

recent_files = [f for f in all_files if os.path.getmtime(f) >= cutoff_ts]

daily = defaultdict(lambda: {
    "messages": 0, "sessions": 0, "tool_calls": 0,
    "tokens_by_model": defaultdict(int)
})

total_sessions = 0
total_messages = 0

for fpath in recent_files:
    is_subagent = "/subagents/" in fpath
    try:
        session_date = None
        msg_count = 0
        tool_count = 0
        tokens_by_model = defaultdict(int)

        with open(fpath) as f:
            for line in f:
                d = json.loads(line)
                t = d.get("type")

                if t in ("user", "assistant"):
                    if session_date is None:
                        ts = d.get("timestamp", "")
                        if isinstance(ts, str) and len(ts) >= 10:
                            session_date = ts[:10]
                    msg_count += 1

                if t == "assistant":
                    msg = d.get("message", {})
                    model = msg.get("model", "unknown")
                    usage = msg.get("usage", {})
                    tokens_by_model[model] += usage.get("output_tokens", 0)
                    content = msg.get("content", [])
                    for c in content:
                        if c.get("type") == "tool_use":
                            tool_count += 1

        if session_date and session_date >= cutoff:
            day = daily[session_date]
            if not is_subagent:
                day["sessions"] += 1
                total_sessions += 1
            day["messages"] += msg_count
            day["tool_calls"] += tool_count
            total_messages += msg_count
            for m, tok in tokens_by_model.items():
                day["tokens_by_model"][m] += tok
    except Exception:
        continue

daily_activity = []
daily_model_tokens = []
for date in sorted(daily.keys()):
    d = daily[date]
    daily_activity.append({
        "date": date,
        "messageCount": d["messages"],
        "sessionCount": d["sessions"],
        "toolCallCount": d["tool_calls"],
    })
    daily_model_tokens.append({
        "date": date,
        "tokensByModel": dict(d["tokens_by_model"]),
    })

payload = {
    "username": os.environ.get("USERNAME", "unknown"),
    "hostname": socket.gethostname(),
    "dailyActivity": daily_activity,
    "dailyModelTokens": daily_model_tokens,
    "totalSessions": total_sessions,
    "totalMessages": total_messages,
}
print(json.dumps(payload))
PYEOF
)

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$ENDPOINT_URL")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
    log "OK: sent (HTTP $HTTP_CODE)"
else
    log "ERROR: HTTP $HTTP_CODE"
fi
REPORT_SCRIPT

chmod +x "$INSTALL_DIR/report.sh"

echo ""
echo "ファイルを配置しました: $INSTALL_DIR"

# macOS の場合のみ LaunchAgent を設定
if [[ "$(uname)" == "Darwin" ]]; then
    # 既存の LaunchAgent をアンロード
    if launchctl list | grep -q "$PLIST_NAME" 2>/dev/null; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/report.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/stderr.log</string>
</dict>
</plist>
PLIST

    launchctl load "$PLIST_PATH"
    echo "LaunchAgent を登録しました（毎日 9:30 に自動実行）"
fi

echo ""
echo "=== テスト送信 ==="
echo ""
bash "$INSTALL_DIR/report.sh"
RESULT=$(tail -1 "$INSTALL_DIR/last_run.log" 2>/dev/null || echo "")
if [[ "$RESULT" == *"OK:"* ]]; then
    echo "OK: テスト送信に成功しました"
else
    echo "ERROR: テスト送信に失敗しました"
    echo "ログ: $RESULT"
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "手動で実行する場合:"
echo "  bash $INSTALL_DIR/report.sh"
echo ""
echo "ログの確認:"
echo "  cat $INSTALL_DIR/last_run.log"
