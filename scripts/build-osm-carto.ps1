param(
  [switch]$ForceImport,
  [string]$MaintenanceJobId = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$compose = Join-Path $root "services\docker-compose.yml"
$envFile = Join-Path $root "services\.env"
$imageDigest = "sha256:b6a79da39b6d0758368f7c62d22e49dd3ec59e78b194a5ef9dee2723b1f3fa79"
$canonicalImage = "overv/openstreetmap-tile-server@$imageDigest"
$fallbackImages = @("docker.1ms.run/overv/openstreetmap-tile-server@$imageDigest")
$image = ""
$sourceManifest = Join-Path $root "raw\osm\carto\installed-regions.manifest.json"
$externalRoot = Join-Path $root "raw\osm\carto\external"
$externalConfig = Join-Path $root "config\osm-carto\external-data.local.yml"
$localImportScript = Join-Path $root "scripts\osm-carto-import-local.sh"
$normalizedImportScript = Join-Path $root "runtime\osm-carto-support\import-local.sh"
$apacheConfig = Join-Path $root "services\osm-carto-apache.conf"
$productRoot = Join-Path $root "products\osm-carto"
$manifestPath = Join-Path $productRoot "osm-carto.manifest.json"
$tileCache = Join-Path $root "data\osm-carto-tiles"
$statePath = Join-Path $root "data\maintenance\osm-carto-state.json"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$candidateVolume = "terrasys_osm_carto_candidate_$timestamp"
$candidateContainer = "terrasys-osm-carto-candidate-$timestamp"
$candidateCache = Join-Path $root "runtime\osm-carto-candidate\$timestamp"
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$switched = $false
$activeVolume = ""
$requiredExternalFiles = @(
  "simplified-water-polygons-split-3857.zip",
  "water-polygons-split-3857.zip",
  "antarctica-icesheet-polygons-3857.zip",
  "antarctica-icesheet-outlines-3857.zip",
  "ne_110m_admin_0_boundary_lines_land.zip"
)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Set-DotEnvValue([string]$Name, [string]$Value) {
  $lines = [Collections.Generic.List[string]]::new()
  if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $envFile) { $lines.Add([string]$line) }
  }
  $updated = $false
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match "^\s*$([regex]::Escape($Name))=") {
      $lines[$index] = "$Name=$Value"
      $updated = $true
      break
    }
  }
  if (-not $updated) { $lines.Add("$Name=$Value") }
  [IO.File]::WriteAllLines($envFile, $lines, (New-Object Text.UTF8Encoding($false)))
}

function Get-DotEnvValue([string]$Name) {
  if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) { return "" }
  $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))=" } | Select-Object -First 1
  if (-not $line) { return "" }
  return ([string]$line).Substring(([string]$line).IndexOf('=') + 1).Trim()
}

function Test-LocalDockerImage([string]$Reference) {
  $savedPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "SilentlyContinue"
    docker image inspect $Reference *> $null
    return $LASTEXITCODE -eq 0
  }
  catch { return $false }
  finally { $ErrorActionPreference = $savedPreference }
}

function Resolve-OsmCartoImage {
  $configured = Get-DotEnvValue "OSM_CARTO_IMAGE"
  if ($configured -and -not $configured.EndsWith("@$imageDigest", [StringComparison]::OrdinalIgnoreCase)) {
    throw "OSM_CARTO_IMAGE must be pinned to the approved digest $imageDigest."
  }

  $candidates = @($configured, $canonicalImage) + $fallbackImages |
    Where-Object { $_ } |
    Select-Object -Unique
  foreach ($candidate in $candidates) {
    if (Test-LocalDockerImage $candidate) {
      Set-DotEnvValue "OSM_CARTO_IMAGE" $candidate
      return $candidate
    }

    Write-Host "Downloading pinned OSM Carto renderer from $candidate ..."
    $savedPreference = $ErrorActionPreference
    $pullSucceeded = $false
    try {
      $ErrorActionPreference = "Continue"
      docker pull $candidate | Out-Host
      $pullSucceeded = $LASTEXITCODE -eq 0
    }
    catch {
      Write-Warning "Docker could not pull $candidate`: $($_.Exception.Message)"
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($pullSucceeded) {
      Set-DotEnvValue "OSM_CARTO_IMAGE" $candidate
      return $candidate
    }
    Write-Warning "Pinned renderer source unavailable: $candidate"
  }
  throw "No approved registry could provide the pinned OSM Carto renderer $imageDigest."
}

function Invoke-Compose([string[]]$Arguments, [string]$Operation) {
  & docker compose -f $compose --profile advanced @Arguments | Out-Host
  Assert-NativeSuccess $Operation
}

function Wait-ContainerEndpoint([string]$Container, [string]$Url, [int]$TimeoutMinutes, [string]$Label) {
  $attempts = [math]::Max(1, $TimeoutMinutes * 6)
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    docker exec $Container curl -fsS --max-time 8 $Url *> $null
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($probeExitCode -eq 0) { return }
    $state = ((docker inspect --format '{{.State.Status}}' $Container 2>$null) -join "").Trim()
    if ($state -in @("exited", "dead")) { throw "$Label exited before validation." }
    Start-Sleep -Seconds 10
  }
  throw "$Label did not become ready within $TimeoutMinutes minutes."
}

function Wait-Healthy([string]$Container, [int]$TimeoutMinutes) {
  $attempts = [math]::Max(1, $TimeoutMinutes * 6)
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $state = ((docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' $Container 2>$null) -join "").Trim()
    if ($state -eq "running|healthy") { return }
    if ($state -like "exited|*" -or $state -like "dead|*") { throw "$Container exited during activation." }
    Start-Sleep -Seconds 10
  }
  throw "$Container did not become healthy within $TimeoutMinutes minutes."
}

function Wait-RenderedTile([string]$Container, [string]$RegionId, [string]$Url, [int]$TimeoutMinutes = 8) {
  $target = "/tmp/$RegionId.png"
  $attempts = [math]::Max(1, $TimeoutMinutes * 6)
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $status = (docker exec $Container curl -sS --max-time 90 -o $target -w '%{http_code}' $Url 2>$null | Select-Object -Last 1)
    $curlExitCode = $LASTEXITCODE
    $sizeText = if ($curlExitCode -eq 0 -and $status -eq "200") {
      docker exec $Container stat -c '%s' $target 2>$null | Select-Object -Last 1
    } else { "0" }
    $sizeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    $size = 0L
    if ($sizeExitCode -eq 0) { [void][int64]::TryParse(([string]$sizeText).Trim(), [ref]$size) }
    if ($curlExitCode -eq 0 -and $status -eq "200" -and $size -gt 1024) {
      Write-Host "Validated $RegionId OSM Carto tile ($size bytes)."
      return
    }
    $state = ((docker inspect --format '{{.State.Status}}' $Container 2>$null) -join "").Trim()
    if ($state -in @("exited", "dead")) { throw "OSM Carto candidate exited while rendering $RegionId." }
    Start-Sleep -Seconds 10
  }
  throw "OSM Carto did not render a non-empty validation tile for $RegionId within $TimeoutMinutes minutes."
}

function Warm-RenderedBounds([string]$Container, [double[]]$Bounds, [int]$MinZoom = 5, [int]$MaxZoom = 8) {
  Write-Host "Prewarming OSM Carto viewport tiles at zooms $MinZoom-$MaxZoom."
  $longitude = ($Bounds[0] + $Bounds[2]) / 2
  $latitude = ($Bounds[1] + $Bounds[3]) / 2
  for ($zoom = $MinZoom; $zoom -le $MaxZoom; $zoom++) {
    $tile = Get-TileCoordinate -Longitude $longitude -Latitude $latitude -Zoom $zoom
    Wait-RenderedTile $Container "overview-z$zoom" "http://127.0.0.1/tile/$zoom/$($tile.x)/$($tile.y).png"
  }
}

function Get-TileCoordinate([double]$Longitude, [double]$Latitude, [int]$Zoom) {
  $count = [math]::Pow(2, $Zoom)
  $latitude = [math]::Max(-85.05112878, [math]::Min(85.05112878, $Latitude))
  $radians = $latitude * [math]::PI / 180
  return [pscustomobject]@{
    x = [math]::Floor(($Longitude + 180) / 360 * $count)
    y = [math]::Floor((1 - [math]::Log([math]::Tan($radians) + 1 / [math]::Cos($radians)) / [math]::PI) / 2 * $count)
  }
}

function Remove-CandidateResources {
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  docker rm -f $candidateContainer *> $null
  if (-not $switched) { docker volume rm $candidateVolume *> $null }
  $ErrorActionPreference = $savedPreference
  if (Test-Path -LiteralPath $candidateCache -PathType Container) {
    Remove-Item -LiteralPath $candidateCache -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }
docker info *> $null
Assert-NativeSuccess "Checking Docker"

& (Join-Path $PSScriptRoot "download-osm-carto-sources.ps1")

$externalInputs = foreach ($name in $requiredExternalFiles) {
  $path = Join-Path $externalRoot $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing local OSM Carto external dataset: $path" }
  $info = Get-Item -LiteralPath $path
  [pscustomobject][ordered]@{
    file = "raw/osm/carto/external/$name"
    bytes = $info.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  }
}
$externalSignature = ($externalInputs | ForEach-Object { "$($_.file):$($_.sha256)" }) -join ':'
foreach ($path in @($externalConfig, $localImportScript, $apacheConfig)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing local OSM Carto import support file: $path" }
}
$normalizedImportRoot = Split-Path -Parent $normalizedImportScript
New-Item -ItemType Directory -Force -Path $normalizedImportRoot | Out-Null
$importContents = (Get-Content -Raw -LiteralPath $localImportScript).Replace("`r`n", "`n")
[IO.File]::WriteAllText($normalizedImportScript, $importContents, $utf8NoBom)

& (Join-Path $PSScriptRoot "build-osm-carto-source.ps1")
if ($LASTEXITCODE -ne 0) { throw "Preparing the OSM Carto source failed." }
New-Item -ItemType Directory -Force -Path $productRoot, $tileCache, $candidateCache, (Split-Path -Parent $statePath) | Out-Null
$sourceState = Get-Content -Raw -LiteralPath $sourceManifest | ConvertFrom-Json
$source = Join-Path $root ([string]$sourceState.product.file).Replace('/', '\')
$sourceHash = [string]$sourceState.product.sha256
$current = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
} else { $null }
$previousState = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
} else { $null }

$inspect = docker inspect terrasys-osm-carto 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and @($inspect).Count) {
  $mount = $inspect[0].Mounts | Where-Object { $_.Destination -eq "/data/database" } | Select-Object -First 1
  if ($mount.Name) { $activeVolume = [string]$mount.Name }
}
if (-not $activeVolume) {
  $configured = Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^OSM_CARTO_VOLUME_NAME=' } | Select-Object -First 1
  $activeVolume = if ($configured) { $configured.Substring("OSM_CARTO_VOLUME_NAME=".Length).Trim() } else { "terrasys_osm_carto_data" }
}

$currentExternalSignature = if ($current -and $current.externalData -and $current.externalData.inputs) {
  (@($current.externalData.inputs) | ForEach-Object { "$($_.file):$($_.sha256)" }) -join ':'
} else { "" }
$sourceChanged = -not $current -or [string]$current.source.sha256 -ne $sourceHash -or $currentExternalSignature -ne $externalSignature
$image = Resolve-OsmCartoImage
$activeReady = [bool](docker volume ls -q --filter "name=^${activeVolume}$")
if ($activeReady) {
  docker run --rm --entrypoint bash -v "${activeVolume}:/data/database/:ro" $image -lc `
    "test -f /data/database/postgres/PG_VERSION -a -f /data/database/planet-import-complete"
  $activeReady = $LASTEXITCODE -eq 0
}
$needsImport = $ForceImport -or -not $activeReady -or $sourceChanged

if (-not $needsImport) {
  Write-Host "OSM Carto already matches $(@($sourceState.scope).Count) enabled installed regions."
  Invoke-Compose @("up", "-d", "osm-carto", "api", "web") "Starting the current OSM Carto service"
  exit 0
}

try {
  Write-Host "OSM_CARTO_STAGE 1/4 IMPORT"
  & docker volume create --label "terrasys.role=osm-carto-candidate" --label "terrasys.maintenance-job=$MaintenanceJobId" $candidateVolume | Out-Null
  Assert-NativeSuccess "Creating the OSM Carto candidate volume"
  $importArgs = @(
    "run", "--rm", "--name", "terrasys-osm-carto-import-$timestamp", "--shm-size", "1g",
    "--memory", "6g", "--memory-swap", "7g", "--cpus", "4",
    "--label", "terrasys.role=osm-carto-candidate", "--label", "terrasys.maintenance-job=$MaintenanceJobId",
    "-e", "THREADS=3", "-e", "OSM2PGSQL_EXTRA_ARGS=-C 3072",
    "-v", "${source}:/data/region.osm.pbf:ro", "-v", "${candidateVolume}:/data/database/",
    "-v", "${candidateCache}:/data/tiles/", "-v", "${externalRoot}:/external:ro",
    "-v", "${externalConfig}:/repair/external-data.yml:ro", "-v", "${normalizedImportScript}:/repair/import-local.sh:ro",
    "--entrypoint", "bash", $image, "/repair/import-local.sh"
  )
  & docker @importArgs
  $importExitCode = $LASTEXITCODE
  if ($importExitCode -ne 0) {
    docker run --rm --entrypoint bash -v "${candidateVolume}:/data/database/:ro" $image -lc "test -f /data/database/postgres/PG_VERSION"
    if ($LASTEXITCODE -ne 0) { throw "OSM Carto candidate import failed before the database was created." }
    Write-Warning "The regional import succeeded, but an external dataset failed. Resuming from verified local files."
  }

  Write-Host "OSM_CARTO_STAGE 2/4 EXTERNAL"
  docker run --rm --entrypoint bash -v "${candidateVolume}:/data/database/:ro" $image -lc "test -f /data/database/planet-import-complete"
  if ($LASTEXITCODE -ne 0) {
    & (Join-Path $PSScriptRoot "repair-osm-carto-external.ps1") -Image $image -DataVolume $candidateVolume
    if ($LASTEXITCODE -ne 0) { throw "OSM Carto candidate external-data repair failed." }
  }

  $databaseBytesText = docker run --rm --entrypoint bash -v "${candidateVolume}:/data/database/:ro" $image -lc "du -sb /data/database | cut -f1"
  Assert-NativeSuccess "Measuring the OSM Carto candidate database"
  $databaseBytes = [int64](($databaseBytesText | Select-Object -Last 1).Trim())

  Write-Host "OSM_CARTO_STAGE 3/4 VERIFY"
  $candidateArgs = @(
    "run", "-d", "--name", $candidateContainer, "--shm-size", "1g",
    "--memory", "3g", "--memory-swap", "3g", "--cpus", "2",
    "--label", "terrasys.role=osm-carto-candidate", "--label", "terrasys.maintenance-job=$MaintenanceJobId",
    "-e", "THREADS=2", "-e", "ALLOW_CORS=enabled", "-e", "AUTOVACUUM=on", "-e", "TZ=Asia/Shanghai",
    "-v", "${candidateVolume}:/data/database/", "-v", "${candidateCache}:/data/tiles/",
    "-v", "${apacheConfig}:/etc/apache2/sites-available/000-default.conf:ro", $image, "run"
  )
  & docker @candidateArgs | Out-Null
  Assert-NativeSuccess "Starting the OSM Carto candidate renderer"
  Wait-ContainerEndpoint $candidateContainer "http://127.0.0.1/" 10 "OSM Carto candidate"

  $catalog = Get-TerraSysExpandedCatalog -Root $root
  $datasets = @{}
  foreach ($dataset in @($catalog.datasets)) { $datasets[[string]$dataset.id] = $dataset }
  foreach ($id in @($sourceState.scope)) {
    $dataset = $datasets[[string]$id]
    if (-not $dataset -or @($dataset.bounds).Count -ne 4) { throw "OSM Carto scope $id has no validation bounds." }
    $longitude = ([double]$dataset.bounds[0] + [double]$dataset.bounds[2]) / 2
    $latitude = ([double]$dataset.bounds[1] + [double]$dataset.bounds[3]) / 2
    $tile = Get-TileCoordinate -Longitude $longitude -Latitude $latitude -Zoom 8
    Wait-RenderedTile $candidateContainer $id "http://127.0.0.1/tile/8/$($tile.x)/$($tile.y).png"
  }
  $enabledDatasets = @($sourceState.scope | ForEach-Object { $datasets[[string]$_] })
  $warmBounds = [double[]]@(
    ($enabledDatasets | ForEach-Object { [double]$_.bounds[0] } | Measure-Object -Minimum).Minimum,
    ($enabledDatasets | ForEach-Object { [double]$_.bounds[1] } | Measure-Object -Minimum).Minimum,
    ($enabledDatasets | ForEach-Object { [double]$_.bounds[2] } | Measure-Object -Maximum).Maximum,
    ($enabledDatasets | ForEach-Object { [double]$_.bounds[3] } | Measure-Object -Maximum).Maximum
  )
  Warm-RenderedBounds -Container $candidateContainer -Bounds $warmBounds
  docker rm -f $candidateContainer | Out-Null

  $manifest = [ordered]@{
    schemaVersion = 2
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    renderer = [ordered]@{
      name = "OpenStreetMap Carto"
      image = $canonicalImage
      runtimeImage = $image
      tiles = "/osm-carto/tile/{z}/{x}/{y}.png"
      minZoom = 0
      maxZoom = 20
    }
    source = [ordered]@{
      file = [string]$sourceState.product.file
      bytes = [int64]$sourceState.product.bytes
      sha256 = $sourceHash
      regions = @($sourceState.scope)
      inputs = @($sourceState.inputs)
    }
    externalData = [ordered]@{
      mode = "local-archive"
      inputs = @($externalInputs)
    }
    storage = [ordered]@{
      databaseVolume = $candidateVolume
      databaseBytes = $databaseBytes
      tileCache = "data/osm-carto-tiles"
    }
  }

  Write-Host "OSM_CARTO_STAGE 4/4 ACTIVATE"
  Set-DotEnvValue "OSM_CARTO_VOLUME_NAME" $candidateVolume
  Get-ChildItem -LiteralPath $tileCache -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
  Get-ChildItem -LiteralPath $candidateCache -Force -ErrorAction Stop | Copy-Item -Destination $tileCache -Recurse -Force
  try {
    Invoke-Compose @("up", "-d", "--force-recreate", "osm-carto") "Activating the OSM Carto candidate"
    Wait-Healthy "terrasys-osm-carto" 15
    $switched = $true
  }
  catch {
    Set-DotEnvValue "OSM_CARTO_VOLUME_NAME" $activeVolume
    Get-ChildItem -LiteralPath $tileCache -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    Invoke-Compose @("up", "-d", "--force-recreate", "osm-carto") "Restoring the previous OSM Carto database"
    Wait-Healthy "terrasys-osm-carto" 15
    throw
  }

  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), $utf8NoBom)
  $state = [ordered]@{
    schemaVersion = 1
    strategy = "blue-green"
    status = "active"
    activatedAt = [DateTimeOffset]::Now.ToString("o")
    activeVolume = $candidateVolume
    previousVolume = $activeVolume
    source = [string]$sourceState.product.file
    regions = @($sourceState.scope)
  }
  [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), $utf8NoBom)
  Invoke-Compose @("up", "-d", "--force-recreate", "api", "web") "Refreshing API and web resource state"
  Wait-Healthy "terrasys-api" 10
  Wait-Healthy "terrasys-web" 5

  $obsoleteVolumes = @()
  if ($previousState -and $previousState.previousVolume) { $obsoleteVolumes += [string]$previousState.previousVolume }
  $obsoleteVolumes += @(docker volume ls -q --filter "label=terrasys.role=osm-carto-candidate" 2>$null)
  foreach ($volume in @($obsoleteVolumes | Select-Object -Unique)) {
    if (-not $volume -or $volume -in @($candidateVolume, $activeVolume)) { continue }
    docker volume rm $volume | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not prune obsolete OSM Carto volume $volume." }
  }
}
finally {
  Remove-CandidateResources
}

Write-Host "OSM Carto now covers $(@($sourceState.scope).Count) enabled installed regions."
Get-Item -LiteralPath $manifestPath | Select-Object FullName, Length, LastWriteTime
