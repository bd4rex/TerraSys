param(
  [string]$KitDirectory = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $KitDirectory) {
  $KitDirectory = Get-ChildItem -LiteralPath (Join-Path $root "offline-kit") -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $KitDirectory) { throw "No offline kit was found. Run create-offline-kit.cmd first." }

$kit = (Resolve-Path -LiteralPath $KitDirectory).Path.TrimEnd('\')
$payload = Join-Path $kit "payload\TerraSys"
$kitInfo = Get-Content -Raw -LiteralPath (Join-Path $kit "kit-info.json") | ConvertFrom-Json
$backup = Get-ChildItem -LiteralPath (Join-Path $payload "backups") -Directory |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw "The offline kit contains no backup." }

& (Join-Path $PSScriptRoot "verify-offline-kit.ps1") -KitDirectory $kit | Out-Host
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running." }

$id = [guid]::NewGuid().ToString("N").Substring(0, 8)
$network = "terrasys-recovery-$id"
$volume = "terrasys_recovery_$id"
$nominatimVolume = "terrasys_recovery_nominatim_$id"
$postgres = "terrasys-recovery-postgis-$id"
$api = "terrasys-recovery-api-$id"
$martin = "terrasys-recovery-martin-$id"
$web = "terrasys-recovery-web-$id"
$nominatim = "terrasys-recovery-nominatim-$id"
$valhalla = "terrasys-recovery-valhalla-$id"
$kiwix = "terrasys-recovery-kiwix-$id"
$auditRoot = Join-Path $root "runtime\recovery-audit"
$work = Join-Path $auditRoot "work-$id"
$media = Join-Path $work "media"
$exports = Join-Path $work "exports"
$terrain = Join-Path $work "terrain-cache"
$maintenance = Join-Path $work "maintenance"
New-Item -ItemType Directory -Force -Path $media, $exports, $terrain, $maintenance | Out-Null

if (Test-Path -LiteralPath (Join-Path $backup.FullName "media")) {
  Get-ChildItem -LiteralPath (Join-Path $backup.FullName "media") -Force |
    Copy-Item -Destination $media -Recurse -Force
}

$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$password = [Convert]::ToBase64String($bytes).Replace("+", "_").Replace("/", "-").TrimEnd("=")
$databaseUrl = "postgres://gis:$password@postgis:5432/terrasys"
$report = [ordered]@{
  schemaVersion = 3
  startedAt = (Get-Date).ToUniversalTime().ToString("o")
  kit = $kit
  kitId = $kitInfo.id
  backup = $backup.Name
  isolatedNetwork = $network
  networkInternal = $false
  success = $false
  counts = $null
  checks = [ordered]@{}
  error = $null
}
$caught = $null

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Get-ApiJson([string]$Container, [string]$Url, [string]$Operation) {
  $code = "import json,urllib.request; print(json.dumps(json.load(urllib.request.urlopen('$Url', timeout=45))))"
  $raw = docker exec $Container python -c $code
  Assert-NativeSuccess $Operation
  return (($raw -join "`n") | ConvertFrom-Json)
}

function Post-ApiJson([string]$Container, [string]$Url, [string]$Json, [string]$Operation) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json))
  $code = "import base64,json,urllib.request; d=base64.b64decode('$encoded'); r=urllib.request.Request('$Url',data=d,headers={'Content-Type':'application/json'}); print(json.dumps(json.load(urllib.request.urlopen(r,timeout=90))))"
  $raw = docker exec $Container python -c $code
  Assert-NativeSuccess $Operation
  return (($raw -join "`n") | ConvertFrom-Json)
}

try {
  docker network create --internal $network | Out-Null
  Assert-NativeSuccess "Creating the isolated recovery network"
  docker volume create $volume | Out-Null
  Assert-NativeSuccess "Creating the temporary database volume"
  if ($kitInfo.advancedCapabilities) {
    docker volume create $nominatimVolume | Out-Null
    Assert-NativeSuccess "Creating the temporary Nominatim volume"
  }
  $report.networkInternal = ((docker network inspect $network --format '{{.Internal}}') -join "").Trim() -eq "true"
  if (-not $report.networkInternal) { throw "Recovery network is not internal." }

  docker run -d --name $postgres --network $network --network-alias postgis `
    -e "POSTGRES_DB=postgres" -e "POSTGRES_USER=gis" -e "POSTGRES_PASSWORD=$password" `
    -v "${volume}:/var/lib/postgresql/data" `
    postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 | Out-Null
  Assert-NativeSuccess "Starting isolated PostGIS"
  $databaseReady = $false
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    # The entrypoint's temporary server is Unix-socket-only; TCP proves init completed.
    $probeErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    docker exec $postgres pg_isready -h 127.0.0.1 -U gis -d postgres *> $null
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $probeErrorAction
    if ($probeExitCode -eq 0) { $databaseReady = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $databaseReady) { throw "Isolated PostGIS did not become ready." }
  docker exec $postgres createdb -U gis -O gis -T template_postgis terrasys
  Assert-NativeSuccess "Creating the isolated recovery database"

  $dump = Join-Path $backup.FullName "terrasys.dump"
  docker cp $dump "${postgres}:/tmp/terrasys.dump"
  Assert-NativeSuccess "Copying the recovery dump"
  docker exec $postgres pg_restore -U gis -d terrasys --clean --if-exists --no-owner /tmp/terrasys.dump | Out-Host
  Assert-NativeSuccess "Restoring the recovery dump"
  docker exec $postgres rm -f /tmp/terrasys.dump
  Assert-NativeSuccess "Removing the temporary recovery dump"

  $countSql = "SELECT (SELECT count(*) FROM app.places),(SELECT count(*) FROM app.tracks),(SELECT count(*) FROM app.media),(SELECT count(*) FROM app.reference_places),(SELECT count(*) FROM app.collections),(SELECT count(*) FROM public.app_schema_migrations);"
  $countText = ((docker exec $postgres psql -U gis -d terrasys -At -F '|' -c $countSql) -join "").Trim()
  Assert-NativeSuccess "Counting restored records"
  $values = $countText.Split('|')
  if ($values.Count -ne 6) { throw "Restored count query returned an unexpected result: $countText" }
  $report.counts = [ordered]@{
    places = [int64]$values[0]
    tracks = [int64]$values[1]
    media = [int64]$values[2]
    referencePlaces = [int64]$values[3]
    collections = [int64]$values[4]
    migrations = [int64]$values[5]
  }
  if ($report.counts.collections -lt 3 -or $report.counts.referencePlaces -lt 1) {
    throw "Restored database is missing collections or reference search data."
  }

  $advancedReady = $false
  if ($kitInfo.advancedCapabilities) {
    if (-not $kitInfo.nominatimIndexIncluded) { throw "Advanced recovery kit has no Nominatim index snapshot." }
    $nominatimArchive = Join-Path $kit ([string]$kitInfo.nominatimIndexArchive).Replace('/', '\')
    $dockerRoot = Join-Path $kit "docker"
    docker run --rm -v "${nominatimVolume}:/target" -v "${dockerRoot}:/backup:ro" `
      postgis/postgis@sha256:1d95a92144c40198b46908fd92ac365e85d35eaf31bfc36f06c2c09a090c0538 `
      tar -C /target -xzf "/backup/$([IO.Path]::GetFileName($nominatimArchive))"
    Assert-NativeSuccess "Restoring the isolated Nominatim volume"

    $coreRoot = Join-Path $payload "raw\osm\china"
    docker run -d --name $nominatim --network $network --network-alias nominatim `
      -e "PBF_PATH=/data/terrasys-core-latest.osm.pbf" -e "UPDATE_MODE=none" -e "FREEZE=true" `
      -e "IMPORT_STYLE=extratags" -e "THREADS=2" -e "GUNICORN_WORKERS=2" `
      -e "NOMINATIM_PASSWORD=$password" -e "TZ=Asia/Shanghai" `
      -v "${nominatimVolume}:/var/lib/postgresql/16/main" -v "${coreRoot}:/data:ro" `
      mediagis/nominatim@sha256:7923a8e67197fc6d4f4ecb7c0e8bbedffeddcfdf4519596fe946e46a28f5a9f8 | Out-Null
    Assert-NativeSuccess "Starting isolated Nominatim"

    $routingRoot = Join-Path $payload "products\routing\valhalla"
    $routingElevation = Join-Path $payload "products\elevation"
    $routingWork = Join-Path $work "valhalla"
    New-Item -ItemType Directory -Force -Path $routingWork | Out-Null
    foreach ($name in @(
      "terrasys-core-latest.osm.pbf", "valhalla_tiles.tar", "valhalla.json", "file_hashes.txt",
      "admins.sqlite", "timezones.sqlite", "default_speeds.json"
    )) {
      Copy-Item -LiteralPath (Join-Path $routingRoot $name) -Destination (Join-Path $routingWork $name) -Force
    }
    docker run -d --name $valhalla --network $network --network-alias valhalla `
      -e "use_tiles_ignore_pbf=True" -e "force_rebuild=False" -e "build_elevation=True" `
      -e "build_admins=True" -e "build_time_zones=True" -e "build_tar=True" -e "server_threads=2" `
      -v "${routingWork}:/custom_files" -v "${routingElevation}:/custom_files/elevation_data:ro" `
      ghcr.io/valhalla/valhalla-scripted@sha256:3d7a08f7e78b356ee873b61711b743ad81bcc114b0ca5731217da8bba6ba39d1 | Out-Null
    Assert-NativeSuccess "Starting isolated Valhalla"

    $encyclopediaRoot = Join-Path $payload "products\encyclopedia"
    $wikipediaFile = Get-ChildItem -LiteralPath $encyclopediaRoot -Filter "wikipedia_zh_all_*.zim" -File | Select-Object -First 1
    $wikivoyageFile = Get-ChildItem -LiteralPath $encyclopediaRoot -Filter "wikivoyage_zh_all_*.zim" -File | Select-Object -First 1
    if (-not $wikipediaFile -or -not $wikivoyageFile) { throw "Recovered Kiwix archives are incomplete." }
    docker run -d --name $kiwix --network $network --network-alias kiwix `
      -e "PORT=8080" -v "${encyclopediaRoot}:/data:ro" `
      ghcr.io/kiwix/kiwix-serve@sha256:57baa553c46cd30770905df15a9a687258aa5471c30c8edaefe278f1784e1aa8 `
      --urlRootLocation=/wiki --blockexternal $wikipediaFile.Name $wikivoyageFile.Name | Out-Null
    Assert-NativeSuccess "Starting isolated Kiwix"

    $advancedReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
      $probeErrorAction = $ErrorActionPreference
      $ErrorActionPreference = "SilentlyContinue"
      docker exec $nominatim curl -fsS http://127.0.0.1:8080/status *> $null
      $nominatimReady = $LASTEXITCODE -eq 0
      docker exec $valhalla curl -fsS http://127.0.0.1:8002/status *> $null
      $valhallaReady = $LASTEXITCODE -eq 0
      docker exec $kiwix wget -q --spider http://127.0.0.1:8080/wiki/ *> $null
      $kiwixReady = $LASTEXITCODE -eq 0
      $ErrorActionPreference = $probeErrorAction
      if ($nominatimReady -and $valhallaReady -and $kiwixReady) { $advancedReady = $true; break }
      Start-Sleep -Seconds 1
    }
    if (-not $advancedReady) { throw "One or more isolated advanced services did not become ready." }
  }

  $catalogPath = Join-Path $payload "web\config\map-catalog.json"
  $regionCatalogPath = Join-Path $payload "web\config\region-catalog.json"
  $worldCatalogPath = Join-Path $payload "web\config\world-region-catalog.json"
  $tileRoot = Join-Path $payload "products\tiles\pmtiles"
  $statePath = Join-Path $payload "raw\osm\china\china.state.txt"
  $osmRoot = Join-Path $payload "raw\osm"
  $routingResources = Join-Path $payload "products\routing"
  $encyclopediaResources = Join-Path $payload "products\encyclopedia"
  $weatherResources = Join-Path $payload "products\weather"
  $nauticalResources = Join-Path $payload "products\nautical"
  $overviewResources = Join-Path $payload "web\assets\overview"
  $webResources = Join-Path $payload "web"
  $advancedApiArgs = @()
  if ($kitInfo.advancedCapabilities) {
    $capabilityManifestPath = Join-Path $payload "raw\osm\china\terrasys-core.manifest.json"
    $elevationRoot = Join-Path $payload "products\elevation"
    $advancedApiArgs = @(
      "-e", "CAPABILITY_MANIFEST_PATH=/data/terrasys-core.manifest.json",
      "-e", "NOMINATIM_URL=http://nominatim:8080",
      "-e", "VALHALLA_URL=http://valhalla:8002",
      "-e", "KIWIX_URL=http://kiwix:8080",
      "-e", "ELEVATION_ROOT=/data/elevation",
      "-e", "TERRAIN_CACHE_ROOT=/data/terrain-cache",
      "-v", "${capabilityManifestPath}:/data/terrasys-core.manifest.json:ro",
      "-v", "${elevationRoot}:/data/elevation:ro",
      "-v", "${terrain}:/data/terrain-cache"
    )
  }
  docker run -d --name $api --network $network --network-alias api `
    -e "DATABASE_URL=$databaseUrl" -e "MEDIA_ROOT=/data/media" -e "EXPORT_ROOT=/data/exports" `
    -e "BACKUP_ROOT=/data/backups" -e "MAP_CATALOG_PATH=/data/map-catalog.json" `
    -e "REGION_CATALOG_PATH=/data/region-catalog.json" -e "WORLD_REGION_CATALOG_PATH=/data/world-region-catalog.json" `
    -e "MAP_PACK_ROOT=/data/map-packs" -e "OSM_STATE_PATH=/data/china.state.txt" `
    -e "OSM_RESOURCE_ROOT=/data/osm-resources" -e "ROUTING_RESOURCE_ROOT=/data/routing-resources" `
    -e "ENCYCLOPEDIA_RESOURCE_ROOT=/data/encyclopedia-resources" -e "WEB_RESOURCE_ROOT=/data/web-resources" `
    -e "WEATHER_RESOURCE_ROOT=/data/weather-resources" -e "NAUTICAL_RESOURCE_ROOT=/data/nautical-resources" `
    -e "OVERVIEW_RESOURCE_ROOT=/data/overview-resources" -e "MAINTENANCE_ROOT=/data/maintenance" `
    @advancedApiArgs `
    -v "${media}:/data/media" -v "${exports}:/data/exports" `
    -v "$($backup.Parent.FullName):/data/backups:ro" -v "${catalogPath}:/data/map-catalog.json:ro" `
    -v "${regionCatalogPath}:/data/region-catalog.json:ro" -v "${worldCatalogPath}:/data/world-region-catalog.json:ro" `
    -v "${osmRoot}:/data/osm-resources:ro" -v "${routingResources}:/data/routing-resources:ro" `
    -v "${encyclopediaResources}:/data/encyclopedia-resources:ro" -v "${webResources}:/data/web-resources:ro" `
    -v "${weatherResources}:/data/weather-resources:ro" -v "${nauticalResources}:/data/nautical-resources:ro" `
    -v "${overviewResources}:/data/overview-resources:ro" -v "${maintenance}:/data/maintenance" `
    -v "${tileRoot}:/data/map-packs:ro" -v "${statePath}:/data/china.state.txt:ro" terrasys-api:1 | Out-Null
  Assert-NativeSuccess "Starting isolated API"
  $apiReady = $false
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $probeErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    docker exec $api python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)" *> $null
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $probeErrorAction
    if ($probeExitCode -eq 0) { $apiReady = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $apiReady) {
    $report.checks.apiStartupLogs = ((docker logs $api 2>&1 | Select-Object -Last 80) -join "`n")
    throw "Isolated API did not become ready."
  }

  $health = Get-ApiJson $api "http://127.0.0.1:8000/health" "Checking isolated API health"
  $status = Get-ApiJson $api "http://127.0.0.1:8000/status" "Checking isolated API status"
  $packStatus = Get-ApiJson $api "http://127.0.0.1:8000/map-packs" "Checking isolated region packs"
  $resources = Get-ApiJson $api "http://127.0.0.1:8000/resources" "Checking isolated resource inventory"
  $weather = Get-ApiJson $api "http://127.0.0.1:8000/weather" "Checking isolated weather snapshot"
  $nauticalData = Get-ApiJson $api "http://127.0.0.1:8000/nautical" "Checking isolated nautical reference"
  $installedPacks = @($packStatus.packs | Where-Object { $_.installed -and $_.sizeMatches })
  if ($installedPacks.Count -lt 2) { throw "Recovery kit contains fewer than two valid region packs." }
  $search = Get-ApiJson $api "http://127.0.0.1:8000/search?q=%E5%8D%97%E4%BA%AC&limit=5" "Checking restored search"
  $capabilities = $null
  $geocode = $null
  $elevation = $null
  $route = $null
  if ($kitInfo.advancedCapabilities) {
    $capabilities = Get-ApiJson $api "http://127.0.0.1:8000/capabilities" "Checking isolated advanced capabilities"
    foreach ($service in @("geocoder", "routing", "elevation", "encyclopedia")) {
      if (-not $capabilities.services.$service.available) { throw "Recovered capability '$service' is unavailable." }
    }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
      try {
        $geocode = Get-ApiJson $api "http://127.0.0.1:8000/geocode?q=%E5%8D%97%E4%BA%AC%E5%A4%A7%E5%AD%A6&limit=5" "Checking restored geocoder"
        break
      }
      catch {
        if ($attempt -eq 4) { throw }
        Start-Sleep -Seconds 3
      }
    }
    if (@($geocode.results).Count -lt 1) { throw "Recovered geocoder returned no result." }
    $elevation = Get-ApiJson $api "http://127.0.0.1:8000/elevation?longitude=118.7969&latitude=32.0603" "Checking restored elevation"
    $routeJson = @{
      costing = "auto"
      locations = @(
        @{ longitude = 118.7969; latitude = 32.0603; name = "Nanjing" },
        @{ longitude = 118.9080; latitude = 32.1040; name = "Xianlin" }
      )
    } | ConvertTo-Json -Depth 5 -Compress
    $route = Post-ApiJson $api "http://127.0.0.1:8000/route" $routeJson "Checking restored routing"
    if (@($route.geometry.coordinates).Count -lt 20 -or @($route.profile).Count -lt 2) {
      throw "Recovered route geometry or elevation profile is incomplete."
    }
  }
  $exportCode = "import json,urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:8000/export/geojson', timeout=15)); print(json.dumps({'type':d.get('type'),'features':len(d.get('features',[]))}))"
  $exportRaw = docker exec $api python -c $exportCode
  Assert-NativeSuccess "Checking restored GeoJSON export"
  $export = (($exportRaw -join "`n") | ConvertFrom-Json)
  $mediaCode = "import json,urllib.request; m=json.load(urllib.request.urlopen('http://127.0.0.1:8000/media', timeout=8)); n=len(urllib.request.urlopen('http://127.0.0.1:8000/media/'+m[0]['id']+'/content', timeout=8).read(16)) if m else 0; print(json.dumps({'records':len(m),'firstFileBytesRead':n}))"
  $mediaRaw = docker exec $api python -c $mediaCode
  Assert-NativeSuccess "Checking restored media"
  $mediaCheck = (($mediaRaw -join "`n") | ConvertFrom-Json)

  $martinConfig = Join-Path $payload "services\martin\config.yaml"
  docker run -d --name $martin --network $network --network-alias martin `
    -e "DATABASE_URL=$databaseUrl" -v "${martinConfig}:/config/config.yaml:ro" `
    ghcr.io/maplibre/martin@sha256:0650e9025f5fcffdc686358114679421b5e6b0ca37b374ad8a66f14709d59d2b --config /config/config.yaml | Out-Null
  Assert-NativeSuccess "Starting isolated Martin"
  $martinReady = $false
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $probeErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $catalogRaw = docker exec $martin wget -qO- http://127.0.0.1:3000/catalog 2>$null
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $probeErrorAction
    if ($probeExitCode -eq 0) { $martinReady = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $martinReady) { throw "Isolated Martin did not become ready." }
  $catalog = (($catalogRaw -join "`n") | ConvertFrom-Json)
  $martinSources = @($catalog.tiles.PSObject.Properties).Count
  if ($martinSources -lt 2) { throw "Martin published fewer than two personal-data sources." }

  $webRoot = Join-Path $payload "web"
  $nginxConfig = Join-Path $payload "services\nginx\default.conf"
  docker run -d --name $web --network $network --network-alias web `
    -v "${webRoot}:/usr/share/nginx/html:ro" -v "${tileRoot}:/srv/pmtiles:ro" `
    -v "${nginxConfig}:/etc/nginx/conf.d/default.conf:ro" `
    nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10 | Out-Null
  Assert-NativeSuccess "Starting isolated web service"
  $webReady = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $probeErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $webHealth = docker exec $web wget -qO- http://127.0.0.1/healthz 2>$null
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $probeErrorAction
    if ($probeExitCode -eq 0) { $webReady = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $webReady -or (($webHealth -join "").Trim() -ne "ok")) { throw "Isolated web service did not become ready." }
  $proxyHealthRaw = docker exec $web wget -qO- http://127.0.0.1/api/health
  Assert-NativeSuccess "Checking the isolated API proxy"
  $proxyHealth = (($proxyHealthRaw -join "`n") | ConvertFrom-Json)
  $proxyCatalogRaw = docker exec $web wget -qO- http://127.0.0.1/martin/catalog
  Assert-NativeSuccess "Checking the isolated Martin proxy"
  $proxyCatalog = (($proxyCatalogRaw -join "`n") | ConvertFrom-Json)
  $wikiAvailable = $false
  if ($kitInfo.advancedCapabilities) {
    $wikiRaw = docker exec $web wget -qO- 'http://127.0.0.1/wiki/catalog/v2/entries?count=-1'
    Assert-NativeSuccess "Checking the isolated encyclopedia proxy"
    $wikiAvailable = ($wikiRaw -join "`n") -match '<name>wikipedia_zh_all</name>'
    $travelAvailable = ($wikiRaw -join "`n") -match '<name>wikivoyage_zh_all</name>'
    if (-not $wikiAvailable -or -not $travelAvailable) { throw "Recovered knowledge proxy returned unexpected content." }
  }

  $pmtilesHeaders = [ordered]@{}
  foreach ($pack in $installedPacks) {
    $pmtiles = Join-Path $tileRoot ([IO.Path]::GetFileName([string]$pack.url))
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $tileRoot ([IO.Path]::GetFileName([string]$pack.manifestUrl))) | ConvertFrom-Json
    $details = if ($manifest.details.file) { Join-Path $tileRoot ([IO.Path]::GetFileName([string]$manifest.details.file)) } else { $null }
    if (-not $details -or -not (Test-Path -LiteralPath $details -PathType Leaf)) {
      throw "Rich-detail PMTiles is missing from the recovery kit for $($pack.id)."
    }
    foreach ($archive in @($pmtiles, $details)) {
      $stream = [IO.File]::OpenRead($archive)
      try {
        $headerBytes = New-Object byte[] 7
        $read = $stream.Read($headerBytes, 0, 7)
      }
      finally { $stream.Dispose() }
      $pmtilesHeader = [Text.Encoding]::ASCII.GetString($headerBytes, 0, $read)
      if ($pmtilesHeader -ne "PMTiles") { throw "PMTiles archive header is invalid: $archive" }
    }
    $pmtilesHeaders[$pack.id] = "PMTiles+details"
  }

  docker exec $api python -c "import socket,sys; s=socket.socket(); s.settimeout(2); r=s.connect_ex(('1.1.1.1',443)); s.close(); sys.exit(0 if r != 0 else 1)" *> $null
  Assert-NativeSuccess "Proving the recovery network has no external route"

  $report.checks = [ordered]@{
    postgis = $health.postgis
    apiStatus = $status.status
    apiCountsMatch = ([int64]$status.places -eq $report.counts.places -and [int64]$status.reference_places -eq $report.counts.referencePlaces)
    searchResults = @($search.results).Count
    exportFeatures = [int64]$export.features
    mediaRecords = [int64]$mediaCheck.records
    mediaFirstFileBytesRead = [int64]$mediaCheck.firstFileBytesRead
    martinSources = $martinSources
    webHealth = (($webHealth -join "").Trim())
    webApiProxy = $proxyHealth.status
    webMartinSources = @($proxyCatalog.tiles.PSObject.Properties).Count
    regionPacks = $installedPacks.Count
    mapPackCatalog = [int]$resources.summary.mapPackCount
    updateChecks = @($resources.updateChecks).Count
    weatherLocations = @($weather.features).Count
    nauticalFeatures = @($nauticalData.features).Count
    pmtilesHeaders = $pmtilesHeaders
    advancedServices = if ($kitInfo.advancedCapabilities) { [ordered]@{
      geocoder = [bool]$capabilities.services.geocoder.available
      geocodeResults = @($geocode.results).Count
      routing = [bool]$capabilities.services.routing.available
      routePoints = @($route.geometry.coordinates).Count
      elevationMeters = $elevation.elevation_m
      encyclopedia = $wikiAvailable
      travelGuide = $travelAvailable
    }} else { $null }
    externalRouteBlocked = $true
  }
  if (-not $report.checks.apiCountsMatch -or $report.checks.searchResults -lt 1 -or $report.checks.exportFeatures -lt 1 -or
      $report.checks.mapPackCatalog -lt 500 -or $report.checks.updateChecks -lt 8 -or
      $report.checks.weatherLocations -lt 1 -or $report.checks.nauticalFeatures -lt 1) {
    throw "Restored API data checks did not pass."
  }
  $report.success = $true
}
catch {
  $caught = $_
  $report.error = $_.Exception.Message
}
finally {
  $cleanupErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  foreach ($container in @($web, $martin, $api, $kiwix, $valhalla, $nominatim, $postgres)) {
    docker rm -f $container *> $null
  }
  docker volume rm -f $volume *> $null
  docker volume rm -f $nominatimVolume *> $null
  docker network rm $network *> $null
  $ErrorActionPreference = $cleanupErrorAction
  $report.completedAt = (Get-Date).ToUniversalTime().ToString("o")
  New-Item -ItemType Directory -Force -Path $auditRoot | Out-Null
  $reportPath = Join-Path $auditRoot ((Get-Date -Format "yyyyMMdd-HHmmss") + "-$id.json")
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
  $workFull = [IO.Path]::GetFullPath($work)
  $auditFull = [IO.Path]::GetFullPath($auditRoot).TrimEnd('\')
  if (Test-Path -LiteralPath $workFull) {
    if (-not $workFull.StartsWith($auditFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove recovery work outside $auditFull"
    }
    [IO.Directory]::Delete($workFull, $true)
  }
}

if ($caught) {
  Write-Host "Recovery audit report: $reportPath"
  throw $caught
}
Write-Host "Offline recovery drill passed: $reportPath"
$report | ConvertTo-Json -Depth 8
