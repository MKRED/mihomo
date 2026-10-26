<#
.SYNOPSIS
  Скачивает бинарники, которых нет в git: mihomo.exe и обёртку службы WinSW (mihomo-service.exe).

.DESCRIPTION
  Файлы кладутся рядом со скриптом (core\). Уже имеющиеся файлы не трогаются, если не указан -Force.
  Скрипт только скачивает и распаковывает, ничего не запускает: иначе антивирусы
  видят «скачал exe и сразу выполнил» и бьют тревогу.
  mihomo берётся из Releases этого репозитория (теги core-v*): это официальные исходники
  с патчами из patches\, собранные GitHub Actions (.github\workflows\build-core.yml).
  Сборка «compatible»: работает на любом x64-процессоре. Контрольная сумма архива проверяется.

.PARAMETER Force
  Скачать заново, даже если файлы уже есть (например, чтобы обновить версию).

.PARAMETER MihomoVersion
  Версия mihomo, например 1.19.33. По умолчанию последняя собранная в Releases репозитория.

.PARAMETER Upstream
  Взять официальную сборку MetaCubeX без патчей (серверы Xray v26.7.11+ с REALITY в ней не работают).

.PARAMETER Repo
  Репозиторий GitHub, в Releases которого лежат сборки с патчами.

.PARAMETER WinswVersion
  Версия WinSW, см. https://github.com/winsw/winsw/releases
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$MihomoVersion,
    [switch]$Upstream,
    [string]$Repo          = 'MKRED/mihomo',
    [string]$WinswVersion  = '2.12.0'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Bin = Split-Path -Parent $MyInvocation.MyCommand.Path

# TLS 1.2 обязателен для GitHub; TLS 1.3 добавляем, если система его знает (на старых Windows 10 его нет)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

function Get-File {
    param([string]$Url, [string]$Path)
    Write-Host "  скачиваю $Url"
    $tmp = "$Path.part"
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 900
    Move-Item $tmp $Path -Force
    Write-Host ("  готово, {0:N1} МБ" -f ((Get-Item $Path).Length / 1MB))
}

$ok = $true

# --- mihomo -----------------------------------------------------------------
$exe = Join-Path $Bin 'mihomo.exe'
if ($Force -or -not (Test-Path $exe)) {
    $zip = Join-Path $Bin 'mihomo-download.zip'
    $extract = Join-Path $Bin 'mihomo-download-tmp'
    try {
        if ($Upstream) {
            if (-not $MihomoVersion) { throw "для -Upstream укажите -MihomoVersion, например 1.19.33" }
            Write-Host "mihomo $MihomoVersion (официальная сборка, без патчей)"
            Get-File "https://github.com/MetaCubeX/mihomo/releases/download/v$MihomoVersion/mihomo-windows-amd64-compatible-v$MihomoVersion.zip" $zip
        } else {
            if ($MihomoVersion) {
                $tag = "core-v$MihomoVersion"
            } else {
                # Последняя по номеру версии сборка, а не последняя по дате: вручную могли пересобрать старую
                $rels = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=50" -UseBasicParsing -TimeoutSec 60
                $tag = @($rels) | Where-Object { -not $_.draft -and $_.tag_name -match '^core-v\d+\.\d+\.\d+$' } |
                    Sort-Object { [version]($_.tag_name -replace '^core-v', '') } -Descending |
                    Select-Object -First 1 -ExpandProperty tag_name
                if (-not $tag) { throw "в https://github.com/$Repo/releases нет сборок core-v*" }
            }
            Write-Host "mihomo $($tag -replace '^core-v', '') с патчами ($Repo)"
            $base = "https://github.com/$Repo/releases/download/$tag/mihomo-windows-amd64-compatible.zip"
            Get-File $base $zip
            $sumFile = "$zip.sha256"
            Invoke-WebRequest -Uri "$base.sha256" -OutFile $sumFile -UseBasicParsing -TimeoutSec 60
            $want = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0].ToLower()
            Remove-Item $sumFile -Force
            $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
            if ($got -ne $want) { throw "контрольная сумма архива не совпала (ожидалась $want, получилась $got)" }
            Write-Host "  контрольная сумма совпала"
        }
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        $found = Get-ChildItem $extract -Recurse -Filter '*.exe' | Select-Object -First 1
        if (-not $found) { throw "в архиве нет exe" }
        Move-Item $found.FullName $exe -Force
        Write-Host ("  распакован mihomo.exe, {0:N1} МБ" -f ((Get-Item $exe).Length / 1MB))
    } catch {
        Write-Host "  ОШИБКА: $($_.Exception.Message)"
        $ok = $false
    } finally {
        if (Test-Path $zip) { Remove-Item $zip -Force }
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    }
} else {
    Write-Host ("mihomo.exe уже есть ({0:N1} МБ)" -f ((Get-Item $exe).Length / 1MB))
}

# --- WinSW (обёртка, запускающая mihomo как службу Windows) ----------------
$svcExe = Join-Path $Bin 'mihomo-service.exe'
if ($Force -or -not (Test-Path $svcExe)) {
    Write-Host "WinSW $WinswVersion"
    try {
        Get-File "https://github.com/winsw/winsw/releases/download/v$WinswVersion/WinSW-x64.exe" $svcExe
    } catch {
        Write-Host "  ОШИБКА: $($_.Exception.Message)"
        $ok = $false
    }
} else {
    Write-Host "mihomo-service.exe уже есть: WinSW $((Get-Item $svcExe).VersionInfo.FileVersion)"
}

if (-not $ok) {
    Write-Host ""
    Write-Host "Не всё скачалось. Можно положить файлы в core\ вручную:"
    Write-Host "  mihomo.exe из https://github.com/$Repo/releases (архив mihomo-windows-amd64-compatible.zip, релиз core-v*)"
    Write-Host "  WinSW-x64.exe из https://github.com/winsw/winsw/releases, переименовать в mihomo-service.exe"
    exit 1
}
Write-Host ""
Write-Host "Если антивирус ругается на этот скрипт или на mihomo.exe, добавьте папку проекта в исключения:"
Write-Host "  это обычное поведение для загрузки программы и создания VPN-адаптера, а не заражение."
exit 0
