# ============================================================================
#  RobloxUnlocker - полное удаление
# ============================================================================

. (Join-Path $PSScriptRoot 'common.ps1')

Ensure-Admin -ScriptPath $PSCommandPath

Write-Head 'RobloxUnlocker - удаление'

Write-Head 'Шаг 1/3. Снимаю блокировку QUIC'
$null = & (Join-Path $PSScriptRoot 'quic.ps1') -Mode unblock

Write-Head 'Шаг 2/3. Убираю записи из hosts'
$null = & (Join-Path $PSScriptRoot 'hosts.ps1') -Mode clean

Write-Head 'Шаг 3/3. Удаляю автоподдержку'
$null = & (Join-Path $PSScriptRoot 'schedule.ps1') -Mode remove

Write-Head 'Готово'
Write-Good 'Все изменения отменены.'

if (Test-Path $script:StatePath) {
    Remove-Item -Path $script:StatePath -Force -ErrorAction SilentlyContinue
}

Write-Note ('Резервные копии hosts остались в: {0}' -f $script:DataDir)
Write-Note ('Лог работы: {0}' -f (Join-Path $script:LogDir 'unlocker.log'))
Write-Note 'Перезапусти Roblox, чтобы клиент снова начал использовать QUIC.'
Write-Log 'uninstall: завершено'
