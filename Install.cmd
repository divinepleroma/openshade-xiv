@echo off
rem Starts the setup walkthrough.
rem This file only opens Walkthrough.ps1 (in this same folder) in a PowerShell
rem window. "-ExecutionPolicy Bypass" applies to this one window only: it lets
rem Windows run a script you downloaded, and changes no system setting.
setlocal
rem Start from a clean module path, so this also works when launched from a
rem PowerShell 7 window (which otherwise confuses Windows PowerShell).
set "PSModulePath="
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
if not exist "%~dp0Walkthrough.ps1" goto :notunzipped
if not exist "%~dp0manifest.json" goto :notunzipped
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Walkthrough.ps1"
echo.
pause
exit /b
:notunzipped
echo.
echo   This file can't find the rest of the walkthrough.
echo   That usually means it was opened from inside the zip file.
echo.
echo   Close this window, right-click the zip you downloaded, choose
echo   "Extract All", then open the extracted folder and run this again.
echo.
pause
exit /b 1
