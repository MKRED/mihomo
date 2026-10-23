<#
.SYNOPSIS
  Собирает core\config.yaml из config.template.yaml и subscription.txt, затем проверяет его mihomo.exe.

.DESCRIPTION
  В шаблоне вместо ссылки на подписку стоит слово SUBSCRIPTION_URL. Ссылка берётся
  из subscription.txt (первая строка, не начинающаяся с #) и подставляется в шаблон.
  Готовый config.yaml проверяется командой mihomo.exe -t. Код возврата 0 — конфиг собран и проверен.

.PARAMETER NoCheck
  Не проверять конфиг (например, если mihomo.exe ещё не скачан).
#>
[CmdletBinding()]
param([switch]$NoCheck)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Bin  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Bin

try {
    $subFile = Join-Path $Root 'subscription.txt'
    if (-not (Test-Path $subFile)) { throw "нет файла subscription.txt: положите в него ссылку на подписку" }
    $subUrl = (Get-Content $subFile -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1)
    if (-not $subUrl) { throw "в subscription.txt нет ссылки" }
    $subUrl = $subUrl.Trim()
    if ($subUrl -notmatch '^https?://') { throw "ссылка в subscription.txt должна начинаться с http:// или https://" }

    $tplPath = Join-Path $Root 'config.template.yaml'
    $tpl = [IO.File]::ReadAllText($tplPath, [Text.Encoding]::UTF8)
    if ($tpl -notmatch 'SUBSCRIPTION_URL') { throw "в config.template.yaml нет слова SUBSCRIPTION_URL" }

    # Ссылка стоит в YAML внутри двойных кавычек: экранируем \ и "
    $yamlUrl = $subUrl.Replace('\', '\\').Replace('"', '\"')
    $cfg = $tpl.Replace('SUBSCRIPTION_URL', $yamlUrl)

    $cfgPath = Join-Path $Bin 'config.yaml'
    [IO.File]::WriteAllText($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))
    Write-Host "config.yaml собран, подписка с $(([Uri]$subUrl).Host)"

    if ($NoCheck) { exit 0 }
    $exe = Join-Path $Bin 'mihomo.exe'
    if (-not (Test-Path $exe)) { throw "mihomo.exe не найден, сначала запустите get-binaries.ps1" }
    $out = & $exe -t -d $Bin -f $cfgPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Не показываем строки с ссылкой на подписку
        $out | Where-Object { $_ -notmatch [regex]::Escape($subUrl) } | ForEach-Object { Write-Host "  $_" }
        throw "mihomo отклонил config.yaml, см. сообщения выше"
    }
    Write-Host "config.yaml проверен mihomo"
    exit 0
}
catch {
    Write-Host "ОШИБКА: $($_.Exception.Message)"
    exit 1
}
