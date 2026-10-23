<#
.SYNOPSIS
  Команды работающей службе mihomo через её API, без перезапуска.

.PARAMETER Action
  Config       - перечитать core\config.yaml (после правки config.template.yaml и сборки build-config.ps1).
                 TUN-адаптер пересоздаётся только если изменился раздел tun.
  Subscription - скачать подписку заново и подменить серверы.

.PARAMETER Api
  Адрес API mihomo. По умолчанию берётся из config.template.yaml (external-controller).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Config', 'Subscription')]
    [string]$Action,
    [string]$Api
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Bin  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Bin
$Provider = 'sub'  # имя подписки в config.template.yaml

if (-not $Api) {
    $Api = '127.0.0.1:9090'
    $line = Get-Content (Join-Path $Root 'config.template.yaml') -Encoding UTF8 | Where-Object { $_ -match '^\s*external-controller:\s*(\S+)' } | Select-Object -First 1
    if ($line -and $line -match '^\s*external-controller:\s*(\S+)') { $Api = $Matches[1].Trim('"', "'") }
}

# Invoke-RestMethod в PS 5.1 считает ответ без charset латиницей и портит кириллицу, поэтому WebClient с UTF-8
$wc = New-Object Net.WebClient
$wc.Encoding = [Text.Encoding]::UTF8
function Put-Api([string]$Path, [string]$Body = '') {
    $wc.Headers['Content-Type'] = 'application/json'
    $wc.UploadString("http://$Api$Path", 'PUT', $Body) | Out-Null
}
function Get-Api([string]$Path) { $wc.DownloadString("http://$Api$Path") | ConvertFrom-Json }

try {
    switch ($Action) {
        'Config' {
            $cfgPath = Join-Path $Bin 'config.yaml'
            if (-not (Test-Path $cfgPath)) { throw "нет core\config.yaml, сначала соберите его build-config.ps1" }
            Put-Api '/configs?force=true' (@{ path = $cfgPath } | ConvertTo-Json -Compress)
            Write-Host "Конфиг перечитан"
        }
        'Subscription' {
            Put-Api "/providers/proxies/$Provider"
            $pr = Get-Api "/providers/proxies/$Provider"
            Write-Host "Подписка обновлена, серверов в группе: $(@($pr.proxies).Count)"
        }
    }
    exit 0
} catch {
    $msg = $_.Exception.Message
    # Текст ошибки от API лежит в теле ответа
    $resp = $_.Exception.InnerException
    if ($resp -is [Net.WebException] -and $resp.Response) {
        try { $body = (New-Object IO.StreamReader($resp.Response.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd(); if ($body) { $msg = $body } } catch {}
    }
    Write-Host "Не получилось ($Api): $msg"
    exit 1
} finally {
    $wc.Dispose()
}
