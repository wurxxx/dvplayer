@echo off
setlocal
cd /d "%~dp0"
if not exist out mkdir out

set SAMPLE=samples\p7-fel.mkv
if not exist "%SAMPLE%" if exist "p7-fel.mkv" set SAMPLE=p7-fel.mkv
if not exist "%SAMPLE%" (
  echo ERROR: p7-fel.mkv not found.
  echo Put it in .\samples\p7-fel.mkv or in this folder next to this bat.
  pause
  exit /b 1
)

echo ==== mpv version ====
mpv\mpv.exe --version
echo.

echo ==== play 7s-11s, screenshot at 8s (mpv own window) ====
mpv\mpv.exe --no-config --vo=gpu-next --start=7 --length=4 ^
  --sid=no --aid=no --script="%~dp0shot.lua" ^
  --screenshot-directory=out --screenshot-template=a4 --screenshot-format=png ^
  --msg-level=all=info "%SAMPLE%" > out\a4.log 2>&1
echo exit=%errorlevel%
echo.

echo ==== key log lines ====
findstr /i /c:"Dolby Vision Profile" /c:"VO:" /c:"gpu-next" /c:"error" /c:"fail" out\a4.log
echo.

echo ==== output files ====
dir /b out
echo.
echo Done. a4.png (no %n in the template) plus a4.log.
pause
