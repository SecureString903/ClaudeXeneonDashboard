' Launches the Claude usage helper with no visible window.
Dim fso, sh, scriptDir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("Wscript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\ClaudeUsageServer.ps1""", 0, False
