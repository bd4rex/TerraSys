param(
  [Parameter(Mandatory = $true)]
  [string]$KitDirectory,
  [switch]$SkipDockerImages
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$offlineRoot = [IO.Path]::GetFullPath((Join-Path $root "offline-kit")).TrimEnd('\')
$kit = [IO.Path]::GetFullPath($KitDirectory).TrimEnd('\')
if (-not $kit.StartsWith("$offlineRoot\", [StringComparison]::OrdinalIgnoreCase)) {
  throw "KitDirectory must be an existing child of $offlineRoot."
}
if (-not (Test-Path -LiteralPath (Join-Path $kit "kit-info.json") -PathType Leaf)) {
  throw "The target is not a complete offline kit: $kit"
}

$payload = Join-Path $kit "payload\TerraSys"
$utf8 = New-Object Text.UTF8Encoding($false)

function Copy-PayloadFile([string]$Source, [string]$RelativePath) {
  $destination = Join-Path $payload $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination -Force
}

foreach ($directory in @("docs", "scripts", "services", "tests", "web")) {
  $source = Join-Path $root $directory
  foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File -Force) {
    if ($file.Name -eq ".env" -or $file.Extension -eq ".pyc" -or $file.FullName -match '[\/]__pycache__[\/]') { continue }
    Copy-PayloadFile $file.FullName (Join-Path $directory $file.FullName.Substring($source.Length + 1))
  }
}

foreach ($file in Get-ChildItem -LiteralPath $root -File -Force) {
  if ($file.Name -eq "README.md" -or $file.Name -eq ".gitignore" -or $file.Extension -eq ".cmd") {
    Copy-PayloadFile $file.FullName $file.Name
  }
}

$mapPackState = Join-Path $root "data\maintenance\map-pack-state.json"
if (Test-Path -LiteralPath $mapPackState -PathType Leaf) {
  Copy-PayloadFile $mapPackState "data\maintenance\map-pack-state.json"
}

Copy-Item -LiteralPath (Join-Path $root "docs\OFFLINE_RECOVERY.md") -Destination (Join-Path $kit "README-OFFLINE.md") -Force
Copy-Item -LiteralPath (Join-Path $root "scripts\restore-offline-kit.ps1") -Destination (Join-Path $kit "restore-offline-kit.ps1") -Force
Copy-Item -LiteralPath (Join-Path $root "scripts\verify-offline-kit.ps1") -Destination (Join-Path $kit "verify-offline-kit.ps1") -Force

$images = @(
  "postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538",
  "ghcr.io/maplibre/martin@sha256:0650e9025f5fcffdc686358114679421b5e6b0ca37b374ad8a66f14709d59d2b",
  "nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10",
  "terrasys-api:1", "terrasys-osmium:1", "ghcr.io/onthegomap/planetiler:latest", "terrasys-ui-test:1",
  "mediagis/nominatim@sha256:7923a8e67197fc6d4f4ecb7c0e8bbedffeddcfdf4519596fe946e46a28f5a9f8",
  "ghcr.io/valhalla/valhalla-scripted@sha256:3d7a08f7e78b356ee873b61711b743ad81bcc114b0ca5731217da8bba6ba39d1",
  "ghcr.io/kiwix/kiwix-serve@sha256:57baa553c46cd30770905df15a9a687258aa5471c30c8edaefe278f1784e1aa8"
)
if (-not $SkipDockerImages) {
  Write-Host "Refreshing Docker image archive..."
  docker save --output (Join-Path $kit "docker\terrasys-images.tar") $images
  if ($LASTEXITCODE -ne 0) { throw "Docker image export failed." }
}

$infoPath = Join-Path $kit "kit-info.json"
$info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
$info | Add-Member -NotePropertyName refreshedAt -NotePropertyValue ([DateTimeOffset]::Now.ToUniversalTime().ToString("o")) -Force
[IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json -Depth 8), $utf8)

Write-Host "Hashing refreshed offline kit..."
$manifestPath = Join-Path $kit "manifest.json"
$manifest = Get-ChildItem -LiteralPath $kit -Recurse -File |
  Where-Object { $_.FullName -ne $manifestPath } |
  Sort-Object FullName |
  ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [ordered]@{
      Path = $_.FullName.Substring($kit.Length + 1).Replace('\', '/')
      Bytes = $_.Length
      SHA256 = $hash.Hash.ToLowerInvariant()
    }
  }
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), $utf8)

& (Join-Path $PSScriptRoot "verify-offline-kit.ps1") -KitDirectory $kit
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Offline recovery kit refreshed: $kit"
