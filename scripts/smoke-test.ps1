$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root "services\.env"
$httpPortLine = if (Test-Path -LiteralPath $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^TERRASYS_HTTP_PORT=' } | Select-Object -First 1
}
$httpPort = if ($httpPortLine) { $httpPortLine.Substring("TERRASYS_HTTP_PORT=".Length).Trim() } else { "8080" }
$webBase = "http://localhost:$httpPort"
$base = "$webBase/api"
$placeId = $null
$collectionId = $null
$trackIds = New-Object System.Collections.Generic.List[string]
$mediaIds = New-Object System.Collections.Generic.List[string]
$pngPath = Join-Path $root "runtime\smoke-test.png"
$archivePath = Join-Path $root "runtime\smoke-export.zip"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pngPath) | Out-Null

function Wait-MaintenanceJobs {
  param(
    [Parameter(Mandatory = $true)][string[]]$JobIds,
    [int]$TimeoutSeconds = 900
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $snapshot = Invoke-RestMethod -Uri "$base/maintenance"
    $jobs = @($snapshot.jobs | Where-Object { $JobIds -contains $_.id })
    $failed = @($jobs | Where-Object { $_.status -in @("failed", "cancelled") })
    if ($failed.Count) {
      throw "Maintenance verification failed: $($failed[0].resourceId) - $($failed[0].message)"
    }
    if ($jobs.Count -eq $JobIds.Count -and @($jobs | Where-Object { $_.status -ne "succeeded" }).Count -eq 0) {
      return
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "Maintenance verification jobs did not finish within $TimeoutSeconds seconds."
}

try {
  $packStatus = Invoke-RestMethod -Uri "$base/map-packs"
  $installedPacks = @($packStatus.packs | Where-Object { $_.installed -and $_.sizeMatches })
  $provincePacks = @($packStatus.packs | Where-Object { $_.kind -eq "province" })
  $worldPacks = @($packStatus.packs | Where-Object { $_.kind -ne "province" })
  $availablePacks = @($provincePacks | Where-Object { -not $_.installed })
  $independentPacks = @($provincePacks | Where-Object { $_.installed })
  if ($installedPacks.Count -lt 2) { throw "Two verified-size regional map packs are required." }
  if ($packStatus.provinceCount -ne 34 -or $provincePacks.Count -ne 34 -or
      ($availablePacks.Count + $independentPacks.Count) -ne 34) {
    throw "All 34 province-level resource units are required."
  }
  if ($packStatus.coveredProvinceCount -ne $independentPacks.Count) {
    throw "Province coverage does not match the currently installed independent packs."
  }
  if ($worldPacks.Count -lt 500 -or @($worldPacks | Where-Object { $_.sourceProvider -eq "Geofabrik" }).Count -lt 500 -or
      @($worldPacks | Where-Object { -not $_.buildReady }).Count -gt 0) {
    throw "The global Geofabrik map-pack catalog is incomplete."
  }
  foreach ($pack in $provincePacks) {
    if (@($pack.members).Count -ne 1 -or @($pack.estimatedInstallGiB).Count -ne 2 -or -not $pack.boundariesReady) {
      throw "Province resource $($pack.id) is missing its independent boundary or size metadata."
    }
  }
  $mainlandUnavailable = @($availablePacks | Where-Object { $_.id -ne "taiwan" -and -not $_.buildReady })
  if ($mainlandUnavailable.Count -gt 0) { throw "One or more mainland province resources cannot build from the common snapshot." }
  $taiwan = $availablePacks | Where-Object { $_.id -eq "taiwan" } | Select-Object -First 1
  if (-not $taiwan -or $taiwan.sourceMode -ne "direct" -or $taiwan.sourceProvider -ne "Geofabrik") {
    throw "Taiwan does not have an independent source profile."
  }
  $verificationJobIds = @(
    foreach ($pack in $installedPacks) {
      $job = Invoke-RestMethod -Method Post -Uri "$base/map-packs/$($pack.id)/verify"
      if (-not $job.id -or $job.action -ne "verify") { throw "Region pack $($pack.id) did not create a verification job." }
      $job.id
    }
  )
  Wait-MaintenanceJobs -JobIds $verificationJobIds

  try {
    $resources = Invoke-RestMethod -Uri "$base/resources?cached=true"
  }
  catch {
    $resources = Invoke-RestMethod -Uri "$base/resources" -TimeoutSec 600
  }
  if ($resources.storage.diskFreeBytes -le 0) { throw "Resource manager did not report free disk space." }
  if ($resources.storage.managedBytes -lt 1GB) { throw "Resource manager reported an implausibly small managed footprint." }
  if (@($resources.localGroups).Count -lt 3) { throw "Resource manager local categories are incomplete." }
  if (@($resources.localGroups | ForEach-Object { $_.items }).Count -lt 10) { throw "Resource manager did not inventory enough local resource types." }
  if ($resources.summary.mapPackCount -ne @($packStatus.packs).Count -or @($resources.updateChecks).Count -lt 8) {
    throw "Resource manager lifecycle checks are incomplete."
  }
  if ($resources.summary.enabledPacks -ne @($installedPacks | Where-Object { $_.enabled }).Count -or @($resources.caches).Count -ne 3) {
    throw "Map pack activation or regenerable cache accounting is incomplete."
  }
  foreach ($check in @($resources.updateChecks)) {
    foreach ($field in @("sourceUpdatedAt", "builtAt", "lastCheckedAt", "nextCheckAt")) {
      if ($check.PSObject.Properties.Name -notcontains $field) { throw "Resource update $($check.id) is missing $field." }
    }
  }
  $manifestSample = Invoke-RestMethod -Uri "$base/map-packs/$($installedPacks[0].id)/manifest"
  if ($manifestSample.management.disasterRecoveryBaseline -ne "full-snapshot") {
    throw "Map pack manifest export does not preserve the full-snapshot recovery baseline."
  }
  if (-not $manifestSample.details.file -or -not $manifestSample.details.sha256 -or $manifestSample.details.layer -ne "poi_detail") {
    throw "Map pack manifest does not describe its rich-detail companion."
  }
  $detailsRequest = [System.Net.HttpWebRequest]::Create("$webBase$($manifestSample.details.url)")
  $detailsRequest.Method = "HEAD"
  $detailsResponse = $detailsRequest.GetResponse()
  try {
    if ([int64]$detailsResponse.ContentLength -ne [int64]$manifestSample.details.bytes) {
      throw "Rich-detail PMTiles content length does not match its manifest."
    }
  }
  finally { $detailsResponse.Dispose() }
  $cacheInventory = Invoke-RestMethod -Uri "$base/caches"
  if (@($cacheInventory.items).Count -ne 3 -or @($cacheInventory.items | Where-Object { -not $_.regenerable }).Count) {
    throw "Cache maintenance allowlist is incomplete."
  }
  try {
    Invoke-RestMethod -Method Post -Uri "$base/maintenance/jobs" -ContentType "application/json" -Body (ConvertTo-Json @{ resourceId = $installedPacks[0].id; action = "remove" }) | Out-Null
    throw "Map pack removal was accepted without a protection token."
  }
  catch {
    if ($_.Exception.Message -eq "Map pack removal was accepted without a protection token.") { throw }
  }
  $sharedUpdate = @($resources.updateChecks | Where-Object { $_.id -eq "shared-capabilities" }) | Select-Object -First 1
  if (-not $sharedUpdate -or -not $sharedUpdate.heavy) {
    throw "Shared index updates are not marked as an explicit heavy operation."
  }
  $maintenance = Invoke-RestMethod -Uri "$base/maintenance"
  if (-not $maintenance.worker.online -or $maintenance.worker.status -ne "running") {
    throw "The local maintenance worker is not reporting a live heartbeat."
  }
  if (-not $maintenance.settings.resources.weather.enabled -or -not $maintenance.settings.resources.'world-region-catalog'.enabled) {
    throw "The default automatic-update resource policy is incomplete."
  }
  try {
    Invoke-RestMethod -Method Post -Uri "$base/maintenance/jobs" -ContentType "application/json" -Body '{"resourceId":"not-allowlisted","action":"update"}' | Out-Null
    throw "The maintenance API accepted a resource outside the allowlist."
  }
  catch {
    if ($_.Exception.Message -eq "The maintenance API accepted a resource outside the allowlist.") { throw }
  }
  $localResourceIds = @($resources.localGroups | ForEach-Object { $_.items } | ForEach-Object { $_.id })
  foreach ($required in @("overview-map", "weather", "travel-guide", "nautical", "tts")) {
    if ($localResourceIds -notcontains $required) { throw "Local resource inventory is missing $required." }
  }
  $weather = Invoke-RestMethod -Uri "$base/weather"
  $weatherManifest = Get-Content (Join-Path $root "products\weather\weather.manifest.json") -Raw | ConvertFrom-Json
  $enabledWeatherPackIds = @($installedPacks | Where-Object { $_.enabled } | ForEach-Object { $_.id } | Sort-Object)
  $weatherInputIds = @($weatherManifest.inputs | ForEach-Object { $_.id } | Sort-Object)
  if ($weatherManifest.schemaVersion -ne 2 -or @(Compare-Object $enabledWeatherPackIds $weatherInputIds).Count) {
    throw "Weather inputs do not match the enabled installed map packs."
  }
  if (@($weather.features).Count -ne [int]$weatherManifest.locations -or @($weather.features).Count -lt $enabledWeatherPackIds.Count) {
    throw "Weather snapshot feature coverage does not match its installed-region manifest."
  }
  $nautical = Invoke-RestMethod -Uri "$base/nautical" -TimeoutSec 30
  if (@($nautical.features).Count -lt 1000) { throw "Nautical reference layer is unexpectedly sparse." }
  $nauticalManifest = Get-Content (Join-Path $root "products\nautical\nautical.manifest.json") -Raw | ConvertFrom-Json
  $enabledNauticalPackIds = @($installedPacks | Where-Object { $_.enabled } | ForEach-Object { $_.id } | Sort-Object)
  $nauticalInputIds = @($nauticalManifest.inputs | ForEach-Object { $_.id } | Sort-Object)
  if ($nauticalManifest.schemaVersion -ne 2 -or @(Compare-Object $enabledNauticalPackIds $nauticalInputIds).Count) {
    throw "Nautical inputs do not match the enabled installed map packs."
  }
  if (@($nauticalManifest.inputs | Where-Object { $_.bytes -le 0 -or -not $_.sha256 }).Count) {
    throw "Nautical input provenance is incomplete."
  }
  $nauticalUpdate = @($resources.updateChecks | Where-Object { $_.id -eq "nautical" }) | Select-Object -First 1
  if (-not $nauticalUpdate -or $nauticalUpdate.updateAvailable -or $nauticalUpdate.statusKind -ne "current") {
    throw "Nautical resource remains incorrectly marked for update after a successful build."
  }
  foreach ($resourceId in @("weather", "osm-carto")) {
    $resourceUpdate = @($resources.updateChecks | Where-Object { $_.id -eq $resourceId }) | Select-Object -First 1
    if (-not $resourceUpdate -or $resourceUpdate.updateAvailable -or $resourceUpdate.statusKind -ne "current") {
      throw "$resourceId remains incorrectly marked for update after a successful build."
    }
  }
  $overviewResponse = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/assets/overview/gray-earth.jpg" -TimeoutSec 20
  if ($overviewResponse.StatusCode -ne 200 -or $overviewResponse.RawContentLength -lt 1MB) {
    throw "Global overview raster is unavailable."
  }
  $baselineStatus = Invoke-RestMethod -Uri "$base/status"
  $enabledInstalledPackIds = @($installedPacks | Where-Object { $_.enabled } | ForEach-Object { $_.id } | Sort-Object)
  $capabilityProvinceIds = @($resources.capabilityPackIds | Sort-Object)
  $missingCapabilityPackIds = @($enabledInstalledPackIds | Where-Object { $capabilityProvinceIds -notcontains $_ })
  if ($missingCapabilityPackIds.Count) {
    throw "Shared capability coverage is missing enabled map packs: $($missingCapabilityPackIds -join ', ')."
  }
  $osmCartoPackIds = @($resources.osmCartoPackIds | Sort-Object)
  $missingOsmCartoPackIds = @($enabledInstalledPackIds | Where-Object { $osmCartoPackIds -notcontains $_ })
  if ($missingOsmCartoPackIds.Count) {
    throw "OSM Carto coverage is missing enabled map packs: $($missingOsmCartoPackIds -join ', ')."
  }
  $nauticalPackIds = @($resources.nauticalPackIds | Sort-Object)
  $missingNauticalPackIds = @($enabledInstalledPackIds | Where-Object { $nauticalPackIds -notcontains $_ })
  if ($missingNauticalPackIds.Count) {
    throw "Nautical coverage is missing enabled map packs: $($missingNauticalPackIds -join ', ')."
  }
  $weatherPackIds = @($resources.weatherPackIds | Sort-Object)
  $missingWeatherPackIds = @($enabledInstalledPackIds | Where-Object { $weatherPackIds -notcontains $_ })
  if ($missingWeatherPackIds.Count) {
    throw "Weather coverage is missing enabled map packs: $($missingWeatherPackIds -join ', ')."
  }
  $terrainPackIds = @($resources.terrainPackIds | Sort-Object)
  foreach ($coverage in @(
    [pscustomobject]@{ name = "Shared capability"; ids = $capabilityProvinceIds },
    [pscustomobject]@{ name = "OSM Carto"; ids = $osmCartoPackIds },
    [pscustomobject]@{ name = "Nautical"; ids = $nauticalPackIds },
    [pscustomobject]@{ name = "Weather"; ids = $weatherPackIds },
    [pscustomobject]@{ name = "Terrain"; ids = $terrainPackIds }
  )) {
    if (@(Compare-Object $enabledInstalledPackIds @($coverage.ids)).Count) {
      throw "$($coverage.name) coverage does not exactly match enabled installed map packs."
    }
  }

  $capabilities = Invoke-RestMethod -Uri "$base/capabilities"
  if ($capabilities.source) {
    foreach ($service in @("geocoder", "routing", "elevation", "encyclopedia")) {
      if (-not $capabilities.services.$service.available) {
        throw "Prepared advanced capability '$service' is not ready."
      }
    }
    if ($capabilities.services.elevation.files -lt 1) { throw "No local elevation grids were found." }

    $geocode = Invoke-RestMethod -Uri "$base/geocode?q=%E5%8D%97%E4%BA%AC%E5%A4%A7%E5%AD%A6&limit=5"
    if (@($geocode.results).Count -lt 1 -or $geocode.results[0].kind -ne "geocoder") {
      throw "Offline address geocoder returned no normalized results."
    }
    $reverse = Invoke-RestMethod -Uri "$base/reverse?longitude=118.7969&latitude=32.0603"
    if ($reverse.kind -ne "geocoder") { throw "Offline reverse geocoder returned no normalized result." }

    $elevation = Invoke-RestMethod -Uri "$base/elevation?longitude=118.7969&latitude=32.0603"
    if ($null -eq $elevation.elevation_m) { throw "Local elevation lookup returned no height." }

    $terrainResponse = Invoke-WebRequest -UseBasicParsing -Uri "$base/terrain/9/425/209.png" -TimeoutSec 30
    if ($terrainResponse.StatusCode -ne 200 -or $terrainResponse.Headers["Content-Type"] -notlike "image/png*") {
      throw "Local terrain tile endpoint returned an invalid image."
    }

    $contourAsset = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/vendor/maplibre-contour/index.min.js" -TimeoutSec 20
    if ($contourAsset.StatusCode -ne 200 -or $contourAsset.Content -notmatch "DemSource") {
      throw "Local MapLibre contour worker asset is unavailable."
    }

    $emergency = Invoke-RestMethod -Uri "$base/emergency.geojson?categories=medical,security,shelter,supplies,fuel&west=118.5&south=31.8&east=119.1&north=32.4&limit=100"
    if (@($emergency.features).Count -lt 10) { throw "Offline emergency layer returned too few Nanjing facilities." }

    $wikiResponse = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8080/wiki/catalog/v2/entries?count=-1" -TimeoutSec 20
    if ($wikiResponse.StatusCode -ne 200 -or $wikiResponse.Content -notmatch '<name>wikipedia_zh_all</name>' -or
        $wikiResponse.Content -notmatch '<name>wikivoyage_zh_all</name>') {
      throw "Offline knowledge catalog is missing the Chinese Wikipedia or Wikivoyage archive."
    }
  }

  $collections = Invoke-RestMethod -Uri "$base/collections"
  if (@($collections).Count -lt 3) { throw "Default place collections are missing." }
  $collectionPayload = @{
    name = "TerraSys smoke collection"
    color = "#266f9d"
    note = "Temporary collection verification"
  } | ConvertTo-Json
  $collection = Invoke-RestMethod -Method Post -Uri "$base/collections" -ContentType "application/json" -Body $collectionPayload
  $collectionId = $collection.id

  $placePayload = @{
    name = "TerraSys smoke place"
    province = "江苏省"
    category = "reference"
    note = "Temporary API verification record"
    tags = @("smoke", "temporary")
    collection_ids = @($collectionId)
    rating = 4
    longitude = 118.7969
    latitude = 32.0603
  } | ConvertTo-Json
  $place = Invoke-RestMethod -Method Post -Uri "$base/places" -ContentType "application/json" -Body $placePayload
  $placeId = $place.id

  $updatePayload = $placePayload | ConvertFrom-Json
  $updatePayload.note = "Updated verification record"
  $updatePayload | Add-Member -NotePropertyName version -NotePropertyValue $place.version
  $updateJson = $updatePayload | ConvertTo-Json
  $updated = Invoke-RestMethod -Method Put -Uri "$base/places/$placeId" -ContentType "application/json" -Body $updateJson
  if ($updated.version -lt 2) { throw "Place version did not increment." }

  try {
    Invoke-RestMethod -Method Put -Uri "$base/places/$placeId" -ContentType "application/json" -Body $updateJson | Out-Null
    throw "Stale place update was accepted."
  }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { throw }
  }

  $search = Invoke-RestMethod -Uri "$base/places.geojson?q=smoke"
  if (@($search.features).Count -lt 1) { throw "Place search returned no results." }
  if (@($search.features[0].properties.collections | Where-Object { $_.id -eq $collectionId }).Count -ne 1) {
    throw "Place collection membership was not persisted."
  }

  $referenceSearch = Invoke-RestMethod -Uri "$base/search?q=%E5%8D%97%E4%BA%AC&limit=30"
  if (@($referenceSearch.results | Where-Object { $_.kind -eq "reference" }).Count -lt 1) {
    throw "Unified search returned no offline OSM reference results."
  }

  $nearbySearch = Invoke-RestMethod -Uri "$base/reference/nearby?longitude=118.7969&latitude=31.9688&radius_m=1500&limit=10"
  if (@($nearbySearch.results).Count -lt 1 -or $nearbySearch.results[0].details.distance_m -gt 1500) {
    throw "Nearby OSM reference lookup returned no valid distance-ranked results."
  }

  $trackPayload = @{
    name = "TerraSys smoke line"
    activity = "walk"
    note = "Temporary geometry verification"
    tags = @("smoke")
    color = "#267352"
    geometry = @{
      type = "LineString"
      coordinates = @(@(118.79, 32.06), @(118.80, 32.07), @(118.81, 32.08))
    }
  } | ConvertTo-Json -Depth 6
  $track = Invoke-RestMethod -Method Post -Uri "$base/tracks" -ContentType "application/json" -Body $trackPayload
  $trackIds.Add($track.id)
  $trackCollection = Invoke-RestMethod -Uri "$base/tracks.geojson?q=TerraSys%20smoke%20line"
  $trackFeature = @($trackCollection.features | Where-Object { $_.id -eq $track.id }) | Select-Object -First 1
  if (-not $trackFeature -or $trackFeature.properties.version -lt 1) {
    throw "New track could not be read with version metadata."
  }
  $trackUpdate = $trackPayload | ConvertFrom-Json
  $trackUpdate.name = "TerraSys smoke line updated"
  $trackUpdate | Add-Member -NotePropertyName version -NotePropertyValue $trackFeature.properties.version
  $trackUpdateJson = $trackUpdate | ConvertTo-Json -Depth 6
  $updatedTrack = Invoke-RestMethod -Method Put -Uri "$base/tracks/$($track.id)" -ContentType "application/json" -Body $trackUpdateJson
  if ($updatedTrack.version -le $trackFeature.properties.version) { throw "Track version did not increment." }
  try {
    Invoke-RestMethod -Method Put -Uri "$base/tracks/$($track.id)" -ContentType "application/json" -Body $trackUpdateJson | Out-Null
    throw "Stale track update was accepted."
  }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { throw }
  }

  if ($capabilities.source) {
    $routePayload = @{
      costing = "auto"
      locations = @(
        @{ longitude = 118.7969; latitude = 32.0603; name = "南京" },
        @{ longitude = 118.9080; latitude = 32.1040; name = "仙林" }
      )
    } | ConvertTo-Json -Depth 6
    $route = Invoke-RestMethod -Method Post -Uri "$base/route" -ContentType "application/json" -Body $routePayload -TimeoutSec 90
    if ($route.geometry.type -ne "LineString" -or @($route.geometry.coordinates).Count -lt 20 -or
        @($route.maneuvers).Count -lt 2 -or @($route.profile | Where-Object { $null -ne $_.elevation_m }).Count -lt 2) {
      throw "Offline route adapter returned incomplete geometry, maneuvers, or elevation."
    }
    $savedRoutePayload = @{
      name = "TerraSys smoke route"
      activity = "driving"
      note = "Temporary offline route verification"
      tags = @("smoke", "offline-route")
      color = "#2679a6"
      geometry = $route.geometry
    } | ConvertTo-Json -Depth 100
    $savedRoute = Invoke-RestMethod -Method Post -Uri "$base/tracks" -ContentType "application/json" -Body $savedRoutePayload
    $trackIds.Add($savedRoute.id)
  }

  $invalidTrack = $trackPayload | ConvertFrom-Json
  $invalidTrack.geometry.coordinates = @(@(999, 32.06), @(118.80, 32.07))
  try {
    Invoke-RestMethod -Method Post -Uri "$base/tracks" -ContentType "application/json" -Body ($invalidTrack | ConvertTo-Json -Depth 6) | Out-Null
    throw "Out-of-range track geometry was accepted."
  }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 422) { throw }
  }

  $sampleGpx = Join-Path $root "tests\fixtures\sample.gpx"
  $gpxJson = curl.exe -sS --fail -F "file=@$sampleGpx" "$base/imports/gpx"
  $gpx = $gpxJson | ConvertFrom-Json
  foreach ($id in $gpx.created) { $trackIds.Add($id) }

  $png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  [IO.File]::WriteAllBytes($pngPath, [Convert]::FromBase64String($png))
  $mediaJson = curl.exe -sS --fail -F "file=@$pngPath;type=image/png" "$base/media?place_id=$placeId"
  $media = $mediaJson | ConvertFrom-Json
  $mediaIds.Add($media.id)
  $duplicateMedia = (curl.exe -sS --fail -F "file=@$pngPath;type=image/png" "$base/media?place_id=$placeId") | ConvertFrom-Json
  $mediaIds.Add($duplicateMedia.id)
  if ($duplicateMedia.sha256 -ne $media.sha256) { throw "Duplicate media hashes do not match." }
  $mediaList = Invoke-RestMethod -Uri "$base/media?place_id=$placeId"
  if (@($mediaList).Count -ne 2) { throw "Shared media file was not linked twice." }
  $trackMedia = (curl.exe -sS --fail -F "file=@$pngPath;type=image/png" "$base/media?track_id=$($track.id)") | ConvertFrom-Json
  $mediaIds.Add($trackMedia.id)
  $trackMediaList = Invoke-RestMethod -Uri "$base/media?track_id=$($track.id)"
  if (@($trackMediaList).Count -ne 1) { throw "Track media was not linked." }

  $status = Invoke-RestMethod -Uri "$base/status"
  if ($status.places -lt ($baselineStatus.places + 1) -or
      $status.tracks -lt ($baselineStatus.tracks + 2) -or
      $status.media -lt ($baselineStatus.media + 1)) {
    throw "API status counts do not include smoke-test records."
  }
  if ($status.reference_places -lt 100000 -or -not $status.reference_dataset.source_updated_at) {
    throw "Offline reference-search readiness metadata is incomplete."
  }
  if (-not $status.latest_backup) { throw "Latest-backup readiness metadata is missing." }

  $export = Invoke-RestMethod -Uri "$base/export/geojson"
  if ($export.type -ne "FeatureCollection" -or
      @($export.features | Where-Object { $_.id -eq $placeId }).Count -ne 1 -or
      @($export.features | Where-Object { $_.id -eq $track.id }).Count -ne 1) {
    throw "GeoJSON export does not include the current personal place and track."
  }

  $trackGpx = Invoke-WebRequest -UseBasicParsing -Uri "$base/tracks/$($track.id).gpx"
  if ($trackGpx.StatusCode -ne 200 -or $trackGpx.Headers["Content-Type"] -notlike "application/gpx+xml*" -or
      $trackGpx.Content -notmatch '<trk>' -or $trackGpx.Content -notmatch '<trkpt ') {
    throw "Single-track GPX export is invalid."
  }
  $allGpx = Invoke-WebRequest -UseBasicParsing -Uri "$base/export/gpx"
  if ($allGpx.StatusCode -ne 200 -or $allGpx.Headers["Content-Disposition"] -notmatch 'TerraSys-tracks\.gpx' -or
      $allGpx.Content -notmatch 'TerraSys smoke line updated') {
    throw "Full GPX export does not include the updated smoke track."
  }
  $archiveResponse = Invoke-WebRequest -UseBasicParsing -Uri "$base/export/archive" -OutFile $archivePath -PassThru
  if ($archiveResponse.Headers["Content-Disposition"] -notmatch 'TerraSys-personal-\d{8}-\d{6}\.zip') {
    throw "Personal archive export does not use the TerraSys filename."
  }
  if (-not (Test-Path $archivePath) -or (Get-Item $archivePath).Length -lt 1KB) {
    throw "Personal archive export is missing or implausibly small."
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    $archiveEntries = @($archive.Entries.FullName)
    foreach ($requiredEntry in @("manifest.json", "personal.geojson", "tracks.gpx", "collections.json", "media.json")) {
      if ($archiveEntries -notcontains $requiredEntry) { throw "Personal archive is missing $requiredEntry." }
    }
    if (@($archiveEntries | Where-Object { $_ -like "media/*" }).Count -lt 1) {
      throw "Personal archive does not contain linked media files."
    }
  }
  finally {
    $archive.Dispose()
  }

  Invoke-RestMethod -Method Delete -Uri "$base/places/$placeId" | Out-Null
  $placeId = $null
  $placeMediaIds = @("$($media.id)", "$($duplicateMedia.id)")
  $allMedia = @(Invoke-RestMethod -Uri "$base/media")
  if (@($allMedia | Where-Object { $placeMediaIds -contains "$($_.id)" }).Count -ne 0) {
    throw "Deleting a place did not remove its linked media metadata."
  }
  Invoke-RestMethod -Method Delete -Uri "$base/tracks/$($track.id)" | Out-Null
  [void]$trackIds.Remove($track.id)
  $allMedia = @(Invoke-RestMethod -Uri "$base/media")
  if (@($allMedia | Where-Object { "$($_.id)" -eq "$($trackMedia.id)" }).Count -ne 0) {
    throw "Deleting a track did not remove its linked media metadata."
  }
  $orphanCleanup = Invoke-RestMethod -Method Delete -Uri "$base/media/orphans"
  if ($orphanCleanup.deleted -ne 0) { throw "Smoke test left unexpected orphan media records." }

  Write-Host "Global/China region packs, operational resources, CRUD/versioning, search, routing, GeoJSON/GPX/archive export, geometry, and owned-media lifecycle verification passed."
}
finally {
  foreach ($mediaId in $mediaIds) {
    try { Invoke-RestMethod -Method Delete -Uri "$base/media/$mediaId" | Out-Null } catch { }
  }
  foreach ($trackId in $trackIds) {
    try { Invoke-RestMethod -Method Delete -Uri "$base/tracks/$trackId" | Out-Null } catch { Write-Warning $_ }
  }
  if ($placeId) {
    try { Invoke-RestMethod -Method Delete -Uri "$base/places/$placeId" | Out-Null } catch { Write-Warning $_ }
  }
  if ($collectionId) {
    try { Invoke-RestMethod -Method Delete -Uri "$base/collections/$collectionId" | Out-Null } catch { Write-Warning $_ }
  }
  if (Test-Path $pngPath) { Remove-Item -LiteralPath $pngPath -Force }
  if (Test-Path $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
}
