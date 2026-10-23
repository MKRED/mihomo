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
$Provider = 'sub'  # имя подписки в config.template.yaml

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
    $pr = Get-Api "/providers/proxies/$Provider"
    $count = @($pr.proxies).Count
    $updated = if ($pr.updatedAt) { ([DateTime]$pr.updatedAt).ToString('yyyy-MM-dd HH:mm') } else { '?' }
    $paid = ''
    if ($pr.subscriptionInfo -and $pr.subscriptionInfo.Expire -gt 0) {
        $paid = ", оплачена до " + [DateTimeOffset]::FromUnixTimeSeconds([long]$pr.subscriptionInfo.Expire).LocalDateTime.ToString('yyyy-MM-dd')
    }
    Write-Host "Подписка: серверов $count, обновлена $updated$paid"

    $g = Get-Api "/proxies/$Group"
    $now = if ($g.now) { $g.now } else { 'ещё не выбран' }
    $delay = ''
    if ($g.now) {
        # Серверы подписки лежат в /providers/proxies, а не в /proxies; имя с эмодзи в адресе запроса mihomo не находит
        $p = @($pr.proxies) | Where-Object { $_.name -eq $g.now } | Select-Object -First 1
        $h = if ($p) { @($p.history) | Select-Object -Last 1 }
        if ($h -and $h.delay -gt 0) { $delay = " ($($h.delay) мс)" }
    }
    Write-Host "Прокси сейчас: $now$delay"

    if ($All) {
        Write-Host ""
        Write-Host "Проверяю серверы группы $Group..."
        $url = [Uri]::EscapeDataString('https://www.gstatic.com/generate_204')
        $d = Get-Api "/group/$Group/delay?url=$url&timeout=5000"
        $alive = @{}
        foreach ($prop in $d.PSObject.Properties) { $alive[$prop.Name] = [int]$prop.Value }
        foreach ($name in $g.all) {
            $mark = if ($name -eq $g.now) { '*' } else { ' ' }
            $ms = if ($alive.ContainsKey($name) -and $alive[$name] -gt 0) { "$($alive[$name]) мс" } else { 'не отвечает' }
            Write-Host ("  {0} {1,-40} {2}" -f $mark, $name, $ms)
        }
        Write-Host "  * — выбран сейчас"
    }
} catch {
    Write-Host "API ($Api) не отвечает: $($_.Exception.Message)"
    exit 1
}
exit 0
