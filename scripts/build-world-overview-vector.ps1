param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "offline-kit-support.ps1")
$planetilerImage = Get-TerraSysToolImage -Root $root -Name "planetiler"
$schema = Join-Path $root "config\planetiler\world-overview.yml"
$outputRoot = Join-Path $root "web\assets\overview"
$target = Join-Path $outputRoot "world-overview.pmtiles"
$staged = Join-Path $outputRoot "world-overview.staged.pmtiles"
$manifestPath = Join-Path $outputRoot "overview.manifest.json"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

if (-not (Test-Path -LiteralPath $schema -PathType Leaf)) { throw "World overview schema is missing: $schema" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required to build the world overview." }
docker image inspect $planetilerImage | Out-Null
Assert-NativeSuccess "Checking the pinned Planetiler image"

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$rootPath = [IO.Path]::GetFullPath($root)
docker run --rm --memory 5g --memory-swap 6g --cpus 4 `
  -e JAVA_TOOL_OPTIONS="-Xmx4g" `
  -v "${rootPath}:/data" `
  $planetilerImage generate-custom `
  --schema=/data/config/planetiler/world-overview.yml `
  --output=/data/web/assets/overview/world-overview.staged.pmtiles `
  --download=true `
  --tmpdir=/data/tmp/planetiler-world-overview `
  --bounds=-180,-85.05112878,180,85.05112878 `
  --minzoom=0 `
  --maxzoom=7 `
  --render_maxzoom=7 `
  --force=true
Assert-NativeSuccess "Building the low-zoom world overview"

if (-not (Test-Path -LiteralPath $staged -PathType Leaf) -or (Get-Item -LiteralPath $staged).Length -lt 1MB) {
  throw "The staged world overview is missing or unexpectedly small."
}
$stream = [IO.File]::OpenRead($staged)
try {
  $header = New-Object byte[] 7
  [void]$stream.Read($header, 0, 7)
}
finally { $stream.Dispose() }
if ([Text.Encoding]::ASCII.GetString($header) -ne "PMTiles") { throw "The staged world overview has an invalid PMTiles header." }
Move-Item -LiteralPath $staged -Destination $target -Force

$existingManifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
} else { $null }
$files = @(Get-ChildItem -LiteralPath $outputRoot -File | Where-Object {
  $_.Name -ne "overview.manifest.json" -and $_.Name -notlike "*.staged.*" -and $_.Name -notlike "*.layerstats.*"
})
$sourceUrls = @($existingManifest.sourceUrls) + @(
  "https://naciscdn.org/naturalearth/packages/natural_earth_vector.gpkg.zip",
  "https://github.com/onthegomap/planetiler",
  "https://github.com/nvkelso/natural-earth-vector"
) | Where-Object { $_ -and $_ -ne "https://www.openstreetmap.org/copyright" } | Select-Object -Unique
$manifest = [ordered]@{
  schemaVersion = 2
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  snapshot = "Natural Earth 110m/50m/10m multiscale vector"
  sourceUrls = @($sourceUrls)
  bytes = ($files | Measure-Object Length -Sum).Sum
  files = @($files | ForEach-Object {
    [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
  })
  attribution = "Made with Natural Earth"
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), $utf8NoBom)
Get-ChildItem -LiteralPath $outputRoot -File | Select-Object Name, Length, LastWriteTime
