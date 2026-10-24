# ============================================================================
#  RobloxUnlocker - диагностика
#
#  Показывает: состояние установки, статистику последней сессии Roblox,
#  доступность CDN-адресов и (по ключу -Capture) реальный захват QUIC-трафика
#  через pktmon, чтобы доказать односторонний поток UDP 443.
# ============================================================================

param(
    [switch]$Capture,
    [int]$CaptureSeconds = 90
)

. (Join-Path $PSScriptRoot 'common.ps1')

# ---------------------------------------------------------------------------
#  Логи Roblox
# ---------------------------------------------------------------------------

function Get-LogReport {
    $path = Get-RobloxLogPath
    if (-not $path) {
        Write-Bad 'Логи Roblox не найдены — ни разу не запускался?'
        return
    }

    $lines = Get-Content -Path $path -Encoding UTF8
    $http = @($lines | Where-Object { $_ -match 'HttpResponse\(' })

    $ok = 0
    $stalls = @{}
    $stallTotal = 0

    foreach ($line in $http) {
        if ($line -notmatch 'error:') { $ok++ }

        if ($line -match 'net:(5\d{4}|6\d{4})\.') {
            $stallTotal++
            if ($line -match 'url:\{ "https?://([^/"?]+)') {
                $hostName = $matches[1]
                if (-not $stalls.ContainsKey($hostName)) { $stalls[$hostName] = 0 }
                $stalls[$hostName]++
            }
        }
    }

    $assets = @($lines | Where-Object { $_ -match 'AssetResolutionWorkflow' }).Count
    $quic   = @($lines | Where-Object { $_ -match 'ngtcp2|ERR_IDLE_CLOSE' }).Count
    $joined = @($lines | Where-Object { $_ -match 'Joining game|Replicator created' }).Count

    Write-Note ('Файл: {0}' -f (Split-Path $path -Leaf))
    Write-Note ('Записан: {0}' -f (Get-Item $path).LastWriteTime)
    Write-Host ''
    Write-Host ('  Ответов HTTP ....... {0}' -f $http.Count)
    Write-Host ('  Успешных ........... {0}' -f $ok)
    Write-Host ('  Зависаний (>=50 с) . {0}' -f $stallTotal)
    Write-Host ('  Ошибок ассетов ..... {0}' -f $assets)
    Write-Host ('  Ошибок QUIC ........ {0}' -f $quic)
    Write-Host ('  Вход в игру ........ {0}' -f $(if ($joined -gt 0) { 'да' } else { 'нет' }))

    if ($stalls.Count -gt 0) {
        Write-Host ''
        foreach ($hostName in ($stalls.Keys | Sort-Object { $stalls[$_] } -Descending | Select-Object -First 5)) {
            Write-Note ('{0}: {1} зависаний' -f $hostName, $stalls[$hostName])
        }
    }

    Write-Host ''
    if ($stallTotal -ge 5 -or $assets -ge 5) {
        Write-Bad 'В последней сессии ассеты не грузились (симптомы на месте)'
    }
    elseif ($http.Count -eq 0) {
        Write-Note 'В логе нет HTTP-запросов — сессия слишком короткая'
    }
    else {
        Write-Good 'В последней сессии зависаний на ассетах нет'
    }
}

# ---------------------------------------------------------------------------
#  CDN-адреса
# ---------------------------------------------------------------------------

function Get-CdnReport {
    foreach ($domain in $script:Domains) {
        $systemIps = @()
        try {
            $systemIps = @(Resolve-DnsName $domain -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        }
        catch { }

        $dohIps = @(Get-CdnIpsViaDoh -Domain $domain -Quiet | ForEach-Object { $_.Ip } | Select-Object -Unique)

        $all = @($systemIps + $dohIps | Select-Object -Unique)
        $checked = 0
        $dead = @()

        foreach ($ip in $all) {
            if ($checked -ge 8) { break }
            $checked++
            $ms = Test-Edge -Ip $ip -Sni $domain -TimeoutMs 1500
            if ($null -eq $ms) { $dead += $ip }
        }

        if ($checked -eq 0) {
            Write-Bad ('{0}: адреса не получены' -f $domain)
            continue
        }

        if ($dead.Count -eq 0) {
            Write-Good ('{0}: все {1} проверенных адресов отвечают' -f $domain, $checked)
        }
        else {
            Write-Bad ('{0}: мертвы {1} из {2} ({3})' -f $domain, $dead.Count, $checked, ($dead -join ', '))
        }
    }
}

# ---------------------------------------------------------------------------
#  Захват QUIC через pktmon
# ---------------------------------------------------------------------------

function Get-CaptureReport {
    if (-not (Test-Admin)) {
        Write-Bad 'Для захвата трафика нужны права администратора. Запусти: service.bat -> 4'
        return
    }

    if (-not (Get-Command pktmon -ErrorAction SilentlyContinue)) {
        Write-Bad 'pktmon не найден (нужна Windows 10 1809+ / Windows 11)'
        return
    }

    Ensure-DataDir
    $etl = Join-Path $script:DataDir 'capture.etl'
    $txt = Join-Path $script:DataDir 'capture.txt'

    Write-Action ('Снимаю QUIC-трафик {0} секунд. Запусти Roblox и поиграй.' -f $CaptureSeconds)
    Write-Note 'Идёт запись...'

    pktmon filter remove 2>&1 | Out-Null
    pktmon filter add -p 443 -t UDP 2>&1 | Out-Null
    pktmon start --capture --pkt-size 96 --file-size 256 --file-name $etl 2>&1 | Out-Null

    Start-Sleep -Seconds $CaptureSeconds

    pktmon stop 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    pktmon format $etl -o $txt 2>&1 | Out-Null

    if (-not (Test-Path $txt)) {
        Write-Bad 'Не удалось разобрать захват'
        return
    }

    $rx = [regex]'(\d+\.\d+\.\d+\.\d+)\.(\d+) > (\d+\.\d+\.\d+\.\d+)\.(\d+)'
    $flows = @{}
    $previous = ''
    $udpLines = 0

    foreach ($chunk in (Get-Content $txt -ReadCount 4000)) {
        foreach ($line in $chunk) {
            if ($line -notmatch '\bUDP\b') { continue }
            $match = $rx.Match($line)
            if (-not $match.Success) { continue }

            $lengthMatch = [regex]::Match($line, 'length (\d+)\s*$')
            $length = if ($lengthMatch.Success) { [int]$lengthMatch.Groups[1].Value } else { 0 }

            $key = '{0} {1} {2} {3} {4}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value, $match.Groups[4].Value, $length
            if ($key -eq $previous) { continue }
            $previous = $key
            $udpLines++

            $sender = $match.Groups[1].Value
            $remote = if ($sender -match '^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\.') { $match.Groups[3].Value } else { $sender }

            if (-not $flows.ContainsKey($remote)) { $flows[$remote] = @{ Out = 0; OutPkts = 0; In = 0; InPkts = 0 } }

            if ($sender -match '^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\.') {
                $flows[$remote].Out += $length
                $flows[$remote].OutPkts++
            }
            else {
                $flows[$remote].In += $length
                $flows[$remote].InPkts++
            }
        }
    }

    Write-Host ''
    Write-Note ('UDP-пакетов в захвате: {0}' -f $udpLines)

    if ($flows.Count -eq 0) {
        Write-Good 'UDP 443 наружу не ходил вообще — QUIC у Roblox не используется (это норма при включённом фиксе)'
        return
    }

    $broken = @()
    $rows = @()

    foreach ($remote in ($flows.Keys | Sort-Object { $flows[$_].OutPkts } -Descending | Select-Object -First 10)) {
        $flow = $flows[$remote]
        $rows += ('{0,-16} отправлено {1,7} Б ({2,5} пак.)   получено {3,7} Б ({4,5} пак.)' -f $remote, $flow.Out, $flow.OutPkts, $flow.In, $flow.InPkts)

        if ($flow.OutPkts -gt 20 -and $flow.InPkts -eq 0) { $broken += $remote }
    }

    foreach ($row in $rows) { Write-Note $row }

    Write-Host ''
    if ($broken.Count -gt 0) {
        Write-Bad ('Односторонний QUIC (в одну сторону, ответа ноль): {0}' -f ($broken -join ', '))
        Write-Bad 'Это и есть причина «серых» моделей: провайдер режет UDP 443.'
        Write-Action 'Запусти установку (service.bat -> 1) — она заблокирует QUIC для Roblox и вернёт загрузку по TCP.'
    }
    else {
        Write-Good 'Односторонних QUIC-потоков не найдено'
    }
}

# ---------------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------------

Write-Head ('RobloxUnlocker {0} - диагностика' -f $script:UnlockerVersion)
Write-Note ('Права администратора: {0}' -f $(if (Test-Admin) { 'есть' } else { 'нет (часть проверок недоступна)' }))

Write-Head 'Установка'
$null = & (Join-Path $PSScriptRoot 'quic.ps1') -Mode status -Quiet
$null = & (Join-Path $PSScriptRoot 'hosts.ps1') -Mode status -Quiet

Write-Head 'Последняя сессия Roblox'
Get-LogReport

Write-Head 'Доступность CDN-адресов'
Get-CdnReport

if ($Capture) {
    Write-Head 'Захват QUIC-трафика'
    Get-CaptureReport
}
else {
    Write-Note 'Хочешь поймать проблему на пакетах: service.bat -> 4 (захват 90 секунд)'
}

Write-Head 'Что делать'
$state = Get-State
$logPath = Get-RobloxLogPath
$stallTotal = 0

if ($logPath) {
    $stallTotal = @(Get-Content $logPath -Encoding UTF8 | Where-Object { $_ -match 'net:(5\d{4}|6\d{4})\.' }).Count
}

if (-not $state -or -not $state.quic) {
    Write-Action 'QUIC-фикс не установлен -> service.bat -> 1'
}
elseif ($stallTotal -ge 5) {
    Write-Action 'Фикс стоит, но зависания есть -> обнови правила: service.bat -> 1'
}
else {
    Write-Good 'Всё выглядит рабочим. Если ассеты всё равно не грузятся — пришли лог из %LOCALAPPDATA%\Roblox\logs'
}
