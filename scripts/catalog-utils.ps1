function Resolve-TerraSysCatalogTemplate {
  param([string]$Template, [string]$Id)
  return $Template.Replace("{id}", $Id)
}

function Get-TerraSysExpandedCatalog {
  param([Parameter(Mandatory = $true)][string]$Root)

  $mapCatalogPath = Join-Path $Root "web\config\map-catalog.json"
  $regionCatalogPath = Join-Path $Root "web\config\region-catalog.json"
  $worldCatalogPath = Join-Path $Root "web\config\world-region-catalog.json"
  $mapCatalog = Get-Content -Raw -LiteralPath $mapCatalogPath | ConvertFrom-Json
  $regionCatalog = Get-Content -Raw -LiteralPath $regionCatalogPath | ConvertFrom-Json
  $worldCatalog = Get-Content -Raw -LiteralPath $worldCatalogPath | ConvertFrom-Json
  $profiles = @{}
  foreach ($property in $regionCatalog.sourceProfiles.PSObject.Properties) {
    $profiles[$property.Name] = $property.Value
  }
  $groups = @{}
  foreach ($group in @($regionCatalog.groups)) { $groups[[string]$group.id] = $group }

  $datasets = New-Object System.Collections.Generic.List[object]
  if (@($mapCatalog.datasets).Count -ne 0) { throw "Combination datasets are not supported in map-catalog.json." }

  foreach ($unit in @($regionCatalog.datasets)) {
    $id = [string]$unit.id
    $profile = $profiles[[string]$unit.sourceProfileId]
    if (-not $profile) { throw "Region $id references an unknown source profile." }
    $group = $groups[[string]$unit.groupId]
    if (-not $group) { throw "Region $id references an unknown group." }
    $sourceFile = if ($profile.sourceFile) {
      [string]$profile.sourceFile
    }
    else {
      Resolve-TerraSysCatalogTemplate ([string]$regionCatalog.defaults.sourceFileTemplate) $id
    }
    $polygonUrl = if ($profile.polygonUrl) {
      [string]$profile.polygonUrl
    }
    else {
      Resolve-TerraSysCatalogTemplate ([string]$regionCatalog.defaults.polygonUrlTemplate) $id
    }
    [void]$datasets.Add([pscustomobject][ordered]@{
      id = $id
      kind = "province"
      deprecated = $false
      countryId = [string]$regionCatalog.countryId
      name = [string]$unit.name
      shortName = [string]$unit.shortName
      abbreviation = [string]$unit.abbreviation
      administrativeType = [string]$unit.administrativeType
      groupId = [string]$unit.groupId
      groupName = [string]$group.name
      groupOrder = [int]$group.order
      order = [int]$unit.order
      description = "$($group.name) · 省级独立离线资源"
      url = Resolve-TerraSysCatalogTemplate ([string]$regionCatalog.defaults.urlTemplate) $id
      manifestUrl = Resolve-TerraSysCatalogTemplate ([string]$regionCatalog.defaults.manifestUrlTemplate) $id
      sourceFile = $sourceFile
      sourceProfileId = [string]$unit.sourceProfileId
      sourceProfile = $profile
      sourceSizeMiB = [double]$unit.sourceSizeMiB
      estimatedInstallGiB = @($unit.estimatedInstallGiB)
      estimatedTemporaryGiB = [double]$unit.estimatedTemporaryGiB
      estimatedBuildMinutes = @($unit.estimatedBuildMinutes)
      members = @([pscustomobject][ordered]@{ id = $id; name = [string]$unit.shortName; polygonUrl = $polygonUrl })
      bounds = @($unit.bounds)
      views = @([pscustomobject][ordered]@{ id = "all"; label = [string]$unit.shortName; bounds = @(@([double]$unit.bounds[0], [double]$unit.bounds[1]), @([double]$unit.bounds[2], [double]$unit.bounds[3])) })
    })
  }

  foreach ($worldPack in @($worldCatalog.datasets)) {
    if (-not $worldPack.id -or -not $worldPack.sourceProfile.snapshotUrl) {
      throw "World region catalog contains an invalid map pack."
    }
    [void]$datasets.Add($worldPack)
  }

  return [pscustomobject][ordered]@{
    schemaVersion = 3
    version = "$($mapCatalog.version)+$($regionCatalog.version)+$($worldCatalog.version)"
    activeDataset = [string]$mapCatalog.activeDataset
    datasets = $datasets.ToArray()
    limits = $mapCatalog.limits
    regionCatalog = $regionCatalog
  }
}
