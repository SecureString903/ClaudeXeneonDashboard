@echo off
rem Installs the Claude usage helper: copies files to %LOCALAPPDATA%\ClaudeUsageWidget,
rem adds it to Startup so it runs at logon, and starts it now.

set "DEST=%LOCALAPPDATA%\ClaudeUsageWidget"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"

echo Stopping any running copy of the helper ...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*ClaudeUsageServer.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
timeout /t 1 /nobreak >nul

echo Installing to %DEST% ...
if not exist "%DEST%" mkdir "%DEST%"
copy /Y "%~dp0ClaudeUsageServer.ps1" "%DEST%" >nul
copy /Y "%~dp0index.html" "%DEST%" >nul
copy /Y "%~dp0run-hidden.vbs" "%DEST%" >nul

echo Adding to Startup ...
> "%STARTUP%\ClaudeUsageWidget.vbs" (
  echo Set sh = CreateObject^("Wscript.Shell"^)
  echo sh.Run "wscript.exe ""%DEST%\run-hidden.vbs""", 0, False
)

echo Starting the helper now ...
wscript.exe "%DEST%\run-hidden.vbs"

echo.
echo Done. The helper now serves http://127.0.0.1:8787/
echo Test it: open http://127.0.0.1:8787/ in a browser - you should see your usage.
echo.
pause
