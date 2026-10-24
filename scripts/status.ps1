# ============================================================================
#  RobloxUnlocker - статус установки
# ============================================================================

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Head ('RobloxUnlocker {0}' -f $script:UnlockerVersion)

$state = Get-State
if ($state) {
    Write-Note ('Установлен: {0}' -f $state.installedAt)
}
else {
    Write-Note 'Состояние не найдено (ещё не устанавливался)'
}

Write-Head 'Roblox'
$exes = @(Get-RobloxExes)
if ($exes.Count -eq 0) {
    Write-Bad 'Клиент Roblox не найден в %LOCALAPPDATA%\Roblox\Versions'
}
else {
    Write-Note ('Найдено версий: {0}' -f $exes.Count)
    foreach ($exe in $exes) {
        Write-Note ('  {0}' -f (Split-Path (Split-Path $exe -Parent) -Leaf))
    }
}

Write-Head 'HTTP/3 (QUIC)'
$null = & (Join-Path $PSScriptRoot 'quic.ps1') -Mode status -Quiet

Write-Head 'hosts'
$null = & (Join-Path $PSScriptRoot 'hosts.ps1') -Mode status -Quiet

Write-Head 'Автоподдержка'
$null = & (Join-Path $PSScriptRoot 'schedule.ps1') -Mode status -Quiet

Write-Head 'Последняя сессия Roblox'
$logPath = Get-RobloxLogPath
if ($logPath) {
    $stats = Get-RobloxLogStats -Path $logPath
    Write-Note ('Лог: {0} ({1})' -f (Split-Path $logPath -Leaf), $stats.WrittenAt)
    Write-Note ('HTTP: {0} всего / {1} успешных / {2} зависаний / {3} ошибок ассетов' -f $stats.Total, $stats.Ok, $stats.Stalled, $stats.Assets)

    if ($stats.Stalled -ge 5 -or $stats.Assets -ge 5) {
        Write-Bad 'В последней сессии были проблемы с ассетами'
    }
    elseif ($stats.Total -eq 0) {
        Write-Note 'В логе нет HTTP-запросов'
    }
    else {
        Write-Good 'Последняя сессия выглядит здоровой'
    }
}
else {
    Write-Note 'Логов Roblox нет'
}
