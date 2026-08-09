param(
  [Parameter(Mandatory = $true)]
  [string]$KitDirectory,
  [Parameter(Mandatory = $true)]
  [string]$TargetDirectory,
  [switch]$SkipImageLoad,
  [switch]$PrepareOnly
)

$ErrorActionPreference = "Stop"
$kit = (Resolve-Path -LiteralPath $KitDirectory).Path.TrimEnd('\')
$payload = Join-Path $kit "payload\TerraSys"
$imageArchive = Join-Path $kit "docker\terrasys-images.tar"
$dockerDirectory = Join-Path $kit "docker"
$kitInfoPath = Join-Path $kit "kit-info.json"
if (-not (Test-Path -LiteralPath $payload -PathType Container)) {
  throw "Offline-kit payload is missing: $payload"
}

& (Join-Path $PSScriptRoot "verify-offline-kit.ps1") -KitDirectory $kit | Out-Host

$target = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
if (Test-Path -LiteralPath $target) {
  if (@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) {
    throw "Target directory must be empty: $target"
  }
}
else {
  New-Item -ItemType Directory -Force -Path $target | Out-Null
}

foreach ($item in Get-ChildItem -LiteralPath $payload -Force) {
  Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
}

if (-not $SkipImageLoad) {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required to load the offline images."
  }
  if (-not (Test-Path -LiteralPath $imageArchive -PathType Leaf)) {
    throw "Docker image archive is missing: $imageArchive"
  }
  docker load --input $imageArchive | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Loading offline Docker images failed." }
}

if ($PrepareOnly) {
  Write-Host "Offline payload restored to: $target"
  Write-Host "Services and the Nominatim volume were not started because -PrepareOnly was supplied."
  exit 0
}

$kitInfo = Get-Content -Raw -LiteralPath $kitInfoPath | ConvertFrom-Json
if ($kitInfo.nominatimIndexIncluded) {
  $nominatimArchive = Join-Path $kit ([string]$kitInfo.nominatimIndexArchive).Replace('/', '\')
  if (-not (Test-Path -LiteralPath $nominatimArchive -PathType Leaf)) {
    throw "Nominatim index archive is missing: $nominatimArchive"
  }
  $projectName = (Split-Path (Join-Path $target "services") -Leaf).ToLowerInvariant() -replace '[^a-z0-9_-]', ''
  $nominatimVolume = "${projectName}_terrasys_nominatim_data"
  docker volume inspect $nominatimVolume *> $null
  if ($LASTEXITCODE -eq 0) {
    $entryCount = ((docker run --rm -v "${nominatimVolume}:/target:ro" `
      postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
      sh -c 'find /target -mindepth 1 -maxdepth 1 | head -1 | wc -l') -join "").Trim()
    if ($entryCount -ne "0") { throw "Refusing to overwrite non-empty Docker volume: $nominatimVolume" }
  }
  else {
    docker volume create $nominatimVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating the Nominatim recovery volume failed." }
  }
  Write-Host "Restoring the offline Nominatim index..."
  docker run --rm -v "${nominatimVolume}:/target" -v "${dockerDirectory}:/backup:ro" `
    postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
    tar -C /target -xzf "/backup/$([IO.Path]::GetFileName($nominatimArchive))"
  if ($LASTEXITCODE -ne 0) { throw "Restoring the Nominatim index failed." }
}

if ($kitInfo.osmCartoIncluded) {
  $cartoArchive = Join-Path $kit ([string]$kitInfo.osmCartoArchive).Replace('/', '\')
  if (-not (Test-Path -LiteralPath $cartoArchive -PathType Leaf)) {
    throw "OSM Carto database archive is missing: $cartoArchive"
  }
  $cartoVolume = "terrasys_osm_carto_data"
  docker volume inspect $cartoVolume *> $null
  if ($LASTEXITCODE -eq 0) {
    $entryCount = ((docker run --rm -v "${cartoVolume}:/target:ro" `
      postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
      sh -c 'find /target -mindepth 1 -maxdepth 1 | head -1 | wc -l') -join "").Trim()
    if ($entryCount -ne "0") { throw "Refusing to overwrite non-empty Docker volume: $cartoVolume" }
  }
  else {
    docker volume create $cartoVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating the OSM Carto recovery volume failed." }
  }
  Write-Host "Restoring the offline OSM Carto database..."
  docker run --rm -v "${cartoVolume}:/target" -v "${dockerDirectory}:/backup:ro" `
    postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
    tar -C /target -xzf "/backup/$([IO.Path]::GetFileName($cartoArchive))"
  if ($LASTEXITCODE -ne 0) { throw "Restoring the OSM Carto database failed." }
}

& (Join-Path $target "scripts\start-terrasys.ps1") -NoBuild
$backupRoot = Join-Path $target "backups"
$latestBackup = Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latestBackup) { throw "The restored payload contains no database backup." }
& (Join-Path $target "scripts\restore-terrasys.ps1") -BackupDirectory $latestBackup.FullName
& (Join-Path $target "scripts\health-check.ps1") | Out-Host

Write-Host "Offline TerraSys recovery completed: $target"
Write-Host "Map: http://localhost:8080/"
