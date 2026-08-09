param(
  [switch]$SkipEncyclopedia,
  [switch]$SkipTravelGuide,
  [switch]$SkipOverview,
  [switch]$SkipWeather,
  [switch]$SkipNautical,
  [switch]$SkipStart
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root "raw\osm\china\terrasys-core-latest.osm.pbf"
$routingDirectory = Join-Path $root "products\routing\valhalla"
$routingSource = Join-Path $routingDirectory "terrasys-core-latest.osm.pbf"

& (Join-Path $PSScriptRoot "build-capability-source.ps1")
New-Item -ItemType Directory -Force -Path $routingDirectory, (Join-Path $root "data\terrain-cache") | Out-Null
$copySource = -not (Test-Path -LiteralPath $routingSource -PathType Leaf)
if (-not $copySource) {
  $copySource = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne
    (Get-FileHash -Algorithm SHA256 -LiteralPath $routingSource).Hash
}
if ($copySource) {
  Write-Host "Copying the verified capability PBF into the Valhalla build directory..."
  Copy-Item -LiteralPath $source -Destination $routingSource -Force
}

if (-not $SkipEncyclopedia) {
  & (Join-Path $PSScriptRoot "download-encyclopedia.ps1")
}
if (-not $SkipTravelGuide) {
  & (Join-Path $PSScriptRoot "download-travel-guide.ps1")
}
if (-not $SkipOverview) {
  & (Join-Path $PSScriptRoot "sync-overview-resources.ps1")
}
if (-not $SkipWeather) {
  & (Join-Path $PSScriptRoot "sync-weather.ps1")
}
if (-not $SkipNautical) {
  & (Join-Path $PSScriptRoot "build-nautical.ps1")
}
if (-not $SkipStart) {
  & (Join-Path $PSScriptRoot "start-terrasys.ps1")
}
