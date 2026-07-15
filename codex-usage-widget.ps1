param([int]$RefreshSeconds = 10)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:CodexHome = Join-Path $env:USERPROFILE '.codex'

function Get-FastTailLines([string]$Path, [int]$MaxBytes = 8388608) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [math]::Max(0, $stream.Length - $MaxBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 65536, $true)
        try {
            $text = $reader.ReadToEnd()
        } finally { $reader.Dispose() }
        $lines = @($text -split "`r?`n")
        if ($start -gt 0 -and $lines.Count -gt 1) { return @($lines[1..($lines.Count - 1)]) }
        return $lines
    } finally { $stream.Dispose() }
}

function Get-LatestRateLimits {
    $roots = @((Join-Path $script:CodexHome 'sessions'), (Join-Path $script:CodexHome 'archived_sessions')) |
        Where-Object { Test-Path -LiteralPath $_ }
    $files = Get-ChildItem -LiteralPath $roots -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3
    $best = $null
    foreach ($file in $files) {
        $lines = @(Get-FastTailLines $file.FullName)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -notmatch '"type":"token_count"' -or $lines[$i] -notmatch '"rate_limits"') { continue }
            try {
                $record = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
                $limits = $record.payload.rate_limits
                if (-not $limits -or -not $limits.primary) { continue }
                $candidate = [pscustomobject]@{ Timestamp = [datetime]$record.timestamp; Limits = $limits }
                if (-not $best -or $candidate.Timestamp -gt $best.Timestamp) { $best = $candidate }
                break
            } catch { $script:LastParseError = $_.Exception.Message }
        }
        # Files are ordered by modification time. Once the newest file with
        # valid limits is found, older sessions cannot improve the result.
        if ($best) { break }
    }
    $best
}

if ($env:CODEX_USAGE_WIDGET_TEST -eq '1') {
    $testResult = Get-LatestRateLimits
    if ($testResult) { $testResult | ConvertTo-Json -Depth 8 } else {
        'NO_DATA'
        $debugFile = Get-ChildItem (Join-Path $script:CodexHome 'sessions') -Filter '*.jsonl' -File -Recurse |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        "DEBUG_FILE=$($debugFile.FullName)"
        $debugLines = @(Get-FastTailLines $debugFile.FullName)
        "DEBUG_LINES=$($debugLines.Count)"
        "TOKEN_MATCHES=$(@($debugLines | Where-Object { $_ -match 'token_count' }).Count)"
        "EXACT_TOKEN_MATCHES=$(@($debugLines | Where-Object { $_ -match '"type":"token_count"' }).Count)"
        "LIMIT_MATCHES=$(@($debugLines | Where-Object { $_ -match 'rate_limits' }).Count)"
        "PARSE_ERROR=$script:LastParseError"
    }
    exit
}

function Get-WindowLabel([int]$minutes) {
    switch ($minutes) {
        300 { '5 小时' }
        10080 { '1 周' }
        default {
            if ($minutes -ge 1440 -and $minutes % 1440 -eq 0) { "$([int]($minutes / 1440)) 天" }
            elseif ($minutes -ge 60 -and $minutes % 60 -eq 0) { "$([int]($minutes / 60)) 小时" }
            else { "$minutes 分钟" }
        }
    }
}

function Get-ResetText($unixSeconds) {
    if (-not $unixSeconds) { return '重置时间未知' }
    try {
        $local = [DateTimeOffset]::FromUnixTimeSeconds([long]$unixSeconds).LocalDateTime
        $span = $local - (Get-Date)
        if ($span.TotalSeconds -le 0) { return '即将重置' }
        if ($span.TotalDays -ge 1) { return ('{0:M月d日 HH:mm} · {1}天{2}小时' -f $local, [math]::Floor($span.TotalDays), $span.Hours) }
        return ('{0:HH:mm} · {1}小时{2}分' -f $local, [math]::Floor($span.TotalHours), $span.Minutes)
    } catch { return '重置时间未知' }
}

function Get-QuestionSummary([string]$Message, [int]$MaxLength = 110) {
    if (-not $Message) { return '（图片或附件提问）' }
    $question = $Message
    $attachments = @()

    if ($Message -match '(?s)# Files mentioned by the user:(.*?)(?:## My request for Codex:|$)') {
        $fileBlock = $matches[1]
        $attachments = @([regex]::Matches($fileBlock, '(?m)^##\s+([^:\r\n]+):\s+.+$') | ForEach-Object { $_.Groups[1].Value.Trim() })
        if ($Message -match '(?s)## My request for Codex:\s*(.*)$') { $question = $matches[1] }
        else { $question = '' }
    }

    $question = ($question -replace '\s+', ' ').Trim()
    $attachmentText = ''
    if ($attachments.Count -gt 0) {
        $shown = @($attachments | Select-Object -First 2)
        $attachmentText = '附件：' + ($shown -join '、')
        if ($attachments.Count -gt 2) { $attachmentText += ' 等' + $attachments.Count + '个文件' }
    }
    if (-not $question) { $question = '仅上传文件' }
    if ($attachmentText) { $question += '（' + $attachmentText + '）' }
    if ($question.Length -gt $MaxLength) { $question = $question.Substring(0, $MaxLength) + '…' }
    $question
}

function Get-UsageLogs([int]$MaxItems = 100) {
    $titleMap = @{}
    $sessionIndex = Join-Path $script:CodexHome 'session_index.jsonl'
    if (Test-Path -LiteralPath $sessionIndex) {
        foreach ($indexLine in [IO.File]::ReadAllLines($sessionIndex, [Text.Encoding]::UTF8)) {
            try {
                $indexRecord = $indexLine | ConvertFrom-Json -ErrorAction Stop
                if ($indexRecord.id -and $indexRecord.thread_name) {
                    $titleMap[[string]$indexRecord.id] = ([string]$indexRecord.thread_name -replace '\s+', ' ').Trim()
                }
            } catch { }
        }
    }
    $roots = @((Join-Path $script:CodexHome 'sessions'), (Join-Path $script:CodexHome 'archived_sessions')) |
        Where-Object { Test-Path -LiteralPath $_ }
    $files = Get-ChildItem -LiteralPath $roots -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 10
    $items = New-Object Collections.Generic.List[object]

    foreach ($file in $files) {
        $current = $null
        $sessionId = if ($file.BaseName -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { $matches[1] } else { $file.BaseName }
        $sessionTitle = if ($titleMap.ContainsKey($sessionId)) { $titleMap[$sessionId] } else { $null }
        foreach ($line in Get-FastTailLines $file.FullName 8388608) {
            if ($line -notmatch '"user_message"|"token_count"') { continue }
            try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($record.type -ne 'event_msg') { continue }

            if ($record.payload.type -eq 'user_message') {
                if ($current -and $current.Tokens -gt 0) { $items.Add([pscustomobject]$current) }
                $message = Get-QuestionSummary ([string]$record.payload.message)
                $current = [ordered]@{
                    SessionKey = $sessionId
                    SessionTitle = $sessionTitle
                    Start = ([datetime]$record.timestamp).ToLocalTime()
                    End = ([datetime]$record.timestamp).ToLocalTime()
                    Question = $message
                    Tokens = [long]0
                    InputTokens = [long]0
                    OutputTokens = [long]0
                    RemainingPercent = $null
                }
            } elseif ($record.payload.type -eq 'token_count' -and $current -and $record.payload.info.last_token_usage) {
                $usage = $record.payload.info.last_token_usage
                $current.Tokens += [long]$usage.total_tokens
                $current.InputTokens += [long]$usage.input_tokens
                $current.OutputTokens += [long]$usage.output_tokens
                if ($record.payload.rate_limits.primary.used_percent -ne $null) {
                    $current.RemainingPercent = [math]::Max(0, 100 - [double]$record.payload.rate_limits.primary.used_percent)
                }
                $current.End = ([datetime]$record.timestamp).ToLocalTime()
            }
        }
        if ($current -and $current.Tokens -gt 0) { $items.Add([pscustomobject]$current) }
    }

    $ordered = @($items | Sort-Object Start)
    $previousRemaining = $null
    foreach ($item in $ordered) {
        $quotaShare = '—'
        if ($item.RemainingPercent -ne $null -and $previousRemaining -ne $null) {
            if ($item.RemainingPercent -gt $previousRemaining) { $quotaShare = '重置' }
            else { $quotaShare = '{0:N0}%' -f ($previousRemaining - $item.RemainingPercent) }
        }
        $item | Add-Member -NotePropertyName QuotaShare -NotePropertyValue $quotaShare -Force
        if ($item.RemainingPercent -ne $null) { $previousRemaining = $item.RemainingPercent }
    }
    $selected = @($ordered | Sort-Object Start -Descending | Select-Object -First $MaxItems)
    foreach ($item in $selected) {
        [pscustomobject]@{
            SessionKey = $item.SessionKey
            SessionTitle = $item.SessionTitle
            Date = $item.Start.ToString('yyyy-MM-dd')
            StartIso = $item.Start.ToString('o')
            TimeRange = if ($item.Start.Date -eq $item.End.Date) {
                '{0:MM-dd HH:mm:ss}–{1:HH:mm:ss}' -f $item.Start, $item.End
            } else { '{0:MM-dd HH:mm}–{1:MM-dd HH:mm}' -f $item.Start, $item.End }
            Question = $item.Question
            Tokens = $item.Tokens
            Input = $item.InputTokens
            Output = $item.OutputTokens
            Share = $item.QuotaShare
            Remaining = if ($item.RemainingPercent -ne $null) { '{0:N0}%' -f $item.RemainingPercent } else { '—' }
        }
    }
}

if ($env:CODEX_USAGE_WIDGET_LOG_EXPORT -eq '1') {
    @(Get-UsageLogs) | ConvertTo-Json -Depth 4 -Compress
    exit
}

function Show-UsageLogWindow {
    if ($script:LogWindow -and $script:LogWindow.IsVisible) {
        $script:LogWindow.Activate()
        return
    }
    [xml]$logXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 Title="Codex Token 日志" Width="900" Height="520" MinWidth="720" MinHeight="360"
 WindowStartupLocation="CenterScreen" Background="#FFF9F7F3" ShowInTaskbar="False"
 FontFamily="Segoe UI Variable Text, Segoe UI">
 <Grid Margin="16">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Grid Grid.Row="0" Margin="0,0,0,12">
   <StackPanel>
    <TextBlock Text="Token 使用日志" FontSize="18" FontWeight="SemiBold" Foreground="#FF252525"/>
    <TextBlock Text="同一提问触发的多次模型调用已合并；占比表示该次提问消耗的配额百分点。" FontSize="11" Foreground="#FF747474" Margin="0,4,0,0"/>
   </StackPanel>
   <Button Name="ReloadLogButton" Content="刷新" HorizontalAlignment="Right" Width="64" Height="28" Background="#FFFFFFFF" BorderBrush="#FFD8D4CE"/>
  </Grid>
  <DataGrid Name="LogGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
   GridLinesVisibility="Horizontal" HeadersVisibility="Column" RowHeaderWidth="0" Background="#FFFFFFFF"
   BorderBrush="#FFE2DED7" AlternatingRowBackground="#FFFAF9F7" RowHeight="34">
   <DataGrid.Columns>
    <DataGridTextColumn Header="时间段" Binding="{Binding TimeRange}" Width="175"/>
    <DataGridTextColumn Header="提问" Binding="{Binding Question}" Width="*"/>
    <DataGridTextColumn Header="Token" Binding="{Binding Tokens, StringFormat=N0}" Width="90"/>
    <DataGridTextColumn Header="输入" Binding="{Binding Input, StringFormat=N0}" Width="85"/>
    <DataGridTextColumn Header="输出" Binding="{Binding Output, StringFormat=N0}" Width="85"/>
    <DataGridTextColumn Header="占比" Binding="{Binding Share}" Width="75"/>
    <DataGridTextColumn Header="剩余" Binding="{Binding Remaining}" Width="75"/>
   </DataGrid.Columns>
  </DataGrid>
  <Border Grid.Row="2" Margin="0,10,0,0" Padding="10,8" CornerRadius="7" Background="#FFF1EEE8" BorderBrush="#FFE2DED7" BorderThickness="1">
   <TextBlock Name="TaskSummary" TextWrapping="Wrap" Foreground="#FF444444" FontSize="11" LineHeight="19"/>
  </Border>
  <TextBlock Name="LogSummary" Grid.Row="3" Margin="0,8,0,0" Foreground="#FF747474" FontSize="11"/>
 </Grid>
</Window>
'@
    $script:LogWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $logXaml))
    $script:LogGrid = $script:LogWindow.FindName('LogGrid')
    $script:LogSummary = $script:LogWindow.FindName('LogSummary')
    $script:TaskSummary = $script:LogWindow.FindName('TaskSummary')
    $script:LogWindow.Show()

    $reload = {
        if ($script:LogLoadProcess -and -not $script:LogLoadProcess.HasExited) { return }
        $script:LogGrid.ItemsSource = $null
        $script:LogSummary.Text = '正在后台读取日志…'
        $script:TaskSummary.Text = '今日总结正在生成…'
        $script:LogTempFile = Join-Path $env:TEMP ('codex-usage-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:LogErrorFile = $script:LogTempFile + '.err'
        $environmentBackup = $env:CODEX_USAGE_WIDGET_LOG_EXPORT
        $env:CODEX_USAGE_WIDGET_LOG_EXPORT = '1'
        try {
            $script:LogLoadProcess = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $script:LogTempFile -RedirectStandardError $script:LogErrorFile `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
        } finally {
            if ($null -eq $environmentBackup) { Remove-Item Env:CODEX_USAGE_WIDGET_LOG_EXPORT -ErrorAction SilentlyContinue }
            else { $env:CODEX_USAGE_WIDGET_LOG_EXPORT = $environmentBackup }
        }
        $script:LogLoadStarted = Get-Date
        if ($script:LogPollTimer) { $script:LogPollTimer.Stop() }
        $script:LogPollTimer = New-Object Windows.Threading.DispatcherTimer
        $script:LogPollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:LogPollTimer.Add_Tick({
            if (-not $script:LogLoadProcess.HasExited) {
                if (((Get-Date) - $script:LogLoadStarted).TotalSeconds -gt 30) {
                    Stop-Process -Id $script:LogLoadProcess.Id -Force -ErrorAction SilentlyContinue
                    $script:LogPollTimer.Stop()
                    $script:LogSummary.Text = '日志读取超时，请点击刷新重试。'
                    $script:LogLoadProcess = $null
                }
                return
            }
            $script:LogPollTimer.Stop()
            try {
                $json = Get-Content -Raw -LiteralPath $script:LogTempFile -ErrorAction Stop
                $data = if ($json) { @($json | ConvertFrom-Json) } else { @() }
                $script:LogGrid.ItemsSource = $data
                $sum = ($data | Measure-Object Tokens -Sum).Sum
                $script:LogSummary.Text = '共 {0} 次提问 · 合计 {1:N0} Token · 最多显示最近 100 条' -f $data.Count, $sum
                $today = (Get-Date).ToString('yyyy-MM-dd')
                $todayRows = @($data | Where-Object Date -eq $today)
                $taskGroups = @($todayRows | Group-Object SessionKey)
                $taskNames = @($taskGroups | ForEach-Object {
                    $officialTitle = @($_.Group | Where-Object SessionTitle | Select-Object -First 1).SessionTitle
                    if ($officialTitle) { [string]$officialTitle }
                    else {
                        $fallback = [string](($_.Group | Sort-Object StartIso | Select-Object -First 1).Question)
                        ($fallback -replace '（附件：.*?）', '').Trim()
                    }
                })
                if ($taskNames.Count -eq 0) {
                    $script:TaskSummary.Text = '今日总结：暂未读取到今天的 Codex 任务。'
                } else {
                    $shownTasks = @($taskNames | Select-Object -First 6)
                    $parts = for ($i = 0; $i -lt $shownTasks.Count; $i++) {
                        $name = [string]$shownTasks[$i]
                        if ($name.Length -gt 45) { $name = $name.Substring(0, 45) + '…' }
                        '{0}. {1}' -f ($i + 1), $name
                    }
                    $lines = @('今日总结：大约做了 {0} 件事' -f $taskNames.Count) + $parts
                    if ($taskNames.Count -gt 6) { $lines += '另有 {0} 件未展开' -f ($taskNames.Count - 6) }
                    $script:TaskSummary.Text = $lines -join [Environment]::NewLine
                }
            } catch {
                $script:LogSummary.Text = '日志读取失败，请点击刷新重试。'
                $script:TaskSummary.Text = '今日总结生成失败。'
            } finally {
                Remove-Item -LiteralPath $script:LogTempFile, $script:LogErrorFile -Force -ErrorAction SilentlyContinue
                $script:LogLoadProcess = $null
            }
        })
        $script:LogPollTimer.Start()
    }
    $script:LogWindow.FindName('ReloadLogButton').Add_Click($reload)
    $script:LogWindow.Add_Closed({
        if ($script:LogPollTimer) { $script:LogPollTimer.Stop() }
        $script:LogGrid = $null
        $script:LogSummary = $null
        $script:TaskSummary = $null
        $script:LogWindow = $null
    })
    & $reload
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 Title="Codex 用量" Width="272" Height="122" WindowStyle="None" ResizeMode="NoResize"
 AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
 FontFamily="Segoe UI Variable Text, Segoe UI">
 <Border CornerRadius="12" Background="#FFF9F7F3" BorderBrush="#FFE2DED7" BorderThickness="1" Padding="13,10,13,9">
  <Grid>
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="62"/><RowDefinition Name="SecondaryRowDefinition" Height="0"/><RowDefinition Height="16"/></Grid.RowDefinitions>
   <Grid Grid.Row="0">
    <TextBlock Text="Codex 用量" Foreground="#FF252525" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
    <Button Name="LogButton" Content="日志" HorizontalAlignment="Right" Width="42" Height="22" FontSize="11"
     Foreground="#FF555555" Background="#FFFFFFFF" BorderBrush="#FFD8D4CE" BorderThickness="1"/>
   </Grid>
   <Grid Name="Row1" Grid.Row="1" Margin="0,3,0,0">
    <Grid.RowDefinitions><RowDefinition Height="22"/><RowDefinition Height="12"/><RowDefinition Height="22"/></Grid.RowDefinitions>
    <Grid Grid.Row="0">
     <TextBlock Name="Label1" Foreground="#FF5E5E5E" FontSize="11" VerticalAlignment="Center"/>
     <TextBlock Name="Value1" Foreground="#FF252525" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid>
    <ProgressBar Name="Bar1" Grid.Row="1" Height="5" Maximum="100" Foreground="#FF6E9FDB" Background="#FFE5E2DD" BorderThickness="0" VerticalAlignment="Center"/>
    <TextBlock Name="Reset1" Grid.Row="2" Foreground="#FF626262" FontSize="10" VerticalAlignment="Center"/>
   </Grid>
   <Grid Name="Row2" Grid.Row="2" Margin="0,3,0,0" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="22"/><RowDefinition Height="12"/><RowDefinition Height="22"/></Grid.RowDefinitions>
    <Grid Grid.Row="0">
     <TextBlock Name="Label2" Foreground="#FF5E5E5E" FontSize="11" VerticalAlignment="Center"/>
     <TextBlock Name="Value2" Foreground="#FF252525" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid>
    <ProgressBar Name="Bar2" Grid.Row="1" Height="5" Maximum="100" Foreground="#FF6E9FDB" Background="#FFE5E2DD" BorderThickness="0" VerticalAlignment="Center"/>
    <TextBlock Name="Reset2" Grid.Row="2" Foreground="#FF626262" FontSize="10" VerticalAlignment="Center"/>
   </Grid>
   <TextBlock Name="StatusText" Grid.Row="3" Foreground="#FF929292" FontSize="9" VerticalAlignment="Bottom"/>
  </Grid>
 </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$row1 = $window.FindName('Row1'); $row2 = $window.FindName('Row2')
$secondaryRowDefinition = $window.FindName('SecondaryRowDefinition')
$status = $window.FindName('StatusText')

function Set-UsageRow($number, $limit) {
    $remaining = [math]::Max(0, [math]::Round(100 - [double]$limit.used_percent))
    $window.FindName("Label$number").Text = Get-WindowLabel ([int]$limit.window_minutes)
    $window.FindName("Value$number").Text = "$remaining%"
    $window.FindName("Bar$number").Value = $remaining
    $window.FindName("Reset$number").Text = Get-ResetText $limit.resets_at
}

function Update-Widget {
    $latest = Get-LatestRateLimits
    if (-not $latest) {
        $window.FindName('Label1').Text = '用量'
        $window.FindName('Value1').Text = '--%'
        $window.FindName('Reset1').Text = '完成一次 Codex 请求后更新'
        $status.Text = '等待服务器返回用量数据'
        return
    }
    Set-UsageRow 1 $latest.Limits.primary
    if ($latest.Limits.secondary) {
        Set-UsageRow 2 $latest.Limits.secondary
        $secondaryRowDefinition.Height = [Windows.GridLength]::new(62)
        $row2.Visibility = 'Visible'; $window.Height = 184
    } else {
        $secondaryRowDefinition.Height = [Windows.GridLength]::new(0)
        $row2.Visibility = 'Collapsed'; $window.Height = 122
    }
    $status.Text = '更新于 ' + $latest.Timestamp.ToLocalTime().ToString('HH:mm:ss')
}

$window.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq 'Pressed' -and $_.OriginalSource -isnot [Windows.Controls.Button]) { $window.DragMove() }
})
$window.FindName('LogButton').Add_Click({ Show-UsageLogWindow })
$workArea = [System.Windows.SystemParameters]::WorkArea
$window.Left = $workArea.Right - $window.Width - 14
$window.Top = $workArea.Bottom - $window.Height - 14
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([math]::Max(5, $RefreshSeconds))
$timer.Add_Tick({ Update-Widget }); $timer.Start()
Update-Widget
[void]$window.ShowDialog()
