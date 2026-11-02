<#
.SYNOPSIS
  Собирает core\config.yaml из config.template.yaml и subscription.txt, затем проверяет его mihomo.exe.

.DESCRIPTION
  В subscription.txt по ссылке на подписку в строке (строки, начинающиеся с #, пропускаются).
  В шаблоне описана одна подписка, proxy-providers.sub, с url "SUBSCRIPTION_URL".
  Для первой ссылки этот блок остаётся как есть, для каждой следующей копируется
  под именами sub2, sub3... (со своим файлом в providers\), и все они добавляются в use группы.
  Если ссылок несколько, к именам серверов добавляется номер подписки ([1] , [2] ...),
  чтобы одинаково названные серверы разных подписок не путались.
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
    $subUrls = @()
    $n = 0
    foreach ($line in Get-Content $subFile -Encoding UTF8) {
        $n++
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^https?://\S+$') { throw "строка $n в subscription.txt не похожа на ссылку: она должна начинаться с http:// или https:// и не содержать пробелов" }
        if ($subUrls -contains $line) { Write-Host "Строка $n в subscription.txt повторяет ссылку выше, пропускаю"; continue }
        $subUrls += $line
    }
    if (-not $subUrls) { throw "в subscription.txt нет ссылки" }

    $tplPath = Join-Path $Root 'config.template.yaml'
    $tpl = [IO.File]::ReadAllText($tplPath, [Text.Encoding]::UTF8)
    $nl = if ($tpl.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $tpl -split "`r?`n"

    # Блок подписки: от строки "  sub:" до следующей строки с отступом не больше двух пробелов
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^  sub:\s*$') { $start = $i; break } }
    if ($start -lt 0) { throw "в config.template.yaml нет подписки proxy-providers.sub" }
    $end = $start + 1
    while ($end -lt $lines.Count -and $lines[$end] -notmatch '^ {0,2}\S') { $end++ }
    while ($end -gt $start + 1 -and -not $lines[$end - 1].Trim()) { $end-- }  # пустые строки после блока не его
    $block = $lines[$start..($end - 1)]
    if (-not ($block -match '"SUBSCRIPTION_URL"')) { throw "в подписке sub в config.template.yaml нет url: ""SUBSCRIPTION_URL""" }
    if (-not ($block -match '^\s*path:.*/sub\.yaml\s*$')) { throw "в подписке sub в config.template.yaml нет path: ./providers/sub.yaml" }

    $names = @()
    $out = @()
    for ($k = 1; $k -le $subUrls.Count; $k++) {
        $name = if ($k -eq 1) { 'sub' } else { "sub$k" }
        $names += $name
        # Ссылка стоит в YAML внутри двойных кавычек: экранируем \ и "
        $yamlUrl = $subUrls[$k - 1].Replace('\', '\\').Replace('"', '\"')
        $copy = @("  ${name}:")
        foreach ($l in $block[1..($block.Count - 1)]) {
            $l = $l.Replace('"SUBSCRIPTION_URL"', '"' + $yamlUrl + '"')
            if ($l -match '^(\s*path:.*/)sub\.yaml\s*$') { $l = $Matches[1] + "$name.yaml" }
            $copy += $l
            # Номер подписки в начало имён серверов, внутрь уже имеющегося override
            if ($subUrls.Count -gt 1 -and $l -match '^(\s+)override:\s*$') { $copy += "$($Matches[1])  additional-prefix: ""[$k] """ }
        }
        if ($subUrls.Count -gt 1 -and -not ($block -match '^\s+override:\s*$')) {
            $copy += '    override:'
            $copy += "      additional-prefix: ""[$k] """
        }
        if ($k -gt 1) { $out += '' }
        $out += $copy
    }
    $before = if ($start -gt 0) { $lines[0..($start - 1)] } else { @() }
    $after = if ($end -lt $lines.Count) { $lines[$end..($lines.Count - 1)] } else { @() }
    $cfg = (@($before) + $out + @($after)) -join $nl

    # Группы, берущие серверы из подписки: use: [sub] -> use: [sub, sub2, ...]
    if ($names.Count -gt 1) {
        $re = '(?m)^(\s*use:\s*)\[\s*sub\s*\]'
        if ($cfg -notmatch $re) { throw "в config.template.yaml нет группы с use: [sub], подписки 2 и дальше некуда добавить" }
        $cfg = [regex]::Replace($cfg, $re, { param($m) $m.Groups[1].Value + '[' + ($names -join ', ') + ']' })
    }

    $cfgPath = Join-Path $Bin 'config.yaml'
    [IO.File]::WriteAllText($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))
    $hosts = ($subUrls | ForEach-Object { ([Uri]$_).Host }) -join ', '
    if ($subUrls.Count -eq 1) { Write-Host "config.yaml собран, подписка с $hosts" }
    else { Write-Host "config.yaml собран, подписок $($subUrls.Count): $hosts" }

    if ($NoCheck) { exit 0 }
    $exe = Join-Path $Bin 'mihomo.exe'
    if (-not (Test-Path $exe)) { throw "mihomo.exe не найден, сначала запустите get-binaries.ps1" }
    $check = & $exe -t -d $Bin -f $cfgPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Не показываем строки со ссылками на подписки
        $check | Where-Object { $s = "$_"; -not ($subUrls | Where-Object { $s.Contains($_) }) } | ForEach-Object { Write-Host "  $_" }
        throw "mihomo отклонил config.yaml, см. сообщения выше"
    }
    Write-Host "config.yaml проверен mihomo"
    exit 0
}
catch {
    Write-Host "ОШИБКА: $($_.Exception.Message)"
    exit 1
}
