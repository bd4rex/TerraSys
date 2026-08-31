[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $root "raw\planetiler-sources"
$manifestPath = Join-Path $sourceRoot "manifest.json"
$sources = @(
  [ordered]@{
    Name = "lake_centerline.shp.zip"
    Url = "https://github.com/acalcutt/osm-lakelines/releases/download/v12/lake_centerline.shp.zip"
    ExpectedBytes = [int64]80906805
    ExpectedSha256 = "6c900507c88fc9f5b5a386f90fd0a42d0495e8755a03d075538fb9a6801a3192"
  },
  [ordered]@{
    Name = "water-polygons-split-3857.zip"
    Url = "https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip"
    ExpectedBytes = [int64]0
    ExpectedSha256 = ""
  },
  [ordered]@{
    Name = "natural_earth_vector.sqlite.zip"
    Url = "https://naciscdn.org/naturalearth/packages/natural_earth_vector.sqlite.zip"
    ExpectedBytes = [int64]0
    ExpectedSha256 = ""
  }
)

function Get-ValidatedArchiveMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Source
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Planetiler supporting source is missing: $Path"
  }
  $info = Get-Item -LiteralPath $Path
  if ($info.Length -lt 64KB) {
    throw "Planetiler supporting source is unexpectedly small: $Path"
  }
  if ([int64]$Source.ExpectedBytes -gt 0 -and $info.Length -ne [int64]$Source.ExpectedBytes) {
    throw "Planetiler supporting source size mismatch for $($Source.Name): expected $($Source.ExpectedBytes), got $($info.Length)."
  }

  $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ([string]$Source.ExpectedSha256 -and $actualSha256 -ne [string]$Source.ExpectedSha256) {
    throw "Planetiler supporting source SHA256 mismatch for $($Source.Name)."
  }

  $archive = [IO.Compression.ZipFile]::OpenRead($Path)
  try {
    if ($archive.Entries.Count -eq 0) {
      throw "Planetiler supporting source archive is empty: $Path"
    }
  }
  finally {
    $archive.Dispose()
  }

  return [ordered]@{
    file = "raw/planetiler-sources/$($Source.Name)"
    sourceUrl = [string]$Source.Url
    bytes = $info.Length
    sha256 = $actualSha256
    pinnedSha256 = if ([string]$Source.ExpectedSha256) { [string]$Source.ExpectedSha256 } else { $null }
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
    Write-Host "Reusing verified Planetiler source: $($source.Name)"
    Get-ValidatedArchiveMetadata -Path $target -Source $source
    continue
  }

  $staged = "$target.part"
  $stagedComplete = $false
  if (Test-Path -LiteralPath $staged -PathType Leaf) {
    try {
      [void](Get-ValidatedArchiveMetadata -Path $staged -Source $source)
      $stagedComplete = $true
      Write-Host "Activating the complete staged Planetiler source: $($source.Name)"
    }
    catch {
      Write-Host "Resuming the staged Planetiler source: $($source.Name)"
    }
  }

  if (-not $stagedComplete) {
    Write-Host "Downloading Planetiler source directly from its public upstream: $($source.Url)"
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

  [void](Get-ValidatedArchiveMetadata -Path $staged -Source $source)
  Move-Item -LiteralPath $staged -Destination $target
  Get-ValidatedArchiveMetadata -Path $target -Source $source
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
Get-Item -LiteralPath $resultPaths |
  Select-Object FullName, Length, LastWriteTime
