@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul
where dart >nul 2>&1
if errorlevel 1 (
  echo Dart was not found on PATH.
  echo Install the Dart SDK, then run this file again. This launcher does not download packages.
  pause
  exit /b 1
)
dart run "%~dp0packages\ayu_manager\bin\ayu_manager.dart" --root "%~dp0run"
if errorlevel 1 (
  echo.
  echo The manager exited with an error. If packages are missing, run: dart pub get
  pause
  exit /b 1
)
