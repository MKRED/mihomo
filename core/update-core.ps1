<#
.SYNOPSIS
  Обновляет ядро mihomo до последней сборки с патчами, если она отличается от установленной, и веб-панель.

.DESCRIPTION
  1. Узнаёт последнюю сборку core-v* в Releases и SHA-256 её архива.
  2. Сравнивает с core\mihomo.state.json (какая сборка стоит, пишет get-binaries.ps1).
     Если файла нет или mihomo.exe с тех пор заменили (например, кнопкой обновления ядра в панели),
     скачивает сборку и сравнивает сами exe.
  3. Новое ядро скачивается в core\update-tmp\, пока работает старое; проверяются сумма и конфиг (mihomo -t).
  4. Служба останавливается, mihomo.exe заменяется (старый остаётся как mihomo.old.exe), служба запускается.
     Если за 30 секунд API не ответил новой версией, возвращается старое ядро.
  5. Веб-панель обновляется через API (POST /upgrade/ui), если служба работает.

.PARAMETER CheckOnly
  Только сообщить, есть ли обновление. Если неизвестно, какая сборка стоит, она всё же скачивается для сравнения.

.PARAMETER DryRun
  Всё, кроме остановки службы и замены файла: скачать, проверить, сообщить, что было бы сделано.

.PARAMETER Repo
  Репозиторий GitHub со сборками с патчами.

.PARAMETER Api
  Адрес API mihomo. По умолчанию берётся из config.template.yaml (external-controller).
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$DryRun,
    [string]$Repo = 'MKRED/mihomo',
    [string]$Api
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Bin  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Bin
$exe       = Join-Path $Bin 'mihomo.exe'
$oldExe    = Join-Path $Bin 'mihomo.old.exe'
$stateFile = Join-Path $Bin 'mihomo.state.json'
$cfgPath   = Join-Path $Bin 'config.yaml'
$tmp       = Join-Path $Bin 'update-tmp'   # на том же диске, чтобы замена была мгновенным переименованием

if (-not $Api) {
    $Api = '127.0.0.1:9090'
    $line = Get-Content (Join-Path $Root 'config.template.yaml') -Encoding UTF8 | Where-Object { $_ -match '^\s*external-controller:\s*(\S+)' } | Select-Object -First 1
    if ($line -and $line -match '^\s*external-controller:\s*(\S+)') { $Api = $Matches[1].Trim('"', "'") }
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

function Get-Text([string]$Url) {
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers['User-Agent'] = 'mihomo-update-core'
    try { $wc.DownloadString($Url) } finally { $wc.Dispose() }
}

function Get-Sha256([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLower() }

# Версия из "Mihomo Meta v1.19.33-patched windows amd64 ..."
function Get-ExeVersion([string]$Path) {
    $v = & $Path -v 2>&1 | Select-Object -First 1
    if ("$v" -match '\s(v\S+)') { $Matches[1] } else { '?' }
}

# Время сборки из "... with go1.27.3 Mon Oct 26 05:18:16 UTC 2026" (date -u в build-core.yml)
function Get-ExeBuilt([string]$Path) {
    $v = & $Path -v 2>&1 | Select-Object -First 1
    if ("$v" -match 'with go\S+\s+\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d\d:\d\d):\d\d\s+UTC\s+(\d{4})') {
        $s = "$($Matches[2]) $($Matches[1]) $($Matches[4]) $($Matches[3])"
        try { return [DateTime]::ParseExact($s, 'd MMM yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture, 'AssumeUniversal').ToString('yyyy-MM-dd HH:mm') } catch {}
    }
    '?'
}

function Read-State {
    if (-not (Test-Path $stateFile)) { return $null }
    try { Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Get-ApiVersion {
    try { (Get-Text "http://$Api/version" | ConvertFrom-Json).version } catch { $null }
}

# Ждёт, пока процесс mihomo.exe из core\ завершится: файл бывает занят и после остановки службы
function Wait-ExeFree {
    for ($i = 0; $i -lt 30; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" | Where-Object { $_.ExecutablePath -eq $exe }
        if (-not $p) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "mihomo.exe не завершился после остановки службы"
}

function Move-WithRetry([string]$From, [string]$To) {
    for ($i = 1; ; $i++) {
        try { Move-Item $From $To -Force; return }
        catch { if ($i -ge 10) { throw }; Start-Sleep -Milliseconds 500 }
    }
}

function Update-Ui {
    $svc = Get-Service -Name 'mihomo' -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return }
    Write-Host "Обновляю веб-панель..."
    # Сразу после запуска mihomo API уже отвечает, а ссылка на панель (external-ui-url) ещё не применена:
    # ответ 500 и в логе Get "": unsupported protocol scheme. Поэтому несколько попыток
    $wc = New-Object Net.WebClient
    try {
        for ($i = 1; ; $i++) {
            try {
                $wc.UploadString("http://$Api/upgrade/ui", 'POST', '') | Out-Null
                Write-Host "  панель обновлена, обновите страницу в браузере"
                return
            } catch {
                if ($i -ge 5) { Write-Host "  не получилось обновить панель: $($_.Exception.Message)"; return }
                Start-Sleep -Seconds 3
            }
        }
    } finally { $wc.Dispose() }
}

$exitCode = 0
try {
    if (-not (Test-Path $exe)) { throw "нет core\mihomo.exe: сначала установите службу (service.bat, пункт 1)" }

    # --- Что лежит в Releases ---------------------------------------------------
    $rels = Get-Text "https://api.github.com/repos/$Repo/releases?per_page=50" | ConvertFrom-Json
    $rel = @($rels) | Where-Object { -not $_.draft -and $_.tag_name -match '^core-v\d+\.\d+\.\d+$' } |
        Sort-Object { [version]($_.tag_name -replace '^core-v', '') } -Descending |
        Select-Object -First 1
    if (-not $rel) { throw "в https://github.com/$Repo/releases нет сборок core-v*" }
    $tag = $rel.tag_name
    $latestVer = $tag -replace '^core-v', ''
    # Пересборка той же версии выкладывается под тем же тегом, поэтому показываем и дату сборки
    $asset = @($rel.assets) | Where-Object { $_.name -eq 'mihomo-windows-amd64-compatible.zip' } | Select-Object -First 1
    $latestBuilt = if ($asset) { ([DateTime]$asset.updated_at).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '?' }
    $sumUrl = "https://github.com/$Repo/releases/download/$tag/mihomo-windows-amd64-compatible.zip.sha256"
    $latestSum = ((Get-Text $sumUrl).Trim() -split '\s+')[0].ToLower()

    # --- Что стоит ------------------------------------------------------------------
    $curVer = Get-ExeVersion $exe
    $curHash = Get-Sha256 $exe
    $state = Read-State
    $known = $state -and $state.exe -eq $curHash
    Write-Host "Установлено: mihomo $curVer, собрано $(Get-ExeBuilt $exe)"
    Write-Host "В Releases:  mihomo v$latestVer-patched, собрано $latestBuilt"

    if ($known -and $state.archive -eq $latestSum) {
        Write-Host "Ядро актуально"
        if (-not $CheckOnly -and -not $DryRun) { Update-Ui }
        exit 0
    }
    if ($known) {
        Write-Host "Доступна новая сборка"
        if ($CheckOnly) { exit 0 }
    } else {
        Write-Host "Неизвестно, какая сборка стоит: скачаю последнюю и сравню"
    }

    # --- Скачать и проверить новое ядро -------------------------------------
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    & (Join-Path $Bin 'get-binaries.ps1') -Force -MihomoOnly -OutDir $tmp -MihomoVersion $latestVer -Repo $Repo
    if ($LASTEXITCODE -ne 0) { throw "не удалось скачать новое ядро" }
    $newExe = Join-Path $tmp 'mihomo.exe'
    $newState = Join-Path $tmp 'mihomo.state.json'

    if ((Get-Sha256 $newExe) -eq $curHash) {
        # Стоит ровно эта сборка, просто не было записи о ней
        Move-Item $newState $stateFile -Force
        Write-Host "Ядро актуально (это та же сборка)"
        if (-not $CheckOnly -and -not $DryRun) { Update-Ui }
        exit 0
    }
    if ($CheckOnly) { Write-Host "Доступна новая сборка"; exit 0 }

    $newVer = Get-ExeVersion $newExe
    if (Test-Path $cfgPath) {
        $check = & $newExe -t -d $Bin -f $cfgPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $check | Where-Object { "$_" -notmatch 'https?://' } | ForEach-Object { Write-Host "  $_" }
            throw "новое ядро $newVer не принимает config.yaml, обновление отменено"
        }
        Write-Host "Новое ядро $newVer проверило config.yaml"
    }

    if ($DryRun) {
        Write-Host "DryRun: дальше служба была бы остановлена и mihomo.exe заменён на $newVer. Ничего не тронуто."
        exit 0
    }

    # --- Замена ---------------------------------------------------------------------
    $svc = Get-Service -Name 'mihomo' -ErrorAction SilentlyContinue
    $wasRunning = $svc -and $svc.Status -eq 'Running'
    $oldStateText = if (Test-Path $stateFile) { Get-Content $stateFile -Raw -Encoding UTF8 } else { $null }
    if ($wasRunning) {
        Write-Host "Останавливаю службу: на несколько секунд пропадёт связь у программ, идущих через прокси"
        Stop-Service -Name 'mihomo' -Force
    }
    Wait-ExeFree
    Move-WithRetry $exe $oldExe
    Move-WithRetry $newExe $exe
    Move-Item $newState $stateFile -Force

    if (-not $wasRunning) {
        Write-Host "Ядро заменено на $newVer. Служба не запущена, новое ядро заработает при её запуске"
        exit 0
    }

    Start-Service -Name 'mihomo'
    # Running ещё ничего не значит: WinSW перезапускает упавшее ядро. Ждём ответа API с новой версией
    $apiVer = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $apiVer = Get-ApiVersion
        if ($apiVer -eq $newVer) { break }
    }
    if ($apiVer -ne $newVer) {
        Write-Host "Новое ядро не ответило за 30 секунд (API: $(if ($apiVer) { $apiVer } else { 'молчит' })), возвращаю прежнее"
        Stop-Service -Name 'mihomo' -Force
        Wait-ExeFree
        Move-WithRetry $exe (Join-Path $Bin 'mihomo.failed.exe')
        Move-WithRetry $oldExe $exe
        if ($oldStateText) { [IO.File]::WriteAllText($stateFile, $oldStateText, (New-Object Text.UTF8Encoding($false))) }
        else { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
        Start-Service -Name 'mihomo'
        throw "обновление отменено, работает прежнее ядро $curVer. Новое сохранено как core\mihomo.failed.exe, смотрите лог (пункт 6)"
    }
    Write-Host "Ядро обновлено: $curVer -> $newVer. Прежнее сохранено как core\mihomo.old.exe"
    Update-Ui
} catch {
    Write-Host "ОШИБКА: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
