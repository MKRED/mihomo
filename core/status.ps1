<#
.SYNOPSIS
  Показывает состояние службы mihomo, подписки и выбранного сервера.

.PARAMETER All
  Дополнительно прогнать все серверы группы и вывести задержки.

.PARAMETER Api
  Адрес API mihomo. По умолчанию берётся из config.template.yaml (external-controller).
#>
[CmdletBinding()]
param(
    [switch]$All,
    [string]$Api
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Bin  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Bin
$Group = 'proxy'   # имя группы в config.template.yaml

$apiForced = [bool]$Api   # с явным -Api опрашиваем API, даже если служба не установлена (для проверки)
if (-not $Api) {
    $Api = '127.0.0.1:9090'
    $line = Get-Content (Join-Path $Root 'config.template.yaml') -Encoding UTF8 | Where-Object { $_ -match '^\s*external-controller:\s*(\S+)' } | Select-Object -First 1
    if ($line -and $line -match '^\s*external-controller:\s*(\S+)') { $Api = $Matches[1].Trim('"', "'") }
}

function Get-Api([string]$Path) {
    # Invoke-RestMethod в PS 5.1 считает ответ без charset латиницей и портит кириллицу в именах серверов
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    try { $wc.DownloadString("http://$Api$Path") | ConvertFrom-Json } finally { $wc.Dispose() }
}

# --- Служба -------------------------------------------------------------------
$svc = Get-Service -Name 'mihomo' -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "Служба mihomo: не установлена"
} elseif ($svc.Status -ne 'Running') {
    $state = switch ($svc.Status) { 'Stopped' { 'остановлена' } 'StartPending' { 'запускается' } 'StopPending' { 'останавливается' } default { $svc.Status } }
    Write-Host "Служба mihomo: $state"
} else {
    $uptime = ''
    # StartTime процесса службы (SYSTEM) без прав администратора не читается, берём из WMI
    $started = $null
    try {
        $proc = Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction Stop | Sort-Object CreationDate | Select-Object -First 1
        if ($proc) { $started = $proc.CreationDate }
    } catch {}
    if ($started) {
        $span = (Get-Date) - $started
        $uptime = if ($span.TotalDays -ge 1) { " (работает {0} д {1} ч)" -f [int][math]::Floor($span.TotalDays), $span.Hours }
                  elseif ($span.TotalHours -ge 1) { " (работает {0} ч {1} мин)" -f [int][math]::Floor($span.TotalHours), $span.Minutes }
                  else { " (работает {0} мин)" -f [int][math]::Floor($span.TotalMinutes) }
    }
    Write-Host "Служба mihomo: работает$uptime"
}

# --- API: подписка и выбранный сервер ----------------------------------------
if (-not $apiForced -and (-not $svc -or $svc.Status -ne 'Running')) { exit 0 }
try {
    # Подписки (sub, sub2...) — это провайдеры типа HTTP; встроенный default к ним не относится
    $providers = Get-Api '/providers/proxies'
    $subs = @($providers.providers.PSObject.Properties | Where-Object { $_.Value.vehicleType -eq 'HTTP' } | Sort-Object Name | ForEach-Object { $_.Value })
    foreach ($pr in $subs) {
        $count = @($pr.proxies).Count
        $updated = if ($pr.updatedAt) { ([DateTime]$pr.updatedAt).ToString('yyyy-MM-dd HH:mm') } else { '?' }
        $paid = ''
        if ($pr.subscriptionInfo -and $pr.subscriptionInfo.Expire -gt 0) {
            $paid = ", оплачена до " + [DateTimeOffset]::FromUnixTimeSeconds([long]$pr.subscriptionInfo.Expire).LocalDateTime.ToString('yyyy-MM-dd')
        }
        $label = if ($subs.Count -gt 1) { "Подписка $($pr.name)" } else { 'Подписка' }
        Write-Host "${label}: серверов $count, обновлена $updated$paid"
    }

    # В /proxies лежат группы (у них есть all и now), серверы подписок — в /providers/proxies.
    # Читаем всё одним запросом: имя с эмодзи в адресе /proxies/<имя> mihomo не находит
    $px = (Get-Api '/proxies').proxies
    $servers = @{}
    foreach ($pr in $subs) { foreach ($p in @($pr.proxies)) { $servers[$p.name] = $p } }
    function Test-IsGroup([string]$Name) { $p = $px.$Name; [bool]($p -and $p.PSObject.Properties['all']) }

    # Если proxy — переключатель (select), его выбор и есть режим работы
    $modeGroup = $Group
    if ($px.$Group.type -eq 'Selector' -and $px.$Group.now) {
        $modeGroup = $px.$Group.now
        Write-Host "Режим: $modeGroup"
    }

    # Цепочка выбора: режим -> группа приоритета -> сервер
    $chain = @()
    $name = $modeGroup
    while ((Test-IsGroup $name) -and $px.$name.now -and $chain.Count -lt 10) { $name = $px.$name.now; $chain += $name }
    if (-not $chain) {
        Write-Host "Прокси сейчас: ещё не выбран"
    } else {
        $delay = ''
        $h = if ($servers.ContainsKey($name)) { @($servers[$name].history) | Select-Object -Last 1 }
        if ($h -and $h.delay -gt 0) { $delay = " ($($h.delay) мс)" }
        Write-Host "Прокси сейчас: $($chain -join ' → ')$delay"
    }

    if ($All) {
        $url = [Uri]::EscapeDataString('https://www.gstatic.com/generate_204')
        # Группы приоритета по порядку, а если режим состоит из серверов, то он сам
        $members = @($px.$modeGroup.all)
        $tiers = if ($members -and @($members | Where-Object { Test-IsGroup $_ }).Count -eq $members.Count) { $members } else { @($modeGroup) }
        Write-Host ""
        Write-Host "Проверяю серверы..."
        $n = 0
        foreach ($tier in $tiers) {
            $n++
            $g = $px.$tier
            if ($tiers.Count -gt 1) {
                $mark = if ($tier -eq $px.$modeGroup.now) { '  ← используется' } else { '' }
                Write-Host ""
                Write-Host "$n. $tier$mark"
            }
            if (-not @($g.all)) { Write-Host "    серверов нет"; continue }
            $alive = @{}
            try {
                $d = Get-Api "/group/$([Uri]::EscapeDataString($tier))/delay?url=$url&timeout=5000"
                foreach ($prop in $d.PSObject.Properties) { $alive[$prop.Name] = [int]$prop.Value }
            } catch {}  # mihomo отвечает ошибкой, если в группе не ответил ни один сервер
            foreach ($s in $g.all) {
                $mark = if ($s -eq $g.now) { '*' } else { ' ' }
                $ms = if ($alive.ContainsKey($s) -and $alive[$s] -gt 0) { "$($alive[$s]) мс" } else { 'не отвечает' }
                Write-Host ("  {0} {1,-40} {2}" -f $mark, $s, $ms)
            }
        }
        Write-Host ""
        Write-Host "  * — выбран в своей группе"
    }
} catch {
    Write-Host "API ($Api) не отвечает: $($_.Exception.Message)"
    exit 1
}
exit 0
