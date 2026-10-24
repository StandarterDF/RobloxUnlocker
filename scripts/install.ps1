# ============================================================================
#  RobloxUnlocker - установка
# ============================================================================

param(
    [switch]$SkipHosts,
    [switch]$SkipSchedule,
    [switch]$CommentForeign
)

. (Join-Path $PSScriptRoot 'common.ps1')

$forward = @()
if ($SkipHosts)      { $forward += '-SkipHosts' }
if ($SkipSchedule)   { $forward += '-SkipSchedule' }
if ($CommentForeign) { $forward += '-CommentForeign' }

Ensure-Admin -ScriptPath $PSCommandPath -ScriptArgs $forward

Write-Head ('RobloxUnlocker {0} - установка' -f $script:UnlockerVersion)

$state = Get-State
if (-not $state) { $state = New-State }
$state.version = $script:UnlockerVersion
if (-not $state.installedAt) { $state.installedAt = (Get-Date).ToString('s') }
Save-State $state

function Invoke-Step {
    param(
        [string]$Title,
        [string]$LogName,
        [scriptblock]$Body
    )

    Write-Head $Title
    Write-Log ('install: {0}' -f $LogName)

    try {
        & $Body
    }
    catch {
        Write-Bad ('Шаг не выполнен: {0}' -f $_.Exception.Message)
        Write-Log ('install: ошибка в шаге {0}: {1}' -f $LogName, $_.Exception.Message) 'ERROR'
    }
}

# ---------------------------------------------------------------------------
Invoke-Step -Title 'Шаг 1/3. QUIC (HTTP/3): принудительный TCP' -LogName 'quic' -Body {
    $null = & (Join-Path $PSScriptRoot 'quic.ps1') -Mode block
}

# ---------------------------------------------------------------------------
if ($SkipHosts) {
    Write-Head 'Шаг 2/3. hosts: пропущено (-SkipHosts)'
}
else {
    Invoke-Step -Title 'Шаг 2/3. hosts: живые адреса CDN' -LogName 'hosts' -Body {
        $hostsArgs = @{ Mode = 'apply' }
        if ($CommentForeign) { $hostsArgs['CommentForeign'] = $true }
        $null = & (Join-Path $PSScriptRoot 'hosts.ps1') @hostsArgs
    }
}

# ---------------------------------------------------------------------------
if ($SkipSchedule) {
    Write-Head 'Шаг 3/3. Автоподдержка: пропущено (-SkipSchedule)'
}
else {
    Invoke-Step -Title 'Шаг 3/3. Автоподдержка после обновлений Roblox' -LogName 'scheduler' -Body {
        $null = & (Join-Path $PSScriptRoot 'schedule.ps1') -Mode install
    }
}

# ---------------------------------------------------------------------------
Write-Head 'Готово'

$state = Get-State
if ($state) {
    Write-Note ('QUIC-фикс: {0}' -f $(if ($state.quic) { 'да' } else { 'нет' }))
    Write-Note ('hosts-фикс: {0}' -f $(if ($state.hosts) { 'да' } else { 'нет' }))
    Write-Note ('автоподдержка: {0}' -f $(if ($state.scheduled) { 'да' } else { 'нет' }))
}

Write-Action 'Полностью закрой Roblox (все процессы RobloxPlayerBeta) и запусти заново.'
Write-Note 'Проверить состояние: service.bat -> 2'
Write-Note 'Проверить причину на пакетах: service.bat -> 4'
Write-Log 'install: завершено'
