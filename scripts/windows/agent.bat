@echo off
title dvplayer agent
set DEST=%TEMP%\dvagent.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$wc = New-Object Net.WebClient; $wc.Proxy = $null; $wc.DownloadFile('http://192.168.0.15:8080/agent.ps1', '%DEST%')"
if errorlevel 1 (
  echo failed to download agent.ps1 - check the Mac server is running
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%"
echo.
echo agent stopped.
pause
