param([switch]$Force)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
$disabledPackIds = @()
if (Test-Path -LiteralPath $packStatePath -PathType Leaf) {
  $packState = Get-Content -Raw -LiteralPath $packStatePath | ConvertFrom-Json
  $disabledPackIds = @($packState.disabledPackIds | ForEach-Object { [string]$_ })
}
$image = "terrasys-osmium:1"
$outputRoot = Join-Path $root "raw\osm\carto"
$output = Join-Path $outputRoot "installed-regions.osm.pbf"
$staged = Join-Path $outputRoot "installed-regions.staged.osm.pbf"
$merged = Join-Path $outputRoot "installed-regions.merged.osm.pbf"
$manifestPath = Join-Path $outputRoot "installed-regions.manifest.json"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }
if (-not (docker image ls -q $image)) {
  docker build -t $image (Join-Path $root "services\tools\osmium")
  Assert-NativeSuccess "Building the Osmium image"
}

$inputs = @()
foreach ($dataset in @($catalog.datasets)) {
  $id = [string]$dataset.id
  if ($disabledPackIds -contains $id) { continue }
  $productPath = Join-Path $root "products\tiles\pmtiles\$id.pmtiles"
  $packManifestPath = Join-Path $root "products\tiles\pmtiles\$id.manifest.json"
  $productExists = Test-Path -LiteralPath $productPath -PathType Leaf
  $manifestExists = Test-Path -LiteralPath $packManifestPath -PathType Leaf
  if (-not $productExists -and -not $manifestExists) { continue }
  if ($productExists -ne $manifestExists) {
    throw "Regional pack $id is partially installed; both PMTiles and manifest are required."
  }

  $packManifest = Get-Content -Raw -LiteralPath $packManifestPath | ConvertFrom-Json
  $sourceRelative = ([string]$packManifest.source.file).Replace('/', '\')
  $sourcePath = Join-Path $root $sourceRelative
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Regional source is missing for ${id}: $sourcePath"
  }
  $sourceInfo = Get-Item -LiteralPath $sourcePath
  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
  if ($sourceHash -ne ([string]$packManifest.source.sha256).ToLowerInvariant()) {
    throw "Regional source hash does not match the $id map manifest."
  }
  $inputs += [pscustomobject][ordered]@{
    id = $id
    file = $sourceRelative.Replace('\', '/')
    bytes = $sourceInfo.Length
    sha256 = $sourceHash
    sourceSequence = [string]$packManifest.source.sequenceNumber
    sourceUpdatedAt = [string]$packManifest.source.updatedAt
  }
}
if ($inputs.Count -lt 1) { throw "No enabled installed map packs are available for OSM Carto." }

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$inputSignature = ($inputs | ForEach-Object { "$($_.id):$($_.sha256)" }) -join ':'
$current = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
} else { $null }
if (-not $Force -and $current -and $current.inputSignature -eq $inputSignature -and
    $current.deduplication -eq "time-filter-latest" -and
    (Test-Path -LiteralPath $output -PathType Leaf)) {
  Write-Host "OSM Carto source already matches $($inputs.Count) enabled installed map packs."
  Get-Item -LiteralPath $output, $manifestPath | Select-Object FullName, Length, LastWriteTime
  exit 0
}

Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $merged -Force -ErrorAction SilentlyContinue
$containerInputs = @($inputs | ForEach-Object { "/data/$($_.file)" })
$snapshotTime = [DateTime]::UtcNow.AddYears(10).ToString("yyyy-MM-ddTHH:mm:ssZ")
try {
  Write-Host "Merging $($inputs.Count) enabled installed regions for OSM Carto..."
  docker run --rm -v "${root}:/data" $image merge @containerInputs `
    -o /data/raw/osm/carto/installed-regions.merged.osm.pbf --overwrite
  Assert-NativeSuccess "Merging the OSM Carto source"

  Write-Host "Deduplicating overlapping regional boundaries..."
  docker run --rm -v "${root}:/data" $image time-filter -F pbf `
    /data/raw/osm/carto/installed-regions.merged.osm.pbf $snapshotTime `
    -o /data/raw/osm/carto/installed-regions.staged.osm.pbf --overwrite
  Assert-NativeSuccess "Deduplicating the OSM Carto source"
  docker run --rm -v "${root}:/data" $image fileinfo -e /data/raw/osm/carto/installed-regions.staged.osm.pbf | Out-Host
  Assert-NativeSuccess "Validating the merged OSM Carto source"
  Move-Item -LiteralPath $staged -Destination $output -Force
}
finally {
  Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $merged -Force -ErrorAction SilentlyContinue
}

$outputInfo = Get-Item -LiteralPath $output
$manifest = [ordered]@{
  schemaVersion = 2
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  scope = @($inputs.id)
  inputSignature = $inputSignature
  deduplication = "time-filter-latest"
  inputs = $inputs
  product = [ordered]@{
    file = "raw/osm/carto/installed-regions.osm.pbf"
    bytes = $outputInfo.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()
  }
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)
Get-Item -LiteralPath $output, $manifestPath | Select-Object FullName, Length, LastWriteTime
