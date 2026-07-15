# Codex Usage Widget

一个轻量的 Windows 桌面悬浮窗，用于直接查看 Codex 当前配额的剩余比例和重置时间。

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)

## 功能

- 显示 Codex 当前周期的剩余用量
- 显示配额重置时间和剩余时长
- 自动读取最新用量并定时刷新
- 始终置顶，可拖动到任意位置
- 无标题栏、无任务栏图标
- 无需安装第三方运行库
- 不访问额外网络接口，不上传本地数据

## 界面

窗口采用紧凑的浅色卡片设计。标题为“Codex 用量”，下方显示配额周期、剩余百分比、进度条、重置时间和数据更新时间。

## 环境要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更高版本
- 已安装并使用过 Codex 桌面端或 Codex CLI

悬浮窗从用户目录下的 `.codex/sessions` 和 `.codex/archived_sessions` 中读取 Codex 已写入的用量记录。首次使用前，请至少完成一次 Codex 请求。

## 使用方法

1. 下载或克隆本仓库。
2. 双击 `launch-widget.vbs`。
3. 按住悬浮窗空白区域即可拖动。

`launch-widget.vbs` 会以隐藏窗口方式启动 PowerShell，避免任务栏出现 PowerShell 图标。

也可以直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-usage-widget.ps1
```

## 创建桌面快捷方式

在仓库目录打开 PowerShell，执行：

```powershell
$launcher = (Resolve-Path '.\launch-widget.vbs').Path
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 用量悬浮窗.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$shortcut.Arguments = "`"$launcher`""
$shortcut.WorkingDirectory = Split-Path -Parent $launcher
$shortcut.Description = '打开 Codex 用量悬浮窗（无任务栏图标）'
$shortcut.Save()
```

## 刷新间隔

直接运行 PowerShell 脚本时，可以通过 `RefreshSeconds` 调整刷新间隔，最低为 5 秒：

```powershell
.\codex-usage-widget.ps1 -RefreshSeconds 30
```

## 数据与隐私

本工具只读取本机 Codex 会话文件中的 `rate_limits` 字段，不读取对话正文，也不会将任何数据发送到第三方服务。

## 文件说明

- `codex-usage-widget.ps1`：悬浮窗界面、用量解析和自动刷新逻辑
- `launch-widget.vbs`：无控制台窗口启动器

## 常见问题

### 为什么显示 `--%`？

请先在 Codex 中完成一次请求，等待服务端返回新的用量信息，然后重新打开悬浮窗。

### 为什么窗口没有关闭按钮？

这是为了保持界面简洁。需要关闭时，可在任务管理器中结束对应的 PowerShell 进程；再次双击启动器即可恢复。

### 能否看到多个配额周期？

可以。如果 Codex 返回次级配额周期，悬浮窗会自动扩展并显示第二组数据。
