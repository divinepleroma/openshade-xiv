@echo off
rem OpenShade XIV launcher. Runs OpenShade.ps1 -Menu in Windows PowerShell.
rem -ExecutionPolicy Bypass applies to this process only.
setlocal
rem Cleared so Windows PowerShell loads its own modules when started from PowerShell 7.
set "PSModulePath="
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
if not exist "%~dp0OpenShade.ps1" goto :notunzipped
if not exist "%~dp0manifest.json" goto :notunzipped
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenShade.ps1" -Menu
echo.
pause
exit /b
:notunzipped
echo.
echo   OpenShade.ps1 or manifest.json was not found next to this file.
echo   Extract the zip first (right-click the zip, "Extract All"),
echo   then run OpenShade.cmd from the extracted folder.
echo.
pause
exit /b 1
