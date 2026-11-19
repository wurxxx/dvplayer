@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem 一次双击：装 Win32-OpenSSH、开机自启、放行 22、装上 Mac 的公钥。
rem 需要管理员 -> 会自动弹 UAC，点“是”即可。
rem 跑完 Mac 那边就能免密 ssh 进来。
rem ---------------------------------------------------------------------------

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo [1/4] requesting administrator ...
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

cd /d "%~dp0"
set MSI=OpenSSH-Win64-v10.4.0.0.msi

if not exist "%MSI%" (
    echo        downloading %MSI% from the Mac ...
    powershell -NoProfile -Command "$wc = New-Object Net.WebClient; $wc.Proxy = $null; $wc.DownloadFile('http://192.168.0.15:8080/OpenSSH-Win64-v10.4.0.0.msi', '%~dp0%MSI%')"
)
if not exist "%MSI%" (
    echo ERROR: %MSI% not found and download failed.
    pause
    exit /b 1
)

echo [2/4] installing %MSI% ...
msiexec /i "%MSI%" /quiet /norestart
echo        msiexec exit=%errorlevel%

sc config sshd start= auto >nul 2>&1
net start sshd >nul 2>&1

netsh advfirewall firewall show rule name="OpenSSH SSH Server" >nul 2>&1
if not "%errorlevel%"=="0" (
    echo        adding firewall rule for TCP 22
    netsh advfirewall firewall add rule name="OpenSSH SSH Server" dir=in action=allow protocol=TCP localport=22 >nul
)

echo [3/4] installing the Mac public key ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$k='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFhxpheT340uWrBZheLy+ZfrCIa282fFEEk9ii99I9ls dvplayer-mac';" ^
  "$d=Join-Path $env:ProgramData 'ssh'; New-Item -ItemType Directory -Force -Path $d | Out-Null;" ^
  "$f=Join-Path $d 'administrators_authorized_keys';" ^
  "if (-not (Test-Path $f) -or -not (Select-String -Path $f -Pattern 'dvplayer-mac' -Quiet)) { Add-Content -Path $f -Value $k -Encoding ascii };" ^
  "icacls $f /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null;" ^
  "$u=Join-Path $env:USERPROFILE '.ssh'; New-Item -ItemType Directory -Force -Path $u | Out-Null;" ^
  "$uf=Join-Path $u 'authorized_keys';" ^
  "if (-not (Test-Path $uf) -or -not (Select-String -Path $uf -Pattern 'dvplayer-mac' -Quiet)) { Add-Content -Path $uf -Value $k -Encoding ascii };" ^
  "Write-Host ('       admin key -> ' + $f); Write-Host ('       user  key -> ' + $uf)"

net stop sshd >nul 2>&1
net start sshd >nul 2>&1

echo [4/4] status:
sc qc sshd | findstr /i "START_TYPE BINARY_PATH"
netstat -ano | findstr ":22" | findstr /i LISTENING
echo.
echo Done - close this window.
pause
