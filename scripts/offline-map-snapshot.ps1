. (Join-Path $PSScriptRoot "map-version-utils.ps1")

function Copy-TerraSysOfflineMap {
  param([string]$Root, [string]$Destination, [object]$Dataset)
  $productRoot = Join-Path $Root "products/tiles/pmtiles"
  $productRelative = "products/tiles/pmtiles/$([IO.Path]::GetFileName([string]$Dataset.url))"
  $manifestRelative = "products/tiles/pmtiles/$([IO.Path]::GetFileName([string]$Dataset.manifestUrl))"
  $productPath = Join-Path $Root $productRelative
  $manifestPath = Join-Path $Root $manifestRelative
  if (-not (Test-Path -LiteralPath $productPath) -and -not (Test-Path -LiteralPath $manifestPath)) { return $null }
  $operationLock = Enter-TerraSysMapLock -ProductRoot $productRoot -PackId $Dataset.id
  try {
    $paths = Get-TerraSysMapPaths -ProductRoot $productRoot -PackId $Dataset.id
    if (Test-Path -LiteralPath $paths.Journal) { throw "Map activation needs recovery before backup: $($Dataset.id)" }
    $manifest = Assert-TerraSysMapVersion -ProductRoot $productRoot -ProductPath $productPath -ManifestPath $manifestPath
    $sourceRelative = ([string]$manifest.source.file).Replace('\', '/')
    $detailsRelative = ([string]$manifest.details.file).Replace('\', '/')
    foreach ($relative in @($productRelative, $manifestRelative, $detailsRelative, $sourceRelative)) {
      if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or
          @($relative.Split('/')) -contains '..' -or @($relative.Split('/')) -contains '.') {
        throw "Unsafe map snapshot path: $relative"
      }
      $target = Join-Path $Destination $relative
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
      Copy-Item -LiteralPath (Join-Path $Root $relative) -Destination $target -Force
    }
    $null = Assert-TerraSysMapVersion -ProductRoot (Join-Path $Destination "products/tiles/pmtiles") `
      -ProductPath (Join-Path $Destination $productRelative) -ManifestPath (Join-Path $Destination $manifestRelative)
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Destination $sourceRelative)).Hash.ToLowerInvariant()
    if ($sourceHash -ne ([string]$manifest.source.sha256).ToLowerInvariant()) {
      throw "The map source changed since its build; refusing an inconsistent offline snapshot: $($Dataset.id)"
    }
    return [pscustomobject][ordered]@{
      id = [string]$Dataset.id; product = $productRelative; details = $detailsRelative; source = $sourceRelative
    }
  }
  finally { $operationLock.Dispose() }
}
