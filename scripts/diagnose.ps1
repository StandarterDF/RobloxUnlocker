# ============================================================================
#  RobloxUnlocker - диагностика
#
#  Отвечает на один вопрос: нужен ли этому компьютеру фикс.
#  Показывает статистику последней сессии Roblox, доступность CDN-адресов и
#  (по ключу -Capture) реальный захват QUIC-трафика через pktmon.
#  В конце печатает строку "ВЕРДИКТ: ..." — по ней можно принять решение.
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
        return $null
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

    $arwLines = @($lines | Where-Object { $_ -match 'AssetResolutionWorkflow' })
    $assetsModerated = @($arwLines | Where-Object { $_ -match 'wasModerated: true|Asset has not been reviewed|AssetDelivery403' }).Count
    $assets = $arwLines.Count - $assetsModerated
    $quic   = @($lines | Where-Object { $_ -match 'ngtcp2|ERR_IDLE_CLOSE' }).Count
    $joined = @($lines | Where-Object { $_ -match 'Joining game|Replicator created' }).Count

    $teleports = @($lines | Where-Object { $_ -match 'SessionTransitionFSM\] Teleported' }).Count
    $ackTimeouts = @($lines | Where-Object { $_ -match 'AckTimeout 1' }).Count
    $udmux = @($lines | Where-Object { $_ -match 'UDMUX Address = ' }).Count
    $direct = @($lines | Where-Object { $_ -match '\[FLog::Network\] Server Address = ' }).Count
    $lostServers = @($lines |
        Select-String -Pattern 'Lost connection to ([0-9.]+)\|(\d+)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Select-Object -Unique)

    Write-Note ('Файл: {0}' -f (Split-Path $path -Leaf))
    Write-Note ('Записан: {0}' -f (Get-Item $path).LastWriteTime)
    Write-Host ''
    Write-Host ('  Ответов HTTP ....... {0}' -f $http.Count)
    Write-Host ('  Успешных ........... {0}' -f $ok)
    Write-Host ('  Зависаний (>=50 с) . {0}' -f $stallTotal)
    Write-Host ('  Ошибок ассетов ..... {0}' -f $assets)
    Write-Host ('  Модерир. ассетов ... {0}' -f $assetsModerated)
    Write-Host ('  Ошибок QUIC ........ {0}' -f $quic)
    Write-Host ('  Вход в игру ........ {0}' -f $(if ($joined -gt 0) { 'да' } else { 'нет' }))
    Write-Host ('  Телепортов ......... {0}' -f $teleports)
    Write-Host ('  Потерь соединения .. {0}' -f $ackTimeouts)
    Write-Host ('  Входов: UDMUX/напр.  {0}/{1}' -f $udmux, $direct)

    if ($lostServers.Count -gt 0) {
        Write-Host ''
        foreach ($serverIp in ($lostServers | Select-Object -First 5)) {
            Write-Note ('потеряно соединение с {0}' -f $serverIp)
        }
    }

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

    return [pscustomobject]@{
        Path        = $path
        Total       = $http.Count
        Ok          = $ok
        Stalled     = $stallTotal
        Assets      = $assets
        Moderated   = $assetsModerated
        Joined      = ($joined -gt 0)
        Teleports   = $teleports
        AckTimeouts = $ackTimeouts
        LostServers = $lostServers
    }
}

# ---------------------------------------------------------------------------
#  CDN-адреса
# ---------------------------------------------------------------------------

function Get-CdnReport {
    $checkedTotal = 0
    $deadTotal = 0

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

        $checkedTotal += $checked
        $deadTotal += $dead.Count

        if ($dead.Count -eq 0) {
            Write-Good ('{0}: все {1} проверенных адресов отвечают' -f $domain, $checked)
        }
        else {
            Write-Bad ('{0}: мертвы {1} из {2} ({3})' -f $domain, $dead.Count, $checked, ($dead -join ', '))
        }
    }

    return [pscustomobject]@{
        Checked = $checkedTotal
        Dead    = $deadTotal
    }
}

# ---------------------------------------------------------------------------
#  Захват QUIC через pktmon
# ---------------------------------------------------------------------------

function Get-CaptureReport {
    if (-not (Test-Admin)) {
        Write-Bad 'Для захвата трафика нужны права администратора. Запусти: service.bat -> 4'
        return $null
    }

    if (-not (Get-Command pktmon -ErrorAction SilentlyContinue)) {
        Write-Bad 'pktmon не найден (нужна Windows 10 1809+ / Windows 11)'
        return $null
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
        return $null
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
        return [pscustomobject]@{ Broken = @(); Ran = $true; Flows = 0 }
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
    }
    else {
        Write-Good 'Односторонних QUIC-потоков не найдено'
    }

    return [pscustomobject]@{ Broken = $broken; Ran = $true; Flows = $flows.Count }
}

# ---------------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------------

Write-Head ('RobloxUnlocker {0} - диагностика' -f $script:UnlockerVersion)
Write-Note ('Права администратора: {0}' -f $(if (Test-Admin) { 'есть' } else { 'нет (захват трафика недоступен)' }))

Write-Head 'Установка'
$null = & (Join-Path $PSScriptRoot 'quic.ps1') -Mode status -Quiet
$null = & (Join-Path $PSScriptRoot 'hosts.ps1') -Mode status -Quiet

Write-Head 'Последняя сессия Roblox'
$log = Get-LogReport

Write-Head 'Доступность CDN-адресов'
$cdn = Get-CdnReport

$capture = $null
if ($Capture) {
    Write-Head 'Захват QUIC-трафика'
    $capture = Get-CaptureReport
}
else {
    Write-Note 'Проверить трафик на пакетах: service.bat -> 4'
}

# ---------------------------------------------------------------------------
#  Вердикт
# ---------------------------------------------------------------------------

Write-Head 'Вердикт'

$state = Get-State
$fixInstalled = [bool]($state -and $state.quic)

$signs = @()
$advice = @()

if ($log) {
    if ($log.Stalled -ge 5) {
        $signs += ('зависаний >= 50 с при загрузке ассетов: {0}' -f $log.Stalled)
    }
    if ($log.Assets -ge 5) {
        $signs += ('ошибок ассетов: {0}' -f $log.Assets)
    }
}

if ($cdn -and $cdn.Dead -gt 0) {
    $signs += ('недоступных CDN-адресов: {0} из {1}' -f $cdn.Dead, $cdn.Checked)
}

if ($capture -and $capture.Broken.Count -gt 0) {
    $signs += ('QUIC-потоков без ответа: {0}' -f $capture.Broken.Count)
}

if (-not $log -or $log.Total -eq 0) {
    Write-Note 'Нет данных: запусти Roblox на 2-3 минуты, зайди в игру и повтори диагностику.'
    Write-Host ''
    Write-Host '  ВЕРДИКТ: НЕДОСТАТОЧНО ДАННЫХ' -ForegroundColor Yellow
}
elseif (-not $fixInstalled -and $signs.Count -gt 0) {
    Write-Bad 'Найдены признаки поломки:'
    foreach ($sign in $signs) { Write-Note ('- {0}' -f $sign) }
    Write-Host ''
    Write-Host '  ВЕРДИКТ: ФИКС НУЖЕН' -ForegroundColor Yellow
    Write-Action 'Запусти service.bat -> 1 (установка)'
}
elseif ($log.AckTimeouts -gt 0) {
    Write-Bad ('В последней сессии потеряно соединений с игровыми серверами: {0}' -f $log.AckTimeouts)
    foreach ($serverIp in ($log.LostServers | Select-Object -First 5)) {
        Write-Note ('- {0}' -f $serverIp)
    }
    Write-Host ''
    Write-Host '  ВЕРДИКТ: ПРОБЛЕМА С ИГРОВЫМ СЕРВЕРОМ' -ForegroundColor Yellow
    Write-Note 'Это не ассеты: фикс не трогает UDP игровых серверов (там порты 50000-65535).'
    Write-Note 'Провайдер режет UDP до игровых серверов Roblox. Варианты:'
    Write-Note '  - VPN на время игры (работает всегда, но пинг выше);'
    Write-Note '  - UDP-desync в zapret для диапазонов игровых серверов (docs/PROBLEMS.md, P5).'
}
elseif (-not $fixInstalled -and $signs.Count -eq 0) {
    Write-Good 'Признаков поломки не найдено.'
    Write-Host ''
    Write-Host '  ВЕРДИКТ: ФИКС НЕ НУЖЕН' -ForegroundColor Green
    Write-Note 'Если ассеты всё равно серые — запусти Roblox, зайди в проблемную игру и повтори: service.bat -> 4 (захват трафика).'
}
elseif ($fixInstalled -and $signs.Count -eq 0) {
    Write-Good 'Фикс установлен, последняя сессия прошла без зависаний.'
    Write-Host ''
    Write-Host '  ВЕРДИКТ: УЖЕ РАБОТАЕТ' -ForegroundColor Green
}
elseif ($fixInstalled -and ($cdn -and $cdn.Dead -gt 0) -and -not ($log.Stalled -ge 5)) {
    Write-Bad 'QUIC уже отключён, но часть CDN-адресов недоступна:'
    foreach ($sign in $signs) { Write-Note ('- {0}' -f $sign) }
    Write-Host ''
    Write-Host '  ВЕРДИКТ: НУЖНО ОБНОВИТЬ HOSTS' -ForegroundColor Yellow
    Write-Action 'Запусти service.bat -> 5 (подобрать живые адреса CDN)'
}
else {
    Write-Bad 'Фикс уже установлен, но зависания остались:'
    foreach ($sign in $signs) { Write-Note ('- {0}' -f $sign) }
    Write-Host ''
    Write-Host '  ВЕРДИКТ: ЭТОТ ФИКС НЕ ПОМОГ' -ForegroundColor Red
    Write-Note 'Значит проблема не в QUIC и не в адресах CDN. Скорее всего блокируются сами серверы Roblox —'
    Write-Note 'нужен инструмент обхода блокировок (VPN / zapret / GoodbyeDPI).'
    Write-Action 'Откатить изменения: service.bat -> 9'
}
