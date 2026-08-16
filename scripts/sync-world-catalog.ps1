param(
  [string]$IndexUrl = "https://download.geofabrik.de/index-v1.json"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$target = Join-Path $root "web\config\world-region-catalog.json"
$indexPart = Join-Path $root "tmp\geofabrik-index-v1.json.part"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

$rootMap = @{
  "africa" = "africa"
  "antarctica" = "antarctica"
  "asia" = "asia"
  "australia-oceania" = "oceania"
  "europe" = "europe"
  "north-america" = "north-america"
  "south-america" = "south-america"
}
$continentNames = @{
  "africa" = "非洲"
  "antarctica" = "南极洲"
  "asia" = "亚洲"
  "australia-oceania" = "大洋洲"
  "europe" = "欧洲"
  "north-america" = "北美洲"
  "south-america" = "南美洲"
  "central-america" = "中美洲"
  "russia" = "俄罗斯联邦"
}

function Get-GeometryBounds {
  param([Parameter(Mandatory = $true)]$Geometry)

  $bounds = [double[]]@([double]::PositiveInfinity, [double]::PositiveInfinity, [double]::NegativeInfinity, [double]::NegativeInfinity)
  function Visit-Coordinates {
    param($Node)
    $items = @($Node)
    if ($items.Count -ge 2 -and $items[0] -is [ValueType] -and $items[1] -is [ValueType]) {
      $longitude = [double]$items[0]
      $latitude = [double]$items[1]
      if ($longitude -lt $bounds[0]) { $bounds[0] = $longitude }
      if ($latitude -lt $bounds[1]) { $bounds[1] = $latitude }
      if ($longitude -gt $bounds[2]) { $bounds[2] = $longitude }
      if ($latitude -gt $bounds[3]) { $bounds[3] = $latitude }
      return
    }
    foreach ($item in $items) { Visit-Coordinates $item }
  }
  Visit-Coordinates $Geometry.coordinates
  if ($bounds | Where-Object { [double]::IsInfinity($_) }) { return @(-180.0, -85.0, 180.0, 85.0) }
  return @($bounds | ForEach-Object { [math]::Round($_, 6) })
}

function Get-TopRootId {
  param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$FeaturesById)
  $current = $Id
  while ($FeaturesById[$current].properties.parent) {
    $current = [string]$FeaturesById[$current].properties.parent
  }
  return $current
}

function Get-CleanDisplayName {
  param([string]$Value)
  $decoded = [Net.WebUtility]::HtmlDecode([string]$Value)
  $decoded = $decoded -replace '(?i)<br\s*/?>', ' / '
  $decoded = $decoded -replace '<[^>]+>', ''
  return ($decoded -replace '\s+', ' ').Trim()
}

Write-Host "Refreshing the local Geofabrik catalog snapshot..."
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $indexPart) | Out-Null
try {
  curl.exe --fail --location --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 3 --retry-all-errors `
    --user-agent "TerraSys/1.0 offline-map-catalog" --output $indexPart $IndexUrl
  if ($LASTEXITCODE -ne 0) { throw "Downloading the Geofabrik catalog failed with exit code $LASTEXITCODE." }
  $indexBytes = [IO.File]::ReadAllBytes($indexPart)
}
catch {
  if (Test-Path -LiteralPath $target -PathType Leaf) {
    $existing = Get-Content -Raw -LiteralPath $target | ConvertFrom-Json
    if ([int]$existing.schemaVersion -eq 1 -and @($existing.datasets).Count -ge 500) {
      Write-Warning "Geofabrik is unavailable; preserving the checked-in catalog snapshot at version $($existing.version)."
      return
    }
  }
  throw
}
finally {
  if (Test-Path -LiteralPath $indexPart -PathType Leaf) { Remove-Item -LiteralPath $indexPart -Force }
}
$index = [Text.Encoding]::UTF8.GetString($indexBytes) | ConvertFrom-Json
$features = @($index.features | Where-Object { $_.properties.id -and $_.properties.urls.pbf })
$featuresById = @{}
foreach ($feature in $features) {
  $id = [string]$feature.properties.id
  if ($featuresById.ContainsKey($id)) { throw "Geofabrik catalog contains duplicate id: $id" }
  if ($id -notmatch '^[a-z0-9][a-z0-9/-]*$' -or $id.Contains("..")) { throw "Geofabrik catalog contains an unsafe id: $id" }
  $featuresById[$id] = $feature
}

$datasets = New-Object System.Collections.Generic.List[object]
$regions = New-Object System.Collections.Generic.List[object]
$childrenByParent = @{}
$patches = @{}
foreach ($regionId in $rootMap.Values) {
  $patches[$regionId] = [ordered]@{ status = "available"; children = @(); datasetIds = @() }
}

foreach ($feature in $features) {
  $properties = $feature.properties
  $id = [string]$properties.id
  if ($id -eq "china") { continue }
  $safeId = $id.Replace('/', '--')
  $packId = "gf-$safeId"
  $rootId = Get-TopRootId -Id $id -FeaturesById $featuresById
  $continentId = if ($rootMap.ContainsKey($rootId)) { $rootMap[$rootId] } elseif ($rootId -eq "russia") { "europe" } elseif ($rootId -eq "central-america") { "north-america" } else { "world" }
  $bounds = Get-GeometryBounds -Geometry $feature.geometry
  $pbfUrl = [string]$properties.urls.pbf
  $updatesUrl = [string]$properties.urls.updates
  $isoCodes = @($properties.'iso3166-1:alpha2')
  $displayName = if ($continentNames.ContainsKey($id)) { $continentNames[$id] } else { Get-CleanDisplayName ([string]$properties.name) }
  $snapshotFile = "raw/osm/world/$safeId-latest.osm.pbf"
  $stateFile = "raw/osm/world/$safeId.state.txt"
  $dataset = [ordered]@{
    id = $packId
    kind = if ($isoCodes.Count) { "country" } else { "region" }
    countryId = if ($isoCodes.Count) { [string]$isoCodes[0] } else { $null }
    name = $displayName
    shortName = $displayName
    groupId = $continentId
    groupName = $continentNames[$rootId]
    description = "Geofabrik 独立 OSM 离线区域"
    url = "/tiles/$packId.pmtiles"
    manifestUrl = "/tiles/$packId.manifest.json"
    sourceFile = $snapshotFile
    sourceProfileId = "geofabrik-$safeId"
    sourceProfile = [ordered]@{
      mode = "direct"
      provider = "Geofabrik"
      snapshotFile = $snapshotFile
      snapshotUrl = $pbfUrl
      checksumUrl = "$pbfUrl.md5"
      stateFile = $stateFile
      stateUrl = if ($updatesUrl) { "$updatesUrl/state.txt" } else { $null }
    }
    estimatedInstallGiB = @()
    estimatedBuildMinutes = @()
    members = @()
    bounds = $bounds
    views = @([ordered]@{ id = "all"; label = $displayName; bounds = @(@($bounds[0], $bounds[1]), @($bounds[2], $bounds[3])) })
  }
  [void]$datasets.Add([pscustomobject]$dataset)

  if ($rootMap.ContainsKey($id)) {
    $patches[$rootMap[$id]].datasetIds = @($packId)
    continue
  }

  $parentId = [string]$properties.parent
  if (-not $parentId) {
    $parentRegionId = $continentId
  }
  elseif ($rootMap.ContainsKey($parentId)) {
    $parentRegionId = $rootMap[$parentId]
  }
  else {
    $parentRegionId = "gf:$parentId"
  }
  $regionId = "gf:$id"
  $region = [ordered]@{
    id = $regionId
    name = $displayName
    sourceName = [string]$properties.name
    isoCode = if ($isoCodes.Count) { [string]$isoCodes[0] } else { $null }
    level = if ($isoCodes.Count) { "country" } else { "region" }
    icon = "map"
    parent = $parentRegionId
    status = "available"
    datasetIds = @($packId)
    children = @()
  }
  [void]$regions.Add([pscustomobject]$region)
  if (-not $childrenByParent.ContainsKey($parentRegionId)) { $childrenByParent[$parentRegionId] = New-Object System.Collections.Generic.List[string] }
  [void]$childrenByParent[$parentRegionId].Add($regionId)
}

foreach ($region in $regions) {
  if ($childrenByParent.ContainsKey([string]$region.id)) {
    $region.children = @($childrenByParent[[string]$region.id] | Sort-Object)
  }
}
foreach ($regionId in @($patches.Keys)) {
  $children = @($childrenByParent[$regionId] | Sort-Object)
  if ($regionId -eq "asia") { $children = @("china") + $children }
  $patches[$regionId].children = $children
}

$payload = [ordered]@{
  schemaVersion = 1
  version = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  source = [ordered]@{
    provider = "Geofabrik"
    indexUrl = $IndexUrl
    attribution = "OpenStreetMap contributors"
  }
  regionPatches = $patches
  regions = @($regions | Sort-Object parent, name)
  datasets = @($datasets | Sort-Object groupId, name)
}
$payload = Merge-TerraSysWorldSourceOverrides -WorldCatalog $payload -Root $root
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
[IO.File]::WriteAllText($target, ($payload | ConvertTo-Json -Depth 12 -Compress), $utf8NoBom)
Write-Host "World catalog written: $target"
Write-Host "$($payload.regions.Count) browse regions and $($payload.datasets.Count) buildable map packs are available."
