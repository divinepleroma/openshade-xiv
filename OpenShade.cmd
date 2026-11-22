@echo off
rem OpenShade XIV launcher. Asks Windows for administrator permission, then
rem runs OpenShade.ps1 -Menu in Windows PowerShell.
rem -ExecutionPolicy Bypass applies to this process only.
setlocal
rem Cleared so Windows PowerShell loads its own modules when started from PowerShell 7.
set "PSModulePath="
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
if not exist "%~dp0OpenShade.ps1" goto :notunzipped
if not exist "%~dp0manifest.json" goto :notunzipped

rem The game is usually under Program Files, where only an administrator can
rem add files, so permission is asked for once, here. The menu then opens in
rem an administrator window. "OpenShade.cmd noadmin" skips this; "elevated"
rem marks the administrator window, so it never asks a second time.
if /i "%~1"=="noadmin" goto :menu
if /i "%~1"=="elevated" goto :menu
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenShade.ps1" -RequestAdmin
rem 0: an administrator window was opened, so this one is finished.
if %errorlevel%==0 exit /b
rem 2: this window already has administrator permission.
if %errorlevel%==2 goto :menu
echo.
echo   Administrator permission was not given. Continuing without it.
echo   Install and Uninstall will only work if the game folder is not protected.
echo.

:menu
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
