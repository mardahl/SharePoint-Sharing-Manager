@echo off
rem Removes the "downloaded from the internet" block (Mark of the Web) from
rem every file next to this launcher, then starts SharePoint-Sharing-Manager.ps1.
rem Requires PowerShell 7.4+ (pwsh). https://aka.ms/powershell
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7.4+ ^(pwsh^) is required but was not found.
    echo Install it from https://aka.ms/powershell and run this launcher again.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0SharePoint-Sharing-Manager.ps1" %*
