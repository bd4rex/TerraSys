param(
  [string]$OutputRoot = "",
  [switch]$SkipDockerImages,
  [bool]$IncludeNominatimIndex = $true,
  [bool]$IncludeOsmCartoIndex = $true,
  [int]$Keep = 1
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
. (Join-Path $PSScriptRoot "offline-kit-support.ps1")
. (Join-Path $PSScriptRoot "offline-map-snapshot.ps1")
if (-not $OutputRoot) { $OutputRoot = Join-Path $root "offline-kit" }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$target = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) $timestamp
$payload = Join-Path $target "payload\TerraSys"
$dockerDirectory = Join-Path $target "docker"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Copy-PayloadFile([string]$Source, [string]$RelativePath) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Required offline-kit file is missing: $Source"
  }
  $destination = Join-Path $payload $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination -Force
}

function Copy-PayloadTree([string]$SourceDirectory, [string]$RelativeDirectory) {
  if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Required offline-kit directory is missing: $SourceDirectory"
  }
  $sourcePrefix = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
  foreach ($file in Get-ChildItem -LiteralPath $sourcePrefix -Recurse -File -Force) {
    if ($file.Name -eq ".env" -or $file.Extension -eq ".pyc" -or $file.FullName -match '[\\/]__pycache__[\\/]') { continue }
    $relative = $file.FullName.Substring($sourcePrefix.Length + 1)
    Copy-PayloadFile $file.FullName (Join-Path $RelativeDirectory $relative)
  }
}

New-Item -ItemType Directory -Force -Path $payload, $dockerDirectory | Out-Null

$outputDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutputRoot))
$freeBytes = [IO.DriveInfo]::new($outputDrive).AvailableFreeSpace
$previousKit = Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue |
  Where-Object { -not $_.Name.EndsWith('.failed') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')) } |
  Sort-Object Name -Descending | Select-Object -First 1
$estimatedBytes = if ($previousKit) {
  [int64]((Get-ChildItem -LiteralPath $previousKit.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum * 1.15)
} else { 20GB }
if ($freeBytes -lt $estimatedBytes + 2GB) {
  throw "Not enough free space for a new offline kit. Required estimate: $([math]::Round(($estimatedBytes + 2GB) / 1GB, 1)) GiB; available: $([math]::Round($freeBytes / 1GB, 1)) GiB."
}

Write-Host "Creating a fresh personal-data recovery point..."
& (Join-Path $PSScriptRoot "backup-terrasys.ps1") | Out-Host
$latestBackup = Get-ChildItem -LiteralPath (Join-Path $root "backups") -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latestBackup) { throw "No database backup is available for the offline kit." }

Write-Host "Copying project and offline data..."
Copy-TerraSysOfflineProject -Root $root -Destination $payload

$mapPackState = Join-Path $root "data\maintenance\map-pack-state.json"
if (Test-Path -LiteralPath $mapPackState -PathType Leaf) {
  Copy-PayloadFile $mapPackState "data\maintenance\map-pack-state.json"
}

foreach ($relative in @(
  "raw\osm\china\china-latest.osm.pbf",
  "raw\osm\china\china.state.txt"
)) {
  Copy-PayloadFile (Join-Path $root $relative) $relative
}
$catalog = Get-TerraSysExpandedCatalog -Root $root
$includedPacks = @()
$skippedPackCount = 0
foreach ($dataset in @($catalog.datasets)) {
  $snapshot = Copy-TerraSysOfflineMap -Root $root -Destination $payload -Dataset $dataset
  if ($snapshot) { $includedPacks += $snapshot } else { $skippedPackCount++ }
}
Write-Host "Included $($includedPacks.Count) installed map packs; skipped $skippedPackCount catalogued but uninstalled packs."
Copy-PayloadTree (Join-Path $root "raw\osm\polygons") "raw\osm\polygons"
Copy-PayloadTree (Join-Path $root "raw\planetiler-sources") "raw\planetiler-sources"
Copy-PayloadTree $latestBackup.FullName (Join-Path "backups" $latestBackup.Name)

foreach ($resourceTree in @(
  @{ Source = "raw\natural-earth"; Target = "raw\natural-earth" },
  @{ Source = "raw\osm\carto"; Target = "raw\osm\carto" },
  @{ Source = "products\osm-carto"; Target = "products\osm-carto" },
  @{ Source = "products\weather"; Target = "products\weather" },
  @{ Source = "products\nautical"; Target = "products\nautical" },
  @{ Source = "products\encyclopedia"; Target = "products\encyclopedia" }
)) {
  Copy-PayloadTree (Join-Path $root $resourceTree.Source) $resourceTree.Target
}

$advancedManifest = Join-Path $root "raw\osm\china\terrasys-core.manifest.json"
$advancedIncluded = Test-Path -LiteralPath $advancedManifest -PathType Leaf
if ($advancedIncluded) {
  foreach ($relative in @(
    "raw\osm\china\terrasys-core-latest.osm.pbf",
    "raw\osm\china\terrasys-core.manifest.json"
  )) {
    Copy-PayloadFile (Join-Path $root $relative) $relative
  }
  $activeRouting = Join-Path $root "products\routing\valhalla"
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    $valhallaInspect = docker inspect terrasys-valhalla 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and @($valhallaInspect).Count -gt 0) {
      $activeMount = $valhallaInspect[0].Mounts | Where-Object { $_.Destination -eq "/custom_files" } | Select-Object -First 1
      if ($activeMount.Source) { $activeRouting = [string]$activeMount.Source }
    }
  }
  foreach ($name in @(
    "terrasys-core-latest.osm.pbf", "valhalla_tiles.tar", "valhalla.json", "admins.sqlite",
    "timezones.sqlite", "default_speeds.json", "file_hashes.txt"
  )) {
    Copy-PayloadFile (Join-Path $activeRouting $name) (Join-Path "products\routing\valhalla" $name)
  }
  Copy-PayloadTree (Join-Path $root "products\elevation") "products\elevation"
}

$images = @(Get-TerraSysOfflineKitImages -Root $root)

$nominatimIndexIncluded = $false
$nominatimArchiveName = "nominatim-data.tar.gz"
if ($advancedIncluded -and $IncludeNominatimIndex) {
  docker exec terrasys-nominatim test -f /var/lib/postgresql/16/main/import-finished
  Assert-NativeSuccess "Checking the completed Nominatim index"
  $nominatimInspect = (docker inspect terrasys-nominatim | ConvertFrom-Json)[0]
  $nominatimVolume = [string]($nominatimInspect.Mounts |
    Where-Object { $_.Destination -eq "/var/lib/postgresql/16/main" } |
    Select-Object -First 1 -ExpandProperty Name)
  if (-not $nominatimVolume) { throw "Nominatim data volume could not be identified." }
  Write-Host "Creating a consistent Nominatim volume snapshot..."
  docker stop terrasys-nominatim | Out-Null
  try {
    docker run --rm -v "${nominatimVolume}:/source:ro" -v "${dockerDirectory}:/backup" `
      postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
      tar -C /source -czf "/backup/$nominatimArchiveName" .
    Assert-NativeSuccess "Archiving the Nominatim data volume"
    $nominatimIndexIncluded = $true
  }
  finally {
    docker start terrasys-nominatim | Out-Null
  }
}

$osmCartoIncluded = $false
$osmCartoArchiveName = "osm-carto-data.tar.gz"
$osmCartoManifest = Join-Path $root "products\osm-carto\osm-carto.manifest.json"
if ($IncludeOsmCartoIndex -and (Test-Path -LiteralPath $osmCartoManifest -PathType Leaf)) {
  $cartoInspect = (docker inspect terrasys-osm-carto | ConvertFrom-Json)[0]
  Assert-NativeSuccess "Inspecting the OSM Carto renderer"
  $cartoVolume = [string]($cartoInspect.Mounts |
    Where-Object { $_.Destination -eq "/data/database" } |
    Select-Object -First 1 -ExpandProperty Name)
  if (-not $cartoVolume) { throw "OSM Carto database volume could not be identified." }
  Write-Host "Creating a consistent OSM Carto database snapshot..."
  docker stop terrasys-osm-carto | Out-Null
  try {
    docker run --rm -v "${cartoVolume}:/source:ro" -v "${dockerDirectory}:/backup" `
      postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
      tar -C /source -czf "/backup/$osmCartoArchiveName" .
    Assert-NativeSuccess "Archiving the OSM Carto database volume"
    $osmCartoIncluded = $true
  }
  finally {
    docker start terrasys-osm-carto | Out-Null
  }
}

if (-not $SkipDockerImages) {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required to export offline images." }
  foreach ($image in $images) {
    docker image inspect $image *> $null
    Assert-NativeSuccess "Finding Docker image $image"
  }
  Write-Host "Exporting Docker runtime, build, and verification images..."
  docker save --output (Join-Path $dockerDirectory "terrasys-images.tar") $images
  Assert-NativeSuccess "Exporting Docker images"
}

$kitInfo = [ordered]@{
  schemaVersion = 5
  id = $timestamp
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  sourceRoot = $root
  databaseBackup = $latestBackup.Name
  includesDockerImages = -not $SkipDockerImages
  dockerImages = $images
  regionPacks = $includedPacks
  operationalResources = @("overview-map", "weather", "nautical", "encyclopedia", "travel-guide", "tts")
  chinaPbf = "raw/osm/china/china-latest.osm.pbf"
  advancedCapabilities = $advancedIncluded
  nominatimIndexIncluded = $nominatimIndexIncluded
  nominatimIndexArchive = if ($nominatimIndexIncluded) { "docker/$nominatimArchiveName" } else { $null }
  osmCartoIncluded = $osmCartoIncluded
  osmCartoArchive = if ($osmCartoIncluded) { "docker/$osmCartoArchiveName" } else { $null }
}
[IO.File]::WriteAllText((Join-Path $target "kit-info.json"), ($kitInfo | ConvertTo-Json -Depth 5), $utf8NoBom)
Copy-Item -LiteralPath (Join-Path $root "docs\OFFLINE_RECOVERY.md") -Destination (Join-Path $target "README-OFFLINE.md") -Force
Copy-Item -LiteralPath (Join-Path $root "scripts\restore-offline-kit.ps1") -Destination (Join-Path $target "restore-offline-kit.ps1") -Force
Copy-Item -LiteralPath (Join-Path $root "scripts\verify-offline-kit.ps1") -Destination (Join-Path $target "verify-offline-kit.ps1") -Force

Write-Host "Hashing the complete offline kit..."
$manifest = Get-ChildItem -LiteralPath $target -Recurse -File | Sort-Object FullName | ForEach-Object {
  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
  [ordered]@{
    Path = $_.FullName.Substring($target.Length + 1).Replace('\', '/')
    Bytes = $_.Length
    SHA256 = $hash.Hash.ToLowerInvariant()
  }
}
[IO.File]::WriteAllText((Join-Path $target "manifest.json"), ($manifest | ConvertTo-Json -Depth 4), $utf8NoBom)

& (Join-Path $PSScriptRoot "verify-offline-kit.ps1") -KitDirectory $target | Out-Host
if ([IO.Path]::GetFullPath($OutputRoot).TrimEnd('\') -eq [IO.Path]::GetFullPath((Join-Path $root "offline-kit")).TrimEnd('\')) {
  & (Join-Path $PSScriptRoot "prune-offline-kits.ps1") -Keep $Keep | Out-Host
}
Write-Host "Offline recovery kit created: $target"
