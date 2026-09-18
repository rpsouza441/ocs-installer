@echo off
setlocal
set "PSHOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSHOST=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PSHOST%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-OCS.ps1" %*
set "OCS_EXIT=%ERRORLEVEL%"
exit /b %OCS_EXIT%
