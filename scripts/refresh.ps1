# ============================================================================
#  RobloxUnlocker - фоновое обновление (вызывается задачей планировщика)
#  Работает тихо, пишет только в лог.
# ============================================================================

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-State
if (-not $state) { return }

# 1. Правила QUIC под актуальные версии Roblox
if ($state.quic) {
    try {
        $null = & (Join-Path $PSScriptRoot 'quic.ps1') -Mode block -Quiet
        Write-Log 'refresh: правила QUIC проверены'
    }
    catch {
        Write-Log ('refresh: ошибка обновления правил: {0}' -f $_.Exception.Message) 'ERROR'
    }
}

# 2. hosts: не чаще раза в 3 дня
if ($state.hosts) {
    $needRefresh = $true

    if ($state.lastHostsRefresh) {
        try {
            $last = [datetime]::Parse($state.lastHostsRefresh)
            if (((Get-Date) - $last).TotalDays -lt 3) { $needRefresh = $false }
        }
        catch { }
    }

    if ($needRefresh) {
        try {
            $null = & (Join-Path $PSScriptRoot 'hosts.ps1') -Mode apply -Quiet -KeepForeign
            Write-Log 'refresh: hosts обновлён'
        }
        catch {
            Write-Log ('refresh: ошибка обновления hosts: {0}' -f $_.Exception.Message) 'ERROR'
        }
    }
}
