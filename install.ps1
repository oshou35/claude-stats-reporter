# Claude Code Stats Reporter - ワンライナーインストーラー (Windows)
# 使い方: irm https://raw.githubusercontent.com/xxx/claude-stats-reporter/main/install.ps1 | iex
$ErrorActionPreference = "Stop"

$installDir = Join-Path $env:USERPROFILE ".claude-stats-reporter"
$taskName = "ClaudeCodeStatsReporter"
$endpointUrl = "https://script.google.com/macros/s/AKfycbw5wNq1UEzjpQSiMn7s50y5vcbKbI9HHsH8IV8vErvrIFx27tq91IMe_OMQ3QuqIvfDww/exec"

Write-Host "=== Claude Code Stats Reporter セットアップ ===" -ForegroundColor Cyan
Write-Host ""

# 既存インストールの確認
if (Test-Path $installDir) {
    Write-Host "既存のインストールが見つかりました: $installDir"
    $overwrite = Read-Host "上書きしますか？ (y/N)"
    if ($overwrite -ne "y" -and $overwrite -ne "Y") {
        Write-Host "中止しました。"
        return
    }
}

# USERNAME の入力
$inputUsername = Read-Host "表示名を入力してください (例: taro)"
if ([string]::IsNullOrWhiteSpace($inputUsername)) {
    Write-Host "エラー: 表示名は必須です。" -ForegroundColor Red
    return
}

$inputEndpoint = $endpointUrl

# インストールディレクトリ作成
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

# config.ps1 作成
@"
`$USERNAME = "$inputUsername"
`$ENDPOINT_URL = "$inputEndpoint"
"@ | Out-File -FilePath (Join-Path $installDir "config.ps1") -Encoding UTF8

# report.ps1 を埋め込み生成
@'
# Claude Code Stats Reporter - daily sender (Windows)
$ErrorActionPreference = "Stop"

$configPath = Join-Path $env:USERPROFILE ".claude-stats-reporter\config.ps1"
. $configPath

$logFile = Join-Path $env:USERPROFILE ".claude-stats-reporter\last_run.log"

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Out-File -Append -FilePath $logFile -Encoding UTF8
}

# Claude Code のプロジェクトディレクトリ
$projectsDir = Join-Path $env:USERPROFILE ".claude\projects"
if (-not (Test-Path $projectsDir)) {
    Write-Log "ERROR: projects dir not found"
    exit 1
}

$cutoff = (Get-Date).AddDays(-8).ToString("yyyy-MM-dd")
$cutoffTime = (Get-Date).AddDays(-8)

# JSONL ファイルを収集
$allFiles = @()
Get-ChildItem -Path $projectsDir -Directory | ForEach-Object {
    $allFiles += Get-ChildItem -Path $_.FullName -Filter "*.jsonl" -ErrorAction SilentlyContinue
    $subagentPath = Join-Path $_.FullName "*\subagents"
    $allFiles += Get-ChildItem -Path $subagentPath -Filter "*.jsonl" -ErrorAction SilentlyContinue
}

$recentFiles = $allFiles | Where-Object { $_.LastWriteTime -ge $cutoffTime }

# 集計
$daily = @{}
$totalSessions = 0
$totalMessages = 0

foreach ($file in $recentFiles) {
    $isSubagent = $file.FullName -match "\\subagents\\"
    try {
        $sessionDate = $null
        $msgCount = 0
        $toolCount = 0
        $tokensByModel = @{}

        foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $d = $line | ConvertFrom-Json

            if ($d.type -in @("user", "assistant")) {
                if ($null -eq $sessionDate -and $d.timestamp -and $d.timestamp.Length -ge 10) {
                    $sessionDate = $d.timestamp.Substring(0, 10)
                }
                $msgCount++
            }

            if ($d.type -eq "assistant" -and $d.message) {
                $model = if ($d.message.model) { $d.message.model } else { "unknown" }
                $outTokens = 0
                if ($d.message.usage -and $d.message.usage.output_tokens) {
                    $outTokens = [int]$d.message.usage.output_tokens
                }
                if (-not $tokensByModel.ContainsKey($model)) { $tokensByModel[$model] = 0 }
                $tokensByModel[$model] += $outTokens

                if ($d.message.content -is [array]) {
                    foreach ($c in $d.message.content) {
                        if ($c.type -eq "tool_use") { $toolCount++ }
                    }
                }
            }
        }

        if ($sessionDate -and $sessionDate -ge $cutoff) {
            if (-not $daily.ContainsKey($sessionDate)) {
                $daily[$sessionDate] = @{
                    messages = 0; sessions = 0; tool_calls = 0
                    tokens_by_model = @{}
                }
            }
            $day = $daily[$sessionDate]
            if (-not $isSubagent) {
                $day.sessions++
                $totalSessions++
            }
            $day.messages += $msgCount
            $day.tool_calls += $toolCount
            $totalMessages += $msgCount
            foreach ($m in $tokensByModel.Keys) {
                if (-not $day.tokens_by_model.ContainsKey($m)) { $day.tokens_by_model[$m] = 0 }
                $day.tokens_by_model[$m] += $tokensByModel[$m]
            }
        }
    } catch {
        continue
    }
}

# ペイロード構築
$dailyActivity = @()
$dailyModelTokens = @()
foreach ($date in ($daily.Keys | Sort-Object)) {
    $d = $daily[$date]
    $dailyActivity += @{
        date = $date
        messageCount = $d.messages
        sessionCount = $d.sessions
        toolCallCount = $d.tool_calls
    }
    $dailyModelTokens += @{
        date = $date
        tokensByModel = $d.tokens_by_model
    }
}

$payload = @{
    username = $USERNAME
    hostname = $env:COMPUTERNAME
    dailyActivity = $dailyActivity
    dailyModelTokens = $dailyModelTokens
    totalSessions = $totalSessions
    totalMessages = $totalMessages
} | ConvertTo-Json -Depth 5

# 送信
try {
    $response = Invoke-WebRequest -Uri $ENDPOINT_URL -Method POST `
        -ContentType "application/json" -Body $payload -UseBasicParsing
    Write-Log "OK: sent (HTTP $($response.StatusCode))"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    Write-Log "ERROR: HTTP $code"
}
'@ | Out-File -FilePath (Join-Path $installDir "report.ps1") -Encoding UTF8

Write-Host ""
Write-Host "ファイルを配置しました: $installDir"

# タスクスケジューラに登録
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$installDir\report.ps1`""

$trigger = New-ScheduledTaskTrigger -Daily -At "09:30"

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Claude Code の利用状況を GAS に送信" | Out-Null

Write-Host "タスクスケジューラに登録しました（毎日 9:30 に自動実行）"

Write-Host ""
Write-Host "=== テスト送信 ===" -ForegroundColor Cyan
Write-Host ""
& powershell -NoProfile -ExecutionPolicy Bypass -File "$installDir\report.ps1"
$logFile = Join-Path $installDir "last_run.log"
$result = Get-Content $logFile -Tail 1 -ErrorAction SilentlyContinue
if ($result -match "OK:") {
    Write-Host "OK: テスト送信に成功しました" -ForegroundColor Green
} else {
    Write-Host "ERROR: テスト送信に失敗しました" -ForegroundColor Red
    Write-Host "ログ: $result"
}

Write-Host ""
Write-Host "=== セットアップ完了 ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "手動で実行する場合:"
Write-Host "  powershell -File $installDir\report.ps1"
Write-Host ""
Write-Host "ログの確認:"
Write-Host "  Get-Content $installDir\last_run.log"
