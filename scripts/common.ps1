# ============================================================================
#  RobloxUnlocker - общие функции
#  Документация: README.md
# ============================================================================

$ErrorActionPreference = 'Stop'

$script:UnlockerVersion = '1.0.1'
$script:RuleGroup       = 'RobloxUnlocker'
$script:TaskName        = 'RobloxUnlocker-Refresh'
$script:HostsPath       = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:ManagedBegin    = '# >>> RobloxUnlocker >>>'
$script:ManagedEnd      = '# <<< RobloxUnlocker <<<'
$script:ForeignMark     = '# [RobloxUnlocker disabled] '
$script:DataDir         = Join-Path $env:ProgramData 'RobloxUnlocker'
$script:LogDir          = Join-Path $script:DataDir 'logs'
$script:StatePath       = Join-Path $script:DataDir 'state.json'
$script:RepoRoot        = Split-Path -Parent $PSScriptRoot
$script:Domains         = @('fts.rbxcdn.com', 'tr.rbxcdn.com')

$script:DohProviders = @(
    @{ Name = 'Cloudflare'; Url = 'https://cloudflare-dns.com/dns-query' },
    @{ Name = 'Google';     Url = 'https://dns.google/resolve' },
    @{ Name = 'doh.pub';    Url = 'https://doh.pub/dns-query' }
)

# Обычный DNS по UDP: каждый резолвер сидит в своей сети и отдаёт свой набор
# edge-адресов, поэтому сумма по ним даёт больше живых вариантов.
$script:DnsServers = @(
    '1.1.1.1', '1.0.0.1',
    '8.8.8.8', '8.8.4.4',
    '9.9.9.9', '149.112.112.112',
    '77.88.8.8', '77.88.8.1',
    '94.140.14.14', '94.140.15.15',
    '208.67.222.222', '4.2.2.1'
)

# ---------------------------------------------------------------------------
#  Вывод
# ---------------------------------------------------------------------------

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Write-Good {
    param([string]$Text)
    Write-Host "  [OK]  $Text" -ForegroundColor Green
}

function Write-Bad {
    param([string]$Text)
    Write-Host "  [!]   $Text" -ForegroundColor Red
}

function Write-Note {
    param([string]$Text)
    Write-Host "  [i]   $Text" -ForegroundColor DarkGray
}

function Write-Action {
    param([string]$Text)
    Write-Host "  [->]  $Text" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
#  Права / служебные каталоги
# ---------------------------------------------------------------------------

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    param(
        [string]$ScriptPath,
        [string[]]$ScriptArgs = @()
    )

    if (Test-Admin) { return }

    Write-Host ''
    Write-Host "  [i]   Для этого действия нужны права администратора." -ForegroundColor Yellow
    Write-Host "        Подтверди запрос UAC в появившемся окне..." -ForegroundColor Yellow

    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"' + $ScriptPath + '"')
    ) + $ScriptArgs

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList -Wait
    }
    catch {
        Write-Bad 'Не удалось получить права администратора.'
        exit 1
    }

    exit
}

function Ensure-DataDir {
    foreach ($directory in @($script:DataDir, $script:LogDir)) {
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    try {
        Ensure-DataDir
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path (Join-Path $script:LogDir 'unlocker.log') -Value $line -Encoding UTF8
    }
    catch { }
}

# ---------------------------------------------------------------------------
#  Состояние установки
# ---------------------------------------------------------------------------

function New-State {
    return [pscustomobject]@{
        version            = $script:UnlockerVersion
        installedAt        = (Get-Date).ToString('s')
        quic               = $false
        hosts              = $false
        autoHosts          = $false
        scheduled          = $false
        profilesEnabledByUs = @()
        lastHostsRefresh   = $null
        hostsPinCount      = 0
    }
}

function Get-State {
    if (-not (Test-Path $script:StatePath)) { return $null }
    try {
        $state = Get-Content -Path $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $state.profilesEnabledByUs) { $state | Add-Member -NotePropertyName profilesEnabledByUs -NotePropertyValue @() -Force }
        return $state
    }
    catch {
        return $null
    }
}

function Save-State {
    param($State)

    Ensure-DataDir
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StatePath -Encoding UTF8
}

# ---------------------------------------------------------------------------
#  Roblox / сеть
# ---------------------------------------------------------------------------

function Get-RobloxExes {
    $base = Join-Path $env:LOCALAPPDATA 'Roblox\Versions'
    $result = @()

    if (-not (Test-Path $base)) { return $result }

    foreach ($directory in Get-ChildItem $base -Directory -ErrorAction SilentlyContinue) {
        foreach ($name in @('RobloxPlayerBeta.exe', 'RobloxStudioBeta.exe')) {
            $path = Join-Path $directory.FullName $name
            if (Test-Path $path) { $result += $path }
        }
    }

    return $result
}

function Get-RobloxLogPath {
    $logDir = Join-Path $env:LOCALAPPDATA 'Roblox\logs'
    if (-not (Test-Path $logDir)) { return $null }

    $log = Get-ChildItem $logDir -Filter '*_last.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'CrashHandler' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($log) { return $log.FullName }
    return $null
}

function Get-ActiveFirewallProfileName {
    $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv6Connectivity -eq 'Internet' } |
        Select-Object -First 1

    if (-not $profile) { return 'Private' }

    switch ($profile.NetworkCategory) {
        'DomainAuthenticated' { return 'Domain' }
        'Public'              { return 'Public' }
        default               { return 'Private' }
    }
}

function Get-CdnIps {
    param(
        [string]$Domain,
        [int]$TimeoutSec = 4,
        [switch]$Quiet
    )

    $result = @()

    # 1. Обычный DNS (UDP) через список публичных резолверов
    foreach ($server in $script:DnsServers) {
        try {
            $answers = Resolve-DnsName -Name $Domain -Type A -Server $server -DnsOnly -QuickTimeout -ErrorAction Stop
            foreach ($answer in $answers) {
                if ($answer.IPAddress) {
                    $result += [pscustomobject]@{ Ip = [string]$answer.IPAddress; Source = $server }
                }
            }
        }
        catch {
            if (-not $Quiet) { Write-Note ('DNS {0}: нет ответа' -f $server) }
        }
    }

    # 2. DoH (JSON API) — на случай, если UDP DNS фильтруется
    foreach ($provider in $script:DohProviders) {
        try {
            $url = '{0}?name={1}&type=A' -f $provider.Url, $Domain
            $response = Invoke-RestMethod -Uri $url -Headers @{ accept = 'application/dns-json' } -TimeoutSec $TimeoutSec -ErrorAction Stop

            foreach ($answer in $response.Answer) {
                if ($answer.type -eq 1) {
                    $result += [pscustomobject]@{ Ip = [string]$answer.data; Source = $provider.Name }
                }
            }
        }
        catch {
            if (-not $Quiet) { Write-Note ('DoH {0}: нет ответа' -f $provider.Name) }
        }
    }

    return $result
}

function Get-CdnIpsViaDoh {
    param(
        [string]$Domain,
        [int]$TimeoutSec = 4,
        [switch]$Quiet
    )

    return Get-CdnIps -Domain $Domain -TimeoutSec $TimeoutSec -Quiet:$Quiet
}

function Test-Edge {
    param(
        [string]$Ip,
        [int]$Port = 443,
        [string]$Sni = 'fts.rbxcdn.com',
        [int]$TimeoutMs = 1500
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs

        $async = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.Close()
            return $null
        }

        $client.EndConnect($async)

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, { param($s, $c, $ch, $e) $true })
        $ssl.AuthenticateAsClient($Sni)
        $stopwatch.Stop()

        $ms = [int]$stopwatch.ElapsedMilliseconds
        $ssl.Dispose()
        $client.Close()

        return $ms
    }
    catch {
        try { $client.Close() } catch { }
        return $null
    }
}

# ---------------------------------------------------------------------------
#  hosts: управляемый блок
# ---------------------------------------------------------------------------

function Get-ManagedHostsLines {
    if (-not (Test-Path $script:HostsPath)) { return @() }

    $lines = @()
    $inside = $false

    foreach ($line in (Get-Content -Path $script:HostsPath -Encoding UTF8)) {
        if ($line.Trim() -eq $script:ManagedBegin) { $inside = $true; continue }
        if ($line.Trim() -eq $script:ManagedEnd)   { $inside = $false; continue }
        if ($inside) { $lines += $line }
    }

    return $lines
}

function Save-HostsBackup {
    if (-not (Test-Path $script:HostsPath)) { return }
    Ensure-DataDir
    $backup = Join-Path $script:DataDir ('hosts.backup.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -Path $script:HostsPath -Destination $backup -Force -ErrorAction SilentlyContinue
    Write-Note ('Резервная копия hosts: {0}' -f $backup)
}

function Set-ManagedHostsBlock {
    param([string[]]$Lines)

    $text = ''
    if (Test-Path $script:HostsPath) {
        $text = Get-Content -Path $script:HostsPath -Raw -Encoding UTF8
    }

    $kept = New-Object System.Collections.Generic.List[string]
    $inside = $false

    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim() -eq $script:ManagedBegin) { $inside = $true; continue }
        if ($line.Trim() -eq $script:ManagedEnd)   { $inside = $false; continue }
        if (-not $inside) { $kept.Add($line) }
    }

    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') {
        $kept.RemoveAt($kept.Count - 1)
    }

    $block = @($script:ManagedBegin) + $Lines + @($script:ManagedEnd)
    $final = ($kept -join "`r`n") + "`r`n`r`n" + ($block -join "`r`n") + "`r`n"

    [IO.File]::WriteAllText($script:HostsPath, $final, (New-Object System.Text.UTF8Encoding($false)))
    ipconfig /flushdns | Out-Null
}

function Remove-ManagedHostsBlock {
    if (-not (Test-Path $script:HostsPath)) { return }

    $text = Get-Content -Path $script:HostsPath -Raw -Encoding UTF8
    $kept = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $removed = 0

    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim() -eq $script:ManagedBegin) { $inside = $true; continue }
        if ($line.Trim() -eq $script:ManagedEnd)   { $inside = $false; continue }
        if ($inside) { $removed++; continue }
        $kept.Add($line)
    }

    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') {
        $kept.RemoveAt($kept.Count - 1)
    }

    [IO.File]::WriteAllText($script:HostsPath, (($kept -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    ipconfig /flushdns | Out-Null

    return $removed
}

function Get-ForeignHostsLines {
    param([string]$Domain)

    $result = @()
    if (-not (Test-Path $script:HostsPath)) { return $result }

    $inside = $false
    foreach ($line in (Get-Content -Path $script:HostsPath -Encoding UTF8)) {
        if ($line.Trim() -eq $script:ManagedBegin) { $inside = $true; continue }
        if ($line.Trim() -eq $script:ManagedEnd)   { $inside = $false; continue }
        if ($inside) { continue }
        if ($line -match ('^\s*\d{1,3}(\.\d{1,3}){3}\s+' + [regex]::Escape($Domain) + '\s*$')) {
            $result += $line
        }
    }

    return $result
}

# ---------------------------------------------------------------------------
#  Анализ логов Roblox
# ---------------------------------------------------------------------------

function Get-RobloxLogStats {
    param([string]$Path)

    $lines = Get-Content -Path $Path -Encoding UTF8
    $http = @($lines | Where-Object { $_ -match 'HttpResponse\(' })

    $ok = 0
    $stalled = 0
    $hosts = @{}

    foreach ($line in $http) {
        if ($line -match 'error:') { } else { $ok++ }

        if ($line -match 'net:(5\d{4}|6\d{4})\.') { $stalled++ }

        if ($line -match 'url:\{ "https?://([^/"?]+)') {
            $hostName = $matches[1]
            if (-not $hosts.ContainsKey($hostName)) { $hosts[$hostName] = 0 }
            $hosts[$hostName]++
        }
    }

    return [pscustomobject]@{
        Path      = $Path
        Total     = $http.Count
        Ok        = $ok
        Errors    = $http.Count - $ok
        Stalled   = $stalled
        Assets    = @($lines | Where-Object { $_ -match 'AssetResolutionWorkflow' }).Count
        Quic      = @($lines | Where-Object { $_ -match 'ngtcp2|ERR_IDLE_CLOSE' }).Count
        Hosts     = $hosts
        WrittenAt = (Get-Item $Path).LastWriteTime
    }
}
