# ============================================================================
#  RobloxUnlocker - автоподдержка
#
#  Задача планировщика раз в 30 минут повторяет refresh.ps1:
#  - добавляет правило QUIC для новых версий Roblox (после обновления клиента);
#  - удаляет правила от старых версий;
#  - раз в 3 дня обновляет hosts с живыми CDN-адресами (если включено).
# ============================================================================

param(
    [ValidateSet('install', 'remove', 'status')]
    [string]$Mode = 'status'
)

. (Join-Path $PSScriptRoot 'common.ps1')

$refreshScript = Join-Path $PSScriptRoot 'refresh.ps1'

function Invoke-Install {
    if (-not (Test-Path $refreshScript)) {
        Write-Bad ('Не найден {0}' -f $refreshScript)
        return $false
    }

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $refreshScript)

    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Minutes 30) `
            -RepetitionDuration (New-TimeSpan -Days 3650))
    )

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $script:TaskName `
        -Action $action `
        -Trigger $triggers `
        -Principal $principal `
        -Settings $settings `
        -Description 'RobloxUnlocker: поддержка QUIC-правил после обновлений Roblox' `
        -Force | Out-Null

    Write-Good ('Задача планировщика установлена: {0}' -f $script:TaskName)

    $state = Get-State
    if (-not $state) { $state = New-State }
    $state.scheduled = $true
    Save-State $state

    Write-Log 'Задача планировщика установлена'
    return $true
}

function Invoke-Remove {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Write-Good 'Задача планировщика удалена'
    }
    else {
        Write-Note 'Задача планировщика не найдена'
    }

    $state = Get-State
    if ($state) {
        $state.scheduled = $false
        Save-State $state
    }

    Write-Log 'Задача планировщика удалена'
    return $true
}

function Invoke-Status {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue

    if (-not $task) {
        $state = Get-State
        if ($state -and $state.scheduled) {
            Write-Good 'Автоподдержка установлена (детали видны только из консоли администратора)'
        }
        else {
            Write-Note 'Автоподдержка не установлена'
        }
        return $true
    }

    $info = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Write-Good ('Задача {0}: {1}' -f $script:TaskName, $task.State)

    if ($info) {
        Write-Note ('Последний запуск: {0}' -f $info.LastRunTime)
        Write-Note ('Результат: {0}' -f $info.LastTaskResult)
    }

    return $true
}

if ($Mode -ne 'status') {
    Ensure-Admin -ScriptPath $PSCommandPath -ScriptArgs @('-Mode', $Mode)
}

Write-Head 'RobloxUnlocker - автоподдержка'

switch ($Mode) {
    'install' { $null = Invoke-Install }
    'remove'  { $null = Invoke-Remove }
    'status'  { $null = Invoke-Status }
}
