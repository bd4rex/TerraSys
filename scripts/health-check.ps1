$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$checks = [ordered]@{}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
  throw "Docker Desktop is not running. Run D:\TerraSys\start-terrasys.cmd first."
}

$containers = docker compose -f (Join-Path $root "services\docker-compose.yml") ps --format json | ConvertFrom-Json
$checks.Containers = @($containers).Count

$web = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/healthz"
$checks.Web = $web.StatusCode

$api = Invoke-RestMethod -Uri "http://localhost:8080/api/health"
$checks.Api = $api.status
$checks.PostGIS = $api.postgis

$catalog = Invoke-RestMethod -Uri "http://localhost:8080/martin/catalog"
$checks.MartinSources = @($catalog.tiles.PSObject.Properties).Count

$packStatus = Invoke-RestMethod -Uri "http://localhost:8080/api/map-packs"
$allPacks = @($packStatus.packs)
if ($allPacks.Count -lt 500) { throw "Global map catalog is incomplete." }
$installedPacks = @($packStatus.packs | Where-Object { $_.installed -and $_.sizeMatches })
foreach ($pack in $installedPacks) {
  $headers = curl.exe -sS -I -H "Range: bytes=0-1023" "http://localhost:8080$($pack.url)"
  if (($headers -join "`n") -notmatch "206 Partial Content") {
    throw "PMTiles range request failed for region pack $($pack.id)."
  }
}
$checks.PMTilesRange = "206"
$checks.RegionPacks = $installedPacks.Count
$checks.GlobalCatalogPacks = $allPacks.Count

try {
  $resources = Invoke-RestMethod -Uri "http://localhost:8080/api/resources?cached=true" -TimeoutSec 10
}
catch {
  # A first start may not have produced the persistent inventory yet.
  $resources = Invoke-RestMethod -Uri "http://localhost:8080/api/resources" -TimeoutSec 90
}
if ($resources.summary.mapPackCount -ne $allPacks.Count -or @($resources.updateChecks).Count -lt 8) {
  throw "Resource inventory lifecycle checks are incomplete."
}
$checks.ResourceUpdateChecks = @($resources.updateChecks).Count

$weather = Invoke-RestMethod -Uri "http://localhost:8080/api/weather" -TimeoutSec 20
if (@($weather.features).Count -lt 1) { throw "Weather snapshot has no locations." }
$checks.WeatherLocations = @($weather.features).Count

$nautical = Invoke-RestMethod -Uri "http://localhost:8080/api/nautical" -TimeoutSec 30
if (@($nautical.features).Count -lt 1) { throw "Nautical reference has no features." }
$checks.NauticalFeatures = @($nautical.features).Count

$overview = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/assets/overview/gray-earth.jpg" -TimeoutSec 20
if ($overview.StatusCode -ne 200 -or $overview.RawContentLength -lt 1MB) { throw "Global overview raster is unavailable." }
$checks.WorldOverview = $overview.StatusCode
$overviewVectorRequest = [System.Net.HttpWebRequest]::Create("http://localhost:8080/assets/overview/world-overview.pmtiles")
$overviewVectorRequest.AddRange(0, 16383)
$overviewVectorRequest.Timeout = 20000
$overviewVectorResponse = $overviewVectorRequest.GetResponse()
try {
  $overviewVectorStatus = [int]$overviewVectorResponse.StatusCode
  if ($overviewVectorStatus -notin @(200, 206) -or $overviewVectorResponse.ContentLength -lt 127) { throw "Global vector overview is unavailable." }
  $checks.WorldOverviewVector = $overviewVectorStatus
} finally {
  $overviewVectorResponse.Close()
}

$capabilities = Invoke-RestMethod -Uri "http://localhost:8080/api/capabilities" -TimeoutSec 20
$checks.Geocoder = if (-not $capabilities.services.geocoder.available) { "not-ready" } elseif (-not $capabilities.services.geocoder.coverageComplete) { "ready-existing-scope" } elseif ($capabilities.services.geocoder.verified) { "ready" } else { "online-unverified" }
$checks.Routing = if (-not $capabilities.services.routing.available) { "not-ready" } elseif (-not $capabilities.services.routing.coverageComplete) { "ready-existing-scope" } elseif ($capabilities.services.routing.verified) { "ready" } else { "online-unverified" }
$checks.ElevationGrids = [int]$capabilities.services.elevation.files
$checks.Encyclopedia = if ($capabilities.services.encyclopedia.available) { "ready" } else { "not-ready" }
if ($capabilities.source) {
  foreach ($service in @("geocoder", "routing", "elevation", "encyclopedia")) {
    if (-not $capabilities.services.$service.available) {
      throw "Prepared advanced capability '$service' is not ready."
    }
  }
  $wiki = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/wiki/catalog/v2/entries?count=-1" -TimeoutSec 20
  if ($wiki.Content -notmatch '<name>wikipedia_zh_all</name>' -or $wiki.Content -notmatch '<name>wikivoyage_zh_all</name>') {
    throw "Kiwix is missing the encyclopedia or travel-guide archive."
  }
  $checks.TravelGuide = "ready"
}

$latestBackup = Get-ChildItem (Join-Path $root "backups") -Directory -ErrorAction SilentlyContinue |
  Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName "manifest.json") -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $_.FullName "terrasys.dump") -PathType Leaf)
  } |
  Sort-Object Name -Descending | Select-Object -First 1
$checks.LatestBackup = if ($latestBackup) { $latestBackup.Name } else { "none" }

$checks | Format-Table -AutoSize
