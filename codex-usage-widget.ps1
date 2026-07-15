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

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 Title="Codex 用量" Width="272" Height="122" WindowStyle="None" ResizeMode="NoResize"
 AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
 FontFamily="Segoe UI Variable Text, Segoe UI">
 <Border CornerRadius="12" Background="#FFF9F7F3" BorderBrush="#FFE2DED7" BorderThickness="1" Padding="13,10,13,9">
  <Grid>
   <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="62"/><RowDefinition Name="SecondaryRowDefinition" Height="0"/><RowDefinition Height="16"/></Grid.RowDefinitions>
   <StackPanel Grid.Row="0" Orientation="Horizontal" VerticalAlignment="Center">
    <TextBlock Text="Codex 用量" Foreground="#FF252525" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
   </StackPanel>
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

$window.Add_MouseLeftButtonDown({ if ($_.ButtonState -eq 'Pressed') { $window.DragMove() } })
$workArea = [System.Windows.SystemParameters]::WorkArea
$window.Left = $workArea.Right - $window.Width - 14
$window.Top = $workArea.Bottom - $window.Height - 14
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([math]::Max(5, $RefreshSeconds))
$timer.Add_Tick({ Update-Widget }); $timer.Start()
Update-Widget
[void]$window.ShowDialog()
