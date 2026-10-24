# ============================================================================
#  RobloxUnlocker - привязка CDN-доменов Roblox к живым edge-IP через hosts
#
#  Зачем: часть адресов CDN (CloudFront/Akamai) у российских провайдеров
#  «чёрные дыры»: SYN уходит, ответа нет. Roblox получает такие адреса из DNS
#  и вешает на них загрузку картинок/аватарок (иконки, одежда, превью).
#  Скрипт собирает адреса из нескольких DoH-резолверов, проверяет каждый
#  (TCP + TLS) и оставляет в hosts только реально работающие.
# ============================================================================

param(
    [ValidateSet('apply', 'clean', 'status')]
    [string]$Mode = 'status',

    [int]$MaxPerDomain = 4,
    [int]$ProbeTimeoutMs = 1200,
    [int]$MaxCandidates = 14,

    [switch]$CommentForeign,
    [switch]$KeepForeign,
    [switch]$DryRun,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-EdgesForDomain {
    param([string]$Domain)

    $answers = Get-CdnIpsViaDoh -Domain $Domain -Quiet:$Quiet
    $unique = @()

    foreach ($answer in $answers) {
        if ($unique -notcontains $answer.Ip) { $unique += $answer.Ip }
    }

    return $unique
}

function Select-WorkingEdges {
    param(
        [string]$Domain,
        [string[]]$Candidates
    )

    $working = @()
    $checked = 0

    foreach ($candidate in $Candidates) {
        if ($checked -ge $MaxCandidates) { break }
        $checked++

        $ms = Test-Edge -Ip $candidate -Port 443 -Sni $Domain -TimeoutMs $ProbeTimeoutMs
        if ($null -ne $ms) {
            $working += [pscustomobject]@{ Ip = $candidate; Ms = $ms }
        }
    }

    return [pscustomobject]@{
        Checked = $checked
        Items   = @($working | Sort-Object Ms | Select-Object -First $MaxPerDomain)
    }
}

function Invoke-Apply {
    $lines = @()
    $summary = @()

    foreach ($domain in $script:Domains) {
        Write-Action ('Собираю адреса для {0}...' -f $domain)
        $candidates = Get-EdgesForDomain -Domain $domain

        if ($candidates.Count -eq 0) {
            Write-Bad ('Не удалось получить адреса для {0} ни от одного DoH-резолвера' -f $domain)
            continue
        }

        Write-Note ('Кандидатов: {0}. Проверяю TCP + TLS...' -f $candidates.Count)
        $probe = Select-WorkingEdges -Domain $domain -Candidates $candidates
        $working = @($probe.Items)

        if ($working.Count -eq 0) {
            Write-Bad ('Ни один из {0} проверенных адресов для {1} не ответил — оставляю домен как есть' -f $probe.Checked, $domain)
            continue
        }

        foreach ($item in $working) {
            $lines += ('{0} {1}' -f $item.Ip, $domain)
        }

        $summary += [pscustomobject]@{
            Domain = $domain
            Alive  = $working.Count
            Total  = $probe.Checked
            Best   = ($working | ForEach-Object { '{0} ({1} ms)' -f $_.Ip, $_.Ms }) -join ', '
        }

        Write-Good ('{0}: выбрано {1} из {2} проверенных' -f $domain, $working.Count, $probe.Checked)
    }

    if ($lines.Count -eq 0) {
        Write-Bad 'Нечего записывать в hosts.'
        return $false
    }

    if ($DryRun) {
        Write-Head 'Режим проверки (-DryRun): hosts не изменяется'
        foreach ($line in $lines) { Write-Note $line }
        return $true
    }

    # Чужие записи для наших доменов (например, старые «народные» фиксы)
    $foreign = @()
    foreach ($domain in $script:Domains) { $foreign += @(Get-ForeignHostsLines -Domain $domain) }

    if ($foreign.Count -gt 0) {
        Write-Head 'Найдены сторонние записи для доменов Roblox'
        foreach ($line in ($foreign | Select-Object -First 10)) { Write-Note $line.Trim() }
        if ($foreign.Count -gt 10) { Write-Note ('... и ещё {0}' -f ($foreign.Count - 10)) }

        $doComment = $false
        if ($CommentForeign) { $doComment = $true }
        elseif ($KeepForeign) { $doComment = $false }
        elseif (-not $Quiet) {
            $answer = Read-Host '  Закомментировать их, чтобы не тянуть мёртвые адреса? (Y/n)'
            if ($answer -eq '' -or $answer -match '^(y|yes|д|да)$') { $doComment = $true }
        }

        if ($doComment) {
            Save-HostsBackup
            $text = Get-Content -Path $script:HostsPath -Raw -Encoding UTF8
            $inside = $false
            $result = New-Object System.Collections.Generic.List[string]

            foreach ($line in ($text -split "`r?`n")) {
                if ($line.Trim() -eq $script:ManagedBegin) { $inside = $true; $result.Add($line); continue }
                if ($line.Trim() -eq $script:ManagedEnd)   { $inside = $false; $result.Add($line); continue }

                $isForeign = $false
                if (-not $inside) {
                    foreach ($domain in $script:Domains) {
                        if ($line -match ('^\s*\d{1,3}(\.\d{1,3}){3}\s+' + [regex]::Escape($domain) + '\s*$')) { $isForeign = $true; break }
                    }
                }

                if ($isForeign) { $result.Add($script:ForeignMark + $line.Trim()) }
                else { $result.Add($line) }
            }

            [IO.File]::WriteAllText($script:HostsPath, ($result -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            Write-Good ('Закомментировано сторонних записей: {0}' -f $foreign.Count)
        }
        else {
            Write-Note 'Сторонние записи оставлены (они могут вернуть мёртвые адреса в работу)'
        }
    }

    Save-HostsBackup
    Set-ManagedHostsBlock -Lines $lines
    Write-Good ('В hosts записано строк: {0}' -f $lines.Count)

    $state = Get-State
    if (-not $state) { $state = New-State }
    $state.hosts = $true
    $state.hostsPinCount = $lines.Count
    $state.lastHostsRefresh = (Get-Date).ToString('s')
    Save-State $state

    Write-Log ('hosts обновлён: {0} записей' -f $lines.Count)

    if (-not $Quiet) {
        Write-Head 'Итог'
        foreach ($row in $summary) {
            Write-Note ('{0}: {1} из {2} живы -> {3}' -f $row.Domain, $row.Alive, $row.Total, $row.Best)
        }
    }

    return $true
}

function Invoke-Clean {
    $removed = Remove-ManagedHostsBlock
    Write-Good ('Удалено строк управляемого блока: {0}' -f $removed)

    $state = Get-State
    if ($state) {
        $state.hosts = $false
        $state.hostsPinCount = 0
        Save-State $state
    }

    Write-Log 'hosts-блок удалён'
    return $true
}

function Invoke-Status {
    $lines = @(Get-ManagedHostsLines)

    if ($lines.Count -gt 0) {
        $state = Get-State
        $when = if ($state -and $state.lastHostsRefresh) { $state.lastHostsRefresh } else { 'неизвестно' }
        Write-Good ('hosts-фикс активен: {0} записей (обновлён: {1})' -f $lines.Count, $when)
        foreach ($line in $lines) { Write-Note $line }
    }
    else {
        Write-Note 'hosts-фикс не установлен'
    }

    $foreign = @()
    foreach ($domain in $script:Domains) { $foreign += @(Get-ForeignHostsLines -Domain $domain) }
    if ($foreign.Count -gt 0) {
        Write-Note ('Сторонних записей для доменов Roblox: {0} (могут мешать)' -f $foreign.Count)
    }

    return $true
}

if ($Mode -ne 'status' -and -not $DryRun) {
    Ensure-Admin -ScriptPath $PSCommandPath -ScriptArgs @('-Mode', $Mode)
}

if (-not $Quiet) {
    Write-Head 'RobloxUnlocker - hosts / выбор живых CDN-адресов'
}

switch ($Mode) {
    'apply'  { $null = Invoke-Apply }
    'clean'  { $null = Invoke-Clean }
    'status' { $null = Invoke-Status }
}
