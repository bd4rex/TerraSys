param(
  [string]$MaintenanceJobId = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$directory = Join-Path $root "products\nautical"
$cacheDirectory = Join-Path $directory "source-cache"
$filtered = Join-Path $directory "seamarks.staged.osm.pbf"
$staged = Join-Path $directory "seamarks.staged.geojson"
$target = Join-Path $directory "seamarks.geojson"
$legacyFiltered = Join-Path $directory "seamarks.osm.pbf"
$image = "terrasys-osmium:1"
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$dockerJobArguments = if ($MaintenanceJobId) { @("--label", "terrasys.maintenance-job=$MaintenanceJobId") } else { @() }

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Get-SafeId([string]$Value) {
  return ($Value -replace '[^A-Za-z0-9._-]', '-')
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }
if (-not (docker image ls -q $image)) {
  docker build -t $image (Join-Path $root "services\tools\osmium")
  Assert-NativeSuccess "Building the Osmium image"
}

$disabledPackIds = @()
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
if (Test-Path -LiteralPath $packStatePath -PathType Leaf) {
  $packState = Get-Content -Raw -LiteralPath $packStatePath | ConvertFrom-Json
  $disabledPackIds = @($packState.disabledPackIds | ForEach-Object { [string]$_ })
}

$inputs = @()
foreach ($dataset in @($catalog.datasets)) {
  $packId = [string]$dataset.id
  if ($disabledPackIds -contains $packId) { continue }
  $productPath = Join-Path $root "products\tiles\pmtiles\$packId.pmtiles"
  $packManifestPath = Join-Path $root "products\tiles\pmtiles\$packId.manifest.json"
  $productExists = Test-Path -LiteralPath $productPath -PathType Leaf
  $manifestExists = Test-Path -LiteralPath $packManifestPath -PathType Leaf
  if (-not $productExists -and -not $manifestExists) { continue }
  if ($productExists -ne $manifestExists) { throw "Regional pack $packId is partially installed." }

  $packManifest = Get-Content -Raw -LiteralPath $packManifestPath | ConvertFrom-Json
  $sourceRelative = [string]$packManifest.source.file
  $sourcePath = Join-Path $root ($sourceRelative.Replace('/', '\'))
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Regional source is missing for ${packId}: $sourcePath" }
  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
  if ($sourceHash -ne ([string]$packManifest.source.sha256).ToLowerInvariant()) {
    throw "Regional source hash does not match the $packId manifest."
  }
  $inputs += [pscustomobject][ordered]@{
    id = $packId
    relativePath = $sourceRelative.Replace('\', '/')
    bytes = (Get-Item -LiteralPath $sourcePath).Length
    sha256 = $sourceHash
    sourceSequence = [string]$packManifest.source.sequenceNumber
    sourceUpdatedAt = [string]$packManifest.source.updatedAt
  }
}

if ($inputs.Count -lt 1) { throw "No enabled installed map packages are available for the nautical resource." }
New-Item -ItemType Directory -Force -Path $directory, $cacheDirectory | Out-Null
Remove-Item -LiteralPath $filtered, $staged -Force -ErrorAction SilentlyContinue

$cacheFiles = @()
try {
  $inputIndex = 0
  foreach ($input in $inputs) {
    $inputIndex += 1
    $safeId = Get-SafeId ([string]$input.id)
    $cacheName = "$safeId-$(([string]$input.sha256).Substring(0, 16)).osm.pbf"
    $cachePath = Join-Path $cacheDirectory $cacheName
    $cacheRelative = "products/nautical/source-cache/$cacheName"
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
      $temporaryName = "$safeId-$(([string]$input.sha256).Substring(0, 16)).staged.osm.pbf"
      $temporaryPath = Join-Path $cacheDirectory $temporaryName
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
      Write-Host "NAUTICAL_STAGE 1/4 FILTER $inputIndex/$($inputs.Count) $($input.id)"
      & docker run --rm @dockerJobArguments -v "${root}:/data" $image tags-filter "/data/$($input.relativePath)" `
        nwr/seamark:type nwr/harbour nwr/man_made=lighthouse nwr/man_made=beacon nwr/man_made=breakwater nwr/leisure=marina `
        -o "/data/products/nautical/source-cache/$temporaryName" --overwrite
      Assert-NativeSuccess "Extracting nautical features from $($input.id)"
      Move-Item -LiteralPath $temporaryPath -Destination $cachePath -Force
    }
    else {
      Write-Host "NAUTICAL_STAGE 1/4 CACHE $inputIndex/$($inputs.Count) $($input.id)"
    }
    $cacheFiles += [pscustomobject]@{ Id = $input.id; Path = $cachePath; RelativePath = $cacheRelative; SafeId = $safeId; Name = $cacheName }
  }

  Write-Host "NAUTICAL_STAGE 2/4 MERGE $($cacheFiles.Count)"
  if ($cacheFiles.Count -eq 1) {
    Copy-Item -LiteralPath $cacheFiles[0].Path -Destination $filtered -Force
  }
  else {
    $containerInputs = @($cacheFiles | ForEach-Object { "/data/$($_.RelativePath)" })
    & docker run --rm @dockerJobArguments -v "${root}:/data" $image merge @containerInputs `
      -o /data/products/nautical/seamarks.staged.osm.pbf --overwrite
    Assert-NativeSuccess "Merging nautical feature extracts"
  }

  Write-Host "NAUTICAL_STAGE 3/4 EXPORT"
  & docker run --rm @dockerJobArguments -v "${root}:/data" $image export /data/products/nautical/seamarks.staged.osm.pbf `
    -f geojson -o /data/products/nautical/seamarks.staged.geojson --overwrite
  Assert-NativeSuccess "Exporting OSM nautical GeoJSON"

  Write-Host "NAUTICAL_STAGE 4/4 VERIFY"
  $payload = Get-Content -Raw -LiteralPath $staged | ConvertFrom-Json
  $featureCount = @($payload.features).Count
  if ($featureCount -lt 1) { throw "No nautical features were extracted from the installed map packages." }
  Move-Item -LiteralPath $staged -Destination $target -Force
  $manifest = [ordered]@{
    schemaVersion = 2
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    inputs = $inputs
    features = $featureCount
    bytes = (Get-Item -LiteralPath $target).Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    attribution = "OpenStreetMap contributors"
    warning = "Reference only; not for navigation safety decisions"
  }
  [IO.File]::WriteAllText((Join-Path $directory "nautical.manifest.json"), ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)
  Remove-Item -LiteralPath $legacyFiltered -Force -ErrorAction SilentlyContinue

  foreach ($cacheFile in $cacheFiles) {
    Get-ChildItem -LiteralPath $cacheDirectory -Filter "$($cacheFile.SafeId)-*.osm.pbf" -File |
      Where-Object { $_.Name -ne $cacheFile.Name } |
      Remove-Item -Force
  }
}
finally {
  Remove-Item -LiteralPath $filtered, $staged -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $cacheDirectory -Filter "*.staged.osm.pbf" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Get-Item -LiteralPath $target, (Join-Path $directory "nautical.manifest.json") | Select-Object FullName, Length, LastWriteTime
