@echo off
rem forge-kit - Windows bootstrap installer
rem Downloads install.ps1 and runs it with flags forwarded verbatim.
rem Usage (cmd):  install.cmd              (install / refresh)
rem               install.cmd --update     (hot-update modules only)
rem               install.cmd --uninstall [--purge]
rem               install.cmd --list
rem               install.cmd --from C:\path\to\modules

setlocal EnableDelayedExpansion
set "URL=https://raw.githubusercontent.com/RickSanchez88E/forge-kit/main/install.ps1"
set "DEST=%TEMP%\forge-kit-install.ps1"

where git >nul 2>&1
if errorlevel 1 echo [forge] note: git not found in PATH - self-clone needs Git for Windows

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%DEST%' } catch { Write-Host '[forge] download failed:' $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fail

rem translate git-style --flag to PS-style -flag here: PowerShell < 7.2
rem (incl. bundled 5.1) rejects --flag at parameter binding; PS-style flags
rem work everywhere. Other args pass through quoted.
set "ARGS="
:parse
if "%~1"=="" goto :run
set "a=%~1"
if "!a:~0,2!"=="--" set "a=-!a:~2!"
set "ARGS=!ARGS! "!a!""
shift
goto :parse

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%" !ARGS!
if errorlevel 1 goto :fail

rem pause only when double-clicked (cmdcmdline shows the /c launcher), so the
rem window doesn't vanish before the result is read; terminal runs just exit.
echo %cmdcmdline% | find /i "/c" >nul && pause
exit /b 0

:fail
echo %cmdcmdline% | find /i "/c" >nul && pause
exit /b 1
