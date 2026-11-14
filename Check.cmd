@echo off
rem OpenShade XIV - read-only check of an existing install.
rem Runs OpenShade.ps1 (in this folder) in Windows PowerShell.
rem "-ExecutionPolicy Bypass" applies to this one window only and changes no
rem system setting.
setlocal
rem Clear the inherited module path so this also works when started from a
rem PowerShell 7 window.
set "PSModulePath="
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
if not exist "%~dp0OpenShade.ps1" goto :notunzipped
if not exist "%~dp0manifest.json" goto :notunzipped
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenShade.ps1" -Check
echo.
pause
exit /b
:notunzipped
echo.
echo   Required files were not found next to this file.
echo   This usually means it was opened from inside the zip.
echo.
echo   Extract the zip first (right-click the zip, "Extract All"),
echo   then run this file from the extracted folder.
echo.
pause
exit /b 1
