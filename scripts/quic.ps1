# ============================================================================
#  RobloxUnlocker - блокировка QUIC (UDP 443) для клиента Roblox
#
#  Зачем: провайдер может «тихо» резать QUIC, при этом рукопожатие проходит,
#  а следующие пакеты пропадают. Roblox в этом случае не откатывается на TCP,
#  а ждёт по 60 секунд на каждый ассет (в логе: net:59999ms, 0 bytes received).
#  Запретив UDP 443 для процесса, мы принудительно переводим клиент на TCP/HTTP2.
# ============================================================================

param(
    [ValidateSet('block', 'unblock', 'status')]
    [string]$Mode = 'status',

    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-ExistingRulePrograms {
    $map = @{}
    $rules = Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue

    foreach ($rule in $rules) {
        $filter = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        if ($filter -and $filter.Program) {
            $map[$filter.Program] = $rule.Name
        }
    }

    return $map
}

function Invoke-Block {
    $exes = @(Get-RobloxExes)

    if ($exes.Count -eq 0) {
        Write-Bad 'Не найдены файлы Roblox (RobloxPlayerBeta.exe). Установлен ли Roblox?'
        return $false
    }

    $existing = Get-ExistingRulePrograms
    $created = 0
    $removed = 0

    # 1. Правила на существующие версии
    foreach ($exe in $exes) {
        if ($existing.ContainsKey($exe)) { continue }

        $versionFolder = Split-Path (Split-Path $exe -Parent) -Leaf
        $ruleName = 'RobloxUnlocker QUIC block - {0} - {1}' -f $versionFolder, (Split-Path $exe -Leaf)

        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Group $script:RuleGroup `
            -Description 'Блокирует QUIC (UDP 443), чтобы Roblox не зависал на заблокированном провайдером HTTP/3' `
            -Direction Outbound `
            -Program $exe `
            -Protocol UDP `
            -RemotePort 443 `
            -Action Block `
            -Profile Any `
            -Enabled True | Out-Null

        $created++
        Write-Good ('Правило добавлено: {0}' -f $versionFolder)
    }

    # 2. Чистим правила от удалённых версий Roblox
    foreach ($program in @($existing.Keys)) {
        if (-not (Test-Path $program)) {
            Remove-NetFirewallRule -Name $existing[$program] -ErrorAction SilentlyContinue
            $removed++
        }
    }

    if ($created -eq 0) { Write-Good ('Правила уже на месте (проверено версий: {0})' -f $exes.Count) }
    if ($removed -gt 0)  { Write-Note ('Удалено устаревших правил: {0}' -f $removed) }

    # 3. Включаем активный профиль файрвола, НЕ меняя политику по умолчанию
    $state = Get-State
    if (-not $state) { $state = New-State }

    $profileName = Get-ActiveFirewallProfileName
    $profile = Get-NetFirewallProfile -Name $profileName -ErrorAction SilentlyContinue

    if ($profile -and -not $profile.Enabled) {
        Set-NetFirewallProfile -Name $profileName -Enabled True -DefaultInboundAction Allow -DefaultOutboundAction Allow
        $list = @($state.profilesEnabledByUs)
        if ($list -notcontains $profileName) { $list += $profileName }
        $state.profilesEnabledByUs = $list
        Write-Note ('Профиль файрвола "{0}" включён (входящие/исходящие по умолчанию разрешены, поведение сети не меняется)' -f $profileName)
    }

    $state.quic = $true
    Save-State $state
    Write-Log ('QUIC-фикс применён: правил создано {0}, удалено {1}, профиль {2}' -f $created, $removed, $profileName)

    return $true
}

function Invoke-Unblock {
    $rules = @(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue)

    if ($rules.Count -gt 0) {
        foreach ($rule in $rules) {
            Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        }
        Write-Good ('Удалено правил: {0}' -f $rules.Count)
    }
    else {
        Write-Note 'Правил RobloxUnlocker нет — снимать нечего'
    }

    $state = Get-State
    if ($state) {
        foreach ($profileName in @($state.profilesEnabledByUs)) {
            if (-not $profileName) { continue }
            Set-NetFirewallProfile -Name $profileName -Enabled False -ErrorAction SilentlyContinue
            Write-Note ('Профиль файрвола "{0}" возвращён в исходное состояние (выключен)' -f $profileName)
        }
        $state.profilesEnabledByUs = @()
        $state.quic = $false
        Save-State $state
    }

    Write-Log 'QUIC-фикс снят'
    return $true
}

function Invoke-Status {
    $exes = @(Get-RobloxExes)

    if (-not (Test-Admin)) {
        $state = Get-State
        if ($state -and $state.quic) {
            Write-Good 'QUIC-фикс установлен (детали видны только из консоли администратора)'
        }
        else {
            Write-Bad 'QUIC-фикс не установлен'
        }
        if ($exes.Count -gt 0) { Write-Note ('Найдено версий Roblox: {0}' -f $exes.Count) }
        return $true
    }

    $existing = Get-ExistingRulePrograms
    $covered = 0

    foreach ($exe in $exes) { if ($existing.ContainsKey($exe)) { $covered++ } }

    if ($covered -eq $exes.Count -and $exes.Count -gt 0) {
        Write-Good ('QUIC-фикс активен: правил {0} на {1} верси(й) Roblox' -f $existing.Count, $exes.Count)
    }
    elseif ($existing.Count -eq 0) {
        Write-Bad 'QUIC-фикс не установлен'
    }
    else {
        Write-Bad ('QUIC-фикс неполный: {0} из {1} версий покрыты' -f $covered, $exes.Count)
        Write-Action 'Запусти установку, чтобы обновить правила на новые версии Roblox'
    }

    $profileName = Get-ActiveFirewallProfileName
    $profile = Get-NetFirewallProfile -Name $profileName -ErrorAction SilentlyContinue
    if ($profile) {
        if ($profile.Enabled) { Write-Note ('Профиль файрвола "{0}": включён' -f $profileName) }
        else { Write-Note ('Профиль файрвола "{0}": выключен' -f $profileName) }
    }

    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) { Write-Good 'Автоподдержка (задача планировщика): установлена' }
    else { Write-Note 'Автоподдержка (задача планировщика): не установлена' }

    return $true
}

if ($Mode -ne 'status') {
    Ensure-Admin -ScriptPath $PSCommandPath -ScriptArgs @('-Mode', $Mode)
}

if (-not $Quiet) {
    Write-Head 'RobloxUnlocker - QUIC / HTTP3'
}

switch ($Mode) {
    'block'   { $null = Invoke-Block }
    'unblock' { $null = Invoke-Unblock }
    'status'  { $null = Invoke-Status }
}
