@echo off
rem update-zap PATH shim: run the sibling update-zap.ps1. Installed alongside it
rem in %LOCALAPPDATA%\zap-setup\bin by setup.ps1 so bare `update-zap` works in
rem cmd and PowerShell. %~dp0 resolves to this file's directory.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-zap.ps1" %*
