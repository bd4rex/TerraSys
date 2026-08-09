param(
  [string]$PackId = "",
  [switch]$NoDownload
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
$elevationRoot = Join-Path $root "products\elevation"
$stagingRoot = Join-Path $root "tmp\elevation-downloads"
$manifestPath = Join-Path $elevationRoot "elevation.manifest.json"
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$validSizes = @((2 * 1201 * 1201), (2 * 3601 * 3601))

New-Item -ItemType Directory -Force -Path $elevationRoot, $stagingRoot | Out-Null

$disabledPackIds = @()
if (Test-Path -LiteralPath $packStatePath -PathType Leaf) {
  $packState = Get-Content -Raw -LiteralPath $packStatePath | ConvertFrom-Json
  $disabledPackIds = @($packState.disabledPackIds | ForEach-Object { [string]$_ })
}

function Get-HgtName([int]$Latitude, [int]$Longitude) {
  $latitudePrefix = if ($Latitude -ge 0) { "N" } else { "S" }
  $longitudePrefix = if ($Longitude -ge 0) { "E" } else { "W" }
  return "{0}{1:D2}{2}{3:D3}.hgt" -f $latitudePrefix, [math]::Abs($Latitude), $longitudePrefix, [math]::Abs($Longitude)
}

function Test-HgtFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  return $validSizes -contains (Get-Item -LiteralPath $Path).Length
}

function Expand-GzipFile([string]$Source, [string]$Destination) {
  $input = [IO.File]::OpenRead($Source)
  try {
    $gzip = New-Object IO.Compression.GZipStream($input, [IO.Compression.CompressionMode]::Decompress)
    try {
      $output = [IO.File]::Create($Destination)
      try { $gzip.CopyTo($output) }
      finally { $output.Dispose() }
    }
    finally { $gzip.Dispose() }
  }
  finally { $input.Dispose() }
}

$requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$regions = @()
foreach ($dataset in @($catalog.datasets)) {
  $id = [string]$dataset.id
  if ($PackId -and $id -ne $PackId) { continue }
  if ($disabledPackIds -contains $id) { continue }
  $product = Join-Path $root "products\tiles\pmtiles\$id.pmtiles"
  $manifest = Join-Path $root "products\tiles\pmtiles\$id.manifest.json"
  if (-not (Test-Path -LiteralPath $product -PathType Leaf) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
  $bounds = @($dataset.bounds | ForEach-Object { [double]$_ })
  if ($bounds.Count -ne 4) { throw "Installed region $id has no usable bounds." }
  $grids = @()
  for ($latitude = [math]::Floor($bounds[1]); $latitude -le [math]::Floor($bounds[3] - 0.000000001); $latitude++) {
    for ($longitude = [math]::Floor($bounds[0]); $longitude -le [math]::Floor($bounds[2] - 0.000000001); $longitude++) {
      $name = Get-HgtName $latitude $longitude
      [void]$requested.Add($name)
      $grids += $name
    }
  }
  $regions += [pscustomobject][ordered]@{ id = $id; name = [string]$dataset.name; bounds = $bounds; grids = $grids }
}
if ($regions.Count -lt 1) { throw "No enabled installed map regions were found for elevation synchronization." }

$completed = 0
$downloaded = 0
$unavailable = New-Object System.Collections.Generic.List[string]
$orderedNames = @($requested | Sort-Object)
foreach ($name in $orderedNames) {
  $latitudeDirectory = $name.Substring(0, 3)
  $targetDirectory = Join-Path $elevationRoot $latitudeDirectory
  $target = Join-Path $targetDirectory $name
  New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
  if (-not (Test-HgtFile $target)) {
    if ($NoDownload) {
      [void]$unavailable.Add($name)
    }
    else {
      $gzipPart = Join-Path $stagingRoot "$name.gz.part"
      $hgtPart = Join-Path $stagingRoot "$name.part"
      $url = "https://s3.amazonaws.com/elevation-tiles-prod/skadi/$latitudeDirectory/$name.gz"
      Write-Host "Downloading global elevation grid $name..."
      & curl.exe --fail --location --retry 5 --retry-delay 3 --silent --show-error --output $gzipPart $url
      if ($LASTEXITCODE -ne 0) {
        [void]$unavailable.Add($name)
        if (Test-Path -LiteralPath $gzipPart) { [IO.File]::Delete($gzipPart) }
      }
      else {
        if (Test-Path -LiteralPath $hgtPart) { [IO.File]::Delete($hgtPart) }
        Expand-GzipFile $gzipPart $hgtPart
        if (-not (Test-HgtFile $hgtPart)) { throw "Downloaded elevation grid has an invalid size: $name" }
        Move-Item -LiteralPath $hgtPart -Destination $target -Force
        [IO.File]::Delete($gzipPart)
        $downloaded++
      }
    }
  }
  $completed++
  Write-Host "ELEVATION_PROGRESS $completed/$($orderedNames.Count) $name"
}

$availableFiles = @(
  Get-ChildItem -LiteralPath $elevationRoot -Recurse -File -Filter '*.hgt' |
    Where-Object { Test-HgtFile $_.FullName } |
    Sort-Object Name
)
$availableNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $availableFiles) { [void]$availableNames.Add($file.Name) }
$regionResults = foreach ($region in $regions) {
  $availableCount = @($region.grids | Where-Object { $availableNames.Contains($_) }).Count
  [pscustomobject][ordered]@{
    id = $region.id
    name = $region.name
    bounds = $region.bounds
    requestedGridCount = $region.grids.Count
    availableGridCount = $availableCount
    complete = $availableCount -eq $region.grids.Count
  }
}
$manifest = [ordered]@{
  schemaVersion = 2
  generatedAt = [DateTimeOffset]::Now.ToString("o")
  policy = "global-source-installed-region-bounds-retained"
  source = [ordered]@{
    name = "AWS Open Data Terrain Tiles / Mapzen Skadi"
    urlTemplate = "https://s3.amazonaws.com/elevation-tiles-prod/skadi/{lat}/{tile}.hgt.gz"
    registry = "https://registry.opendata.aws/terrain-tiles/"
  }
  regions = @($regionResults)
  requestedGridCount = $orderedNames.Count
  availableRequestedGridCount = @($orderedNames | Where-Object { $availableNames.Contains($_) }).Count
  retainedGridCount = $availableFiles.Count
  retainedBytes = [int64](($availableFiles | Measure-Object -Property Length -Sum).Sum)
  downloadedGridCount = $downloaded
  unavailable = @($unavailable)
  files = @($availableFiles | ForEach-Object { $_.Name })
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)

if ($unavailable.Count) {
  Write-Warning "$($unavailable.Count) requested grids were unavailable (normally open water); available land grids remain usable."
}
Write-Host "Elevation synchronization complete: $($availableFiles.Count) retained grids, $downloaded downloaded in this run."
Get-Item -LiteralPath $manifestPath | Select-Object FullName, Length, LastWriteTime
