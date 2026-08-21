@echo off
chcp 65001 >nul
REM cmd.exe에서 PowerShell 레지스트리 구축 스크립트(setup-registry.ps1)를 실행하기 위한 래퍼입니다.
REM PowerShell이 표준 구현체이며, 이 bat은 단순 호출만 담당합니다.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-registry.ps1" %*
