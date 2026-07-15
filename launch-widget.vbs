Option Explicit

Dim shell, fileSystem, scriptDirectory, widgetScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
widgetScript = fileSystem.BuildPath(scriptDirectory, "codex-usage-widget.ps1")
command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & widgetScript & """"
shell.Run command, 0, False
