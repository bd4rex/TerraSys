param(
  [Parameter(Mandatory = $true)]
  [string]$PackId,
  [string]$MaintenanceJobId = "",
  [string]$ManifestPath = "",
  [switch]$DeferCleanup
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
. (Join-Path $PSScriptRoot "map-version-utils.ps1")
. (Join-Path $PSScriptRoot "offline-kit-support.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$pack = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
if (-not $pack) { throw "Unknown region pack: $PackId" }

$planetilerImage = Get-TerraSysToolImage -Root $root -Name planetiler
$sourceRelative = ([string]$pack.sourceFile).Replace('/', '\')
$source = Join-Path $root $sourceRelative
$schema = Join-Path $root "config\planetiler\poi-details.yml"
$outputRoot = Join-Path $root "products\tiles\pmtiles"
if (-not $ManifestPath) { $ManifestPath = Join-Path $outputRoot "$PackId.manifest.json" }
$staged = Join-Path $outputRoot "$PackId.details.staged.pmtiles"
$dockerJobArguments = if ($MaintenanceJobId) { @("--label", "terrasys.maintenance-job=$MaintenanceJobId") } else { @() }

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Assert-Pmtiles([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -lt 16KB) {
    throw "$PackId rich-detail PMTiles is missing or unexpectedly small."
  }
  $stream = [IO.File]::OpenRead($Path)
  try {
    $header = New-Object byte[] 7
    [void]$stream.Read($header, 0, 7)
  }
  finally { $stream.Dispose() }
  if ([Text.Encoding]::ASCII.GetString($header) -ne "PMTiles") {
    throw "$PackId rich-detail PMTiles header is invalid."
  }
}

foreach ($required in @($source, $schema, $manifestPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required detail-build input is missing: $required" }
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
if (([string]$manifest.source.sha256).ToLowerInvariant() -ne $sourceHash) {
  throw "$PackId source no longer matches its basemap manifest; rebuild the basemap before details."
}
$schemaHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $schema).Hash.ToLowerInvariant()
$fileName = "$PackId.details.$($sourceHash.Substring(0, 12)).$($schemaHash.Substring(0, 8)).pmtiles"
$final = Join-Path $outputRoot $fileName
$createdFinal = $false
$manifestUpdated = $false

try {
  if (-not (Test-Path -LiteralPath $final -PathType Leaf)) {
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    $bounds = (@($pack.bounds) -join ',')
    Write-Host "DETAIL_STAGE 1/3 BUILD $PackId"
    docker run --rm @dockerJobArguments `
      --memory 4g --memory-swap 5g --cpus 3 `
      -e JAVA_TOOL_OPTIONS="-Xmx3g" `
      -v "${root}:/data" `
      $planetilerImage generate-custom `
      --schema=/data/config/planetiler/poi-details.yml `
      --osm_local_path="/data/$($sourceRelative.Replace('\', '/'))" `
      --output="/data/products/tiles/pmtiles/$PackId.details.staged.pmtiles" `
      --tmpdir="/data/tmp/planetiler-details-$PackId" `
      --bounds=$bounds `
      --download=false `
      --osm_lazy_reads=false `
      --force=true
    Assert-NativeSuccess "Building $PackId rich-detail PMTiles"
    Assert-Pmtiles $staged
    Move-Item -LiteralPath $staged -Destination $final -Force
    $createdFinal = $true
  }

  Write-Host "DETAIL_STAGE 2/3 VERIFY $PackId"
  Assert-Pmtiles $final
  $detailInfo = Get-Item -LiteralPath $final
  $detailHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $final).Hash.ToLowerInvariant()
  $manifest.schemaVersion = 3
  $details = [pscustomobject][ordered]@{
    file = "products/tiles/pmtiles/$fileName"
    url = "/tiles/$fileName"
    bytes = $detailInfo.Length
    sha256 = $detailHash
    schemaVersion = 1
    schemaSha256 = $schemaHash
    layer = "poi_detail"
    minZoom = 12
    maxZoom = 16
    generatedAt = $detailInfo.LastWriteTimeUtc.ToString("o")
    attributes = @(
      "name", "category", "subclass", "brand", "operator", "opening_hours", "phone", "website",
      "cuisine", "wheelchair", "toilets_wheelchair", "fee", "access", "ref", "ele", "description",
      "wikipedia", "wikidata", "address"
    )
  }
  $manifest | Add-Member -NotePropertyName details -NotePropertyValue $details -Force
  $temporaryManifest = "$manifestPath.staged"
  [IO.File]::WriteAllText(
    $temporaryManifest,
    ($manifest | ConvertTo-Json -Depth 9),
    (New-Object Text.UTF8Encoding($false))
  )
  Move-Item -LiteralPath $temporaryManifest -Destination $manifestPath -Force
  $manifestUpdated = $true

  Write-Host "DETAIL_STAGE 3/3 CLEAN $PackId"
  if (-not $DeferCleanup) { Remove-TerraSysUnusedMapDetails -ProductRoot $outputRoot -PackId $PackId }

  Get-Item -LiteralPath $final, $manifestPath | Select-Object FullName, Length, LastWriteTime
}
catch {
  Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
  if ($createdFinal -and -not $manifestUpdated) {
    Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
  }
  throw
}
finally {
  Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
}
