param(
  [Parameter(Mandatory = $true)]
  [string]$PackId,
  [int64]$MissingWayNodes = 0,
  [int64]$MissingRelationMembers = 0,
  [int64]$MaxMissingReferences = 0
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$pack = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
if (-not $pack) { throw "Unknown region pack: $PackId" }

$source = Join-Path $root ([string]$pack.sourceFile).Replace('/', '\')
$stateFile = if ($pack.sourceProfile.stateFile) {
  Join-Path $root ([string]$pack.sourceProfile.stateFile).Replace('/', '\')
} else { $null }
$product = Join-Path $root "products\tiles\pmtiles\$PackId.pmtiles"
$manifestPath = Join-Path $root "products\tiles\pmtiles\$PackId.manifest.json"
$supportingSourceManifestPath = Join-Path $root "raw\planetiler-sources\manifest.json"
if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $product)) {
  throw "The $PackId source PBF and PMTiles product are required."
}

$state = @{}
if ($stateFile -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
  Get-Content -LiteralPath $stateFile | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { $state[$matches[1]] = $matches[2].Replace('\:', ':') }
  }
}
$sourceInfo = Get-Item -LiteralPath $source
$productInfo = Get-Item -LiteralPath $product
$supportingSources = if (Test-Path -LiteralPath $supportingSourceManifestPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $supportingSourceManifestPath | ConvertFrom-Json
} else { $null }
$manifest = [ordered]@{
  schemaVersion = 2
  id = [string]$pack.id
  name = [string]$pack.name
  kind = [string]$pack.kind
  sourceProfileId = [string]$pack.sourceProfileId
  generatedAt = $productInfo.LastWriteTimeUtc.ToString("o")
  members = @($pack.members | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
  source = [ordered]@{
    file = ([string]$pack.sourceFile).Replace('\', '/')
    bytes = $sourceInfo.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
    sequenceNumber = $state.sequenceNumber
    updatedAt = $state.timestamp
    provider = [string]$pack.sourceProfile.provider
    referenceIntegrity = [ordered]@{
      missingWayNodes = $MissingWayNodes
      missingRelationMembers = $MissingRelationMembers
      missingTotal = $MissingWayNodes + $MissingRelationMembers
      maximumMissingReferences = $MaxMissingReferences
    }
  }
  supportingSources = $supportingSources
  product = [ordered]@{
    file = "products/tiles/pmtiles/$PackId.pmtiles"
    bytes = $productInfo.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $product).Hash.ToLowerInvariant()
    minZoom = 0
    maxZoom = 16
    bounds = @($pack.bounds | ForEach-Object { [double]$_ })
  }
  attribution = @("OpenStreetMap contributors", "OpenMapTiles")
}

[IO.File]::WriteAllText(
  $manifestPath,
  ($manifest | ConvertTo-Json -Depth 7),
  (New-Object Text.UTF8Encoding($false))
)
Write-Host "Region manifest written: $manifestPath"
