@echo off
rem Removes the Claude usage helper: stops it, removes Startup entry and installed files.

echo Stopping helper (if running) ...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*ClaudeUsageServer.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"

del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ClaudeUsageWidget.vbs" 2>nul
rmdir /S /Q "%LOCALAPPDATA%\ClaudeUsageWidget" 2>nul

echo Done. You can also remove the widget from iCUE's widget library.
pause
