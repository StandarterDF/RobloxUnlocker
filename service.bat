@echo off
chcp 65001 >nul
setlocal
title RobloxUnlocker
cd /d "%~dp0"

:menu
cls
echo.
echo   ============================================================
echo      RobloxUnlocker - разблокировка ассетов Roblox на Windows
echo   ============================================================
echo.
echo    [1]  Установить все исправления  (рекомендуется)
echo    [2]  Статус
echo    [3]  Диагностика (логи + адреса CDN)
echo    [4]  Диагностика трафика QUIC  (захват 90 секунд)
echo.
echo    [5]  Обновить hosts (подобрать живые адреса CDN)
echo    [6]  Убрать записи из hosts
echo.
echo    [7]  Включить автоподдержку  (после обновлений Roblox)
echo    [8]  Выключить автоподдержку
echo.
echo    [9]  Полностью удалить
echo    [0]  Выход
echo.
set /p "choice=   Выбор: "

if "%choice%"=="1" goto install
if "%choice%"=="2" goto status
if "%choice%"=="3" goto diagnose
if "%choice%"=="4" goto capture
if "%choice%"=="5" goto hosts
if "%choice%"=="6" goto hosts_clean
if "%choice%"=="7" goto sched_on
if "%choice%"=="8" goto sched_off
if "%choice%"=="9" goto uninstall
if "%choice%"=="0" exit /b 0
goto menu

:install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"
goto done

:status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\status.ps1"
goto done

:diagnose
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\diagnose.ps1"
goto done

:capture
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\diagnose.ps1" -Capture
goto done

:hosts
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\hosts.ps1" -Mode apply
goto done

:hosts_clean
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\hosts.ps1" -Mode clean
goto done

:sched_on
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\schedule.ps1" -Mode install
goto done

:sched_off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\schedule.ps1" -Mode remove
goto done

:uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1"
goto done

:done
echo.
pause
goto menu
