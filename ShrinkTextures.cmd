@echo off
setlocal
cd /d "%~dp0"

set "TARGET=%~1"

set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"

if "%TARGET%"=="" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ShrinkTextures.ps1"
) else (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ShrinkTextures.ps1" -TargetFolder "%TARGET%"
)

if errorlevel 1 (
  echo.
  echo ERROR: ShrinkTextures failed. Read the message above.
  pause
)
