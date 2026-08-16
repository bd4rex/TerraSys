param(
  [Parameter(Mandatory = $true)]
  [string]$RoutingRoot
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
$elevationRoot = Join-Path $RoutingRoot "elevation_data"
$manifestPath = Join-Path $RoutingRoot "elevation-coverage.manifest.json"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $elevationRoot -PathType Container)) {
  throw "Valhalla elevation directory is missing: $elevationRoot"
}
$pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
$resolvedRouting = [IO.Path]::GetFullPath($RoutingRoot).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedRouting.StartsWith($resolvedRoot, $pathComparison)) {
  throw "RoutingRoot must remain inside the TerraSys project: $RoutingRoot"
}

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

$allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$regions = @()
foreach ($dataset in @($catalog.datasets)) {
  $id = [string]$dataset.id
  if ($disabledPackIds -contains $id) { continue }
  $product = Join-Path $root "products\tiles\pmtiles\$id.pmtiles"
  $manifest = Join-Path $root "products\tiles\pmtiles\$id.manifest.json"
  if (-not (Test-Path -LiteralPath $product -PathType Leaf) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
  $bounds = @($dataset.bounds | ForEach-Object { [double]$_ })
  if ($bounds.Count -ne 4) { throw "Installed region $id has no usable bounds." }
  $minLongitude = [math]::Floor($bounds[0])
  $maxLongitude = [math]::Floor($bounds[2] - 0.000000001)
  $minLatitude = [math]::Floor($bounds[1])
  $maxLatitude = [math]::Floor($bounds[3] - 0.000000001)
  for ($latitude = $minLatitude; $latitude -le $maxLatitude; $latitude++) {
    for ($longitude = $minLongitude; $longitude -le $maxLongitude; $longitude++) {
      [void]$allowed.Add((Get-HgtName $latitude $longitude))
    }
  }
  $centerLatitude = [math]::Floor(($bounds[1] + $bounds[3]) / 2)
  $centerLongitude = [math]::Floor(($bounds[0] + $bounds[2]) / 2)
  $centerName = Get-HgtName $centerLatitude $centerLongitude
  $centerPath = Get-ChildItem -LiteralPath $elevationRoot -Recurse -File -Filter $centerName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $centerPath) { throw "Valhalla elevation is missing the center grid for ${id}: $centerName" }
  $regions += [pscustomobject][ordered]@{ id = $id; centerGrid = $centerName }
}
if ($regions.Count -lt 1) { throw "No enabled installed map regions were found for elevation pruning." }

$allFiles = @(Get-ChildItem -LiteralPath $elevationRoot -Recurse -File -Filter '*.hgt')
$obsolete = @($allFiles | Where-Object { -not $allowed.Contains($_.Name) })
$removedBytes = [int64](($obsolete | Measure-Object -Property Length -Sum).Sum)
foreach ($file in $obsolete) { [IO.File]::Delete($file.FullName) }
Get-ChildItem -LiteralPath $elevationRoot -Directory -Recurse |
  Sort-Object FullName -Descending |
  Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
  Remove-Item -Force

$retained = @(Get-ChildItem -LiteralPath $elevationRoot -Recurse -File -Filter '*.hgt' | Sort-Object Name)
$manifest = [ordered]@{
  schemaVersion = 1
  generatedAt = [DateTimeOffset]::Now.ToString("o")
  policy = "enabled-installed-region-bounds"
  regions = $regions
  requestedGridCount = $allowed.Count
  retainedGridCount = $retained.Count
  retainedBytes = [int64](($retained | Measure-Object -Property Length -Sum).Sum)
  removedGridCount = $obsolete.Count
  removedBytes = $removedBytes
  files = @($retained | ForEach-Object { $_.Name })
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Host "Retained $($retained.Count) regional HGT grids and removed $($obsolete.Count) unrelated grids ($removedBytes bytes)."
Get-Item -LiteralPath $manifestPath | Select-Object FullName, Length, LastWriteTime
