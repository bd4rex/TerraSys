[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $root "raw\osm\carto\external"
$manifestPath = Join-Path $sourceRoot "manifest.json"
$sources = @(
  [ordered]@{
    Name = "simplified-water-polygons-split-3857.zip"
    Url = "https://osmdata.openstreetmap.de/download/simplified-water-polygons-split-3857.zip"
    RequiredEntry = "simplified-water-polygons-split-3857/simplified_water_polygons.shp"
    ReusePath = ""
  },
  [ordered]@{
    Name = "water-polygons-split-3857.zip"
    Url = "https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip"
    RequiredEntry = "water-polygons-split-3857/water_polygons.shp"
    ReusePath = "raw/planetiler-sources/water-polygons-split-3857.zip"
  },
  [ordered]@{
    Name = "antarctica-icesheet-polygons-3857.zip"
    Url = "https://osmdata.openstreetmap.de/download/antarctica-icesheet-polygons-3857.zip"
    RequiredEntry = "antarctica-icesheet-polygons-3857/icesheet_polygons.shp"
    ReusePath = ""
  },
  [ordered]@{
    Name = "antarctica-icesheet-outlines-3857.zip"
    Url = "https://osmdata.openstreetmap.de/download/antarctica-icesheet-outlines-3857.zip"
    RequiredEntry = "antarctica-icesheet-outlines-3857/icesheet_outlines.shp"
    ReusePath = ""
  },
  [ordered]@{
    Name = "ne_110m_admin_0_boundary_lines_land.zip"
    Url = "https://naciscdn.org/naturalearth/110m/cultural/ne_110m_admin_0_boundary_lines_land.zip"
    RequiredEntry = "ne_110m_admin_0_boundary_lines_land.shp"
    ReusePath = ""
  }
)

function Get-ValidatedArchiveMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Source,
    [string]$ReusedFrom = ""
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "OSM Carto supporting source is missing: $Path"
  }
  $info = Get-Item -LiteralPath $Path
  if ($info.Length -lt 32KB) {
    throw "OSM Carto supporting source is unexpectedly small: $Path"
  }

  $archive = [IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $requiredEntry = [string]$Source.RequiredEntry
    $hasRequiredEntry = @($archive.Entries | Where-Object {
      $_.FullName.Replace('\', '/').EndsWith($requiredEntry, [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    if (-not $hasRequiredEntry) {
      throw "OSM Carto supporting archive does not contain $requiredEntry`: $Path"
    }
  }
  finally {
    $archive.Dispose()
  }

  return [ordered]@{
    file = "raw/osm/carto/external/$($Source.Name)"
    sourceUrl = [string]$Source.Url
    reusedFrom = if ($ReusedFrom) { $ReusedFrom } else { $null }
    bytes = $info.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  throw "curl.exe was not found on PATH."
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null

$files = foreach ($source in $sources) {
  $target = Join-Path $sourceRoot $source.Name
  if (Test-Path -LiteralPath $target -PathType Leaf) {
    Write-Host "Reusing verified OSM Carto source: $($source.Name)"
    Get-ValidatedArchiveMetadata -Path $target -Source $source
    continue
  }

  $staged = "$target.part"
  $reusedFrom = ""
  if ([string]$source.ReusePath) {
    $reuseCandidate = Join-Path $root ([string]$source.ReusePath).Replace('/', '\')
    if (Test-Path -LiteralPath $reuseCandidate -PathType Leaf) {
      [void](Get-ValidatedArchiveMetadata -Path $reuseCandidate -Source $source)
      Write-Host "Reusing the verified shared download for $($source.Name)."
      Copy-Item -LiteralPath $reuseCandidate -Destination $staged -Force
      $reusedFrom = ([string]$source.ReusePath).Replace('\', '/')
    }
  }

  if (-not $reusedFrom) {
    Write-Host "Downloading OSM Carto source directly from its public upstream: $($source.Url)"
    curl.exe --fail --location --continue-at - --connect-timeout 20 --retry 8 --retry-delay 5 --retry-all-errors `
      --speed-limit 1024 --speed-time 120 --output $staged $source.Url
    $downloadExitCode = $LASTEXITCODE
    if ($downloadExitCode -eq 33 -and (Test-Path -LiteralPath $staged -PathType Leaf)) {
      Write-Warning "The upstream rejected the saved byte range; restarting this staging download once."
      Remove-Item -LiteralPath $staged -Force
      curl.exe --fail --location --connect-timeout 20 --retry 8 --retry-delay 5 --retry-all-errors `
        --speed-limit 1024 --speed-time 120 --output $staged $source.Url
      $downloadExitCode = $LASTEXITCODE
    }
    if ($downloadExitCode -ne 0) {
      throw "Downloading $($source.Name) failed with exit code $downloadExitCode."
    }
  }

  [void](Get-ValidatedArchiveMetadata -Path $staged -Source $source -ReusedFrom $reusedFrom)
  Move-Item -LiteralPath $staged -Destination $target -Force
  Get-ValidatedArchiveMetadata -Path $target -Source $source -ReusedFrom $reusedFrom
}

$payload = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  managedBy = "TerraSys resumable public-source downloader"
  files = @($files)
}
[IO.File]::WriteAllText(
  $manifestPath,
  ($payload | ConvertTo-Json -Depth 5),
  (New-Object Text.UTF8Encoding($false))
)

$resultPaths = @($manifestPath) + @($sources | ForEach-Object { Join-Path $sourceRoot $_.Name })
Get-Item -LiteralPath $resultPaths | Select-Object FullName, Length, LastWriteTime
