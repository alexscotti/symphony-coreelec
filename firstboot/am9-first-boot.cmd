@echo off
rem Double-click to run am9-first-boot.ps1 (beside this file) without
rem changing the system's PowerShell script policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0am9-first-boot.ps1"
