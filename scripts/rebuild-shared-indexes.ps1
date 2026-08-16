param(
  [switch]$Plan,
  [switch]$ConfirmRebuild,
  [int]$ValhallaTimeoutMinutes = 360,
  [int]$NominatimTimeoutMinutes = 1440,
  [ValidateRange(2, 8)][int]$BuildCpus = 3,
  [ValidateRange(4, 10)][int]$BuildMemoryGB = 5,
  [string]$MaintenanceJobId = "",
  [string]$ResumeCandidateId = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$services = Join-Path $root "services"
$compose = Join-Path $services "docker-compose.yml"
$envFile = Join-Path $services ".env"
if ($ResumeCandidateId -and $ResumeCandidateId -notmatch '^\d{8}-\d{6}$') {
  throw "ResumeCandidateId must use yyyyMMdd-HHmmss format."
}
$timestamp = if ($ResumeCandidateId) { $ResumeCandidateId } else { Get-Date -Format "yyyyMMdd-HHmmss" }
$audit = Join-Path $root "runtime\index-rebuild\$timestamp"
$capabilityRoot = Join-Path $root "raw\osm\china"
$capabilitySource = Join-Path $capabilityRoot "terrasys-core-latest.osm.pbf"
$capabilityManifestPath = Join-Path $capabilityRoot "terrasys-core.manifest.json"
$activeRoutingDefault = Join-Path $root "products\routing\valhalla"
$elevationRoot = Join-Path $root "products\elevation"
$routingVersions = Join-Path $root "products\routing\versions"
$candidateRouting = Join-Path $audit "candidate-valhalla"
$candidateRoutingFinal = Join-Path $routingVersions $timestamp
$statePath = Join-Path $root "data\maintenance\shared-index-state.json"
$candidateNominatimVolume = "terrasys_nominatim_candidate_$timestamp"
$candidateNominatimContainer = "terrasys-nominatim-candidate-$timestamp"
$candidateValhallaContainer = "terrasys-valhalla-candidate-$timestamp"
$nominatimImageDigest = "sha256:7923a8e67197fc6d4f4ecb7c0e8bbedffeddcfdf4519596fe946e46a28f5a9f8"
$nominatimImage = "mediagis/nominatim@$nominatimImageDigest"
$valhallaImage = "ghcr.io/valhalla/valhalla-scripted@sha256:3d7a08f7e78b356ee873b61711b743ad81bcc114b0ca5731217da8bba6ba39d1"
$utf8 = New-Object Text.UTF8Encoding($false)
$report = [ordered]@{
  schemaVersion = 2
  strategy = "blue-green"
  mapAvailableDuringBuild = $true
  startedAt = [DateTimeOffset]::Now.ToString("o")
  success = $false
  switched = $false
  error = $null
  resumed = [bool]$ResumeCandidateId
}
$previousNominatimVolume = $null
$previousRoutingPath = $null
$routingPromoted = $false

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Read-DotEnv {
  $values = @{}
  if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) { return $values }
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $values[$matches[1]] = $matches[2] }
  }
  return $values
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
  [IO.File]::WriteAllLines($envFile, $lines, $utf8)
}

function Invoke-Compose([string[]]$Arguments, [string]$Operation) {
  Push-Location $services
  try {
    & docker compose --env-file $envFile -f $compose --profile advanced @Arguments
    Assert-NativeSuccess $Operation
  }
  finally { Pop-Location }
}

function Get-ActiveMount([string]$Container, [string]$Destination, [string]$Property) {
  $inspect = (docker inspect $Container | ConvertFrom-Json)[0]
  Assert-NativeSuccess "Inspecting $Container"
  $mount = $inspect.Mounts | Where-Object { $_.Destination -eq $Destination } | Select-Object -First 1
  if (-not $mount) { throw "$Container does not mount $Destination." }
  return [string]$mount.$Property
}

function Get-CapabilityValidationPoints {
  $manifestPath = Join-Path $capabilityRoot "terrasys-core.manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Capability-source manifest is missing: $manifestPath"
  }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $catalog = Get-TerraSysExpandedCatalog -Root $root
  $datasets = @{}
  foreach ($dataset in @($catalog.datasets)) { $datasets[[string]$dataset.id] = $dataset }

  $points = @()
  foreach ($input in @($manifest.inputs)) {
    $id = [string]$input.id
    $dataset = $datasets[$id]
    if (-not $dataset -or @($dataset.bounds).Count -ne 4) {
      throw "Installed capability input $id has no usable catalog bounds."
    }
    $bounds = @($dataset.bounds | ForEach-Object { [double]$_ })
    $points += [pscustomobject][ordered]@{
      id = $id
      label = if ($dataset.name) { [string]$dataset.name } else { $id }
      latitude = ($bounds[1] + $bounds[3]) / 2
      longitude = ($bounds[0] + $bounds[2]) / 2
    }
  }
  if ($points.Count -lt 1) { throw "No validation point could be derived from the installed map packs." }
  return $points
}

function New-CapabilitySourceLink([string]$Destination) {
  if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
  try {
    New-Item -ItemType HardLink -Path $Destination -Target $capabilitySource -ErrorAction Stop | Out-Null
    Write-Host "Linked the Valhalla source to the shared capability PBF without duplicating its bytes."
  }
  catch {
    Write-Warning "A hard link could not be created; falling back to a full source copy: $($_.Exception.Message)"
    Copy-Item -LiteralPath $capabilitySource -Destination $Destination -Force
  }
}

function Wait-ContainerEndpoint([string]$Container, [string]$Url, [int]$TimeoutMinutes, [string]$Label) {
  $attempts = [math]::Max(1, $TimeoutMinutes * 6)
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $state = ((docker inspect --format '{{.State.Status}}' $Container 2>$null) -join "").Trim()
    if ($state -eq "exited" -or $state -eq "dead") { throw "$Label candidate exited before validation." }
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    docker exec $Container curl -fsS --max-time 8 $Url *> $null
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorAction
    if ($probeExitCode -eq 0) { return }
    if ($attempt -gt 0 -and $attempt % 6 -eq 0) {
      Write-Host "$Label candidate is still building; the active map remains available."
      $savedLogErrorAction = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      $recentLogs = @(docker logs --since 70s --tail 12 $Container 2>&1)
      $ErrorActionPreference = $savedLogErrorAction
      $recentLogs | ForEach-Object { Write-Host "$_" }
    }
    Start-Sleep -Seconds 10
  }
  throw "$Label candidate did not become ready within $TimeoutMinutes minutes."
}

function Test-ValhallaCoverage([string]$Container, [object[]]$Points) {
  foreach ($point in $Points) {
    $payload = [ordered]@{
      locations = @(
        [ordered]@{ lat = [double]$point.latitude; lon = [double]$point.longitude },
        [ordered]@{ lat = [double]$point.latitude + 0.02; lon = [double]$point.longitude + 0.03 }
      )
      costing = "auto"
      units = "kilometers"
    } | ConvertTo-Json -Depth 5 -Compress
    $encoded = [uri]::EscapeDataString($payload)
    $response = docker exec $Container curl -fsS --max-time 30 "http://127.0.0.1:8002/route?json=$encoded"
    Assert-NativeSuccess "Testing Valhalla coverage for $($point.label)"
    $route = ($response -join "") | ConvertFrom-Json
    if (-not $route.trip -or @($route.trip.legs).Count -lt 1) {
      throw "Valhalla returned no route for installed map pack $($point.id)."
    }
  }
}

function Wait-Healthy([string]$Container, [int]$TimeoutMinutes) {
  $attempts = [math]::Max(1, $TimeoutMinutes * 6)
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $state = ((docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' $Container 2>$null) -join "").Trim()
    if ($state -eq "running|healthy") { return }
    if ($state -like "exited|*" -or $state -like "dead|*") { throw "$Container exited while activating the candidate." }
    Start-Sleep -Seconds 10
  }
  throw "$Container did not become healthy within $TimeoutMinutes minutes."
}

function Remove-CandidateContainers {
  foreach ($container in @($candidateNominatimContainer, $candidateValhallaContainer)) {
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    docker container inspect $container *> $null
    $exists = $LASTEXITCODE -eq 0
    if ($exists) { docker rm -f $container *> $null }
    $ErrorActionPreference = $savedErrorAction
  }
}

function Restore-ActivePointers {
  if (-not $previousNominatimVolume -or -not $previousRoutingPath) { return }
  Set-DotEnvValue "NOMINATIM_VOLUME_NAME" $previousNominatimVolume
  Set-DotEnvValue "VALHALLA_DATA_PATH" ($previousRoutingPath -replace '\\', '/')
  Invoke-Compose @("up", "-d", "--force-recreate", "nominatim", "valhalla") "Restoring the previous shared indexes"
  Wait-Healthy "terrasys-nominatim" 20
  Wait-Healthy "terrasys-valhalla" 20
  Invoke-Compose @("up", "-d", "--force-recreate", "api") "Refreshing the API after rollback"
  Wait-Healthy "terrasys-api" 10
  Invoke-Compose @("up", "-d", "--force-recreate", "web") "Refreshing the web entry after rollback"
  Wait-Healthy "terrasys-web" 5
}

$configuredImages = Read-DotEnv
if ($configuredImages.ContainsKey("NOMINATIM_IMAGE") -and $configuredImages.NOMINATIM_IMAGE) {
  $nominatimImage = [string]$configuredImages.NOMINATIM_IMAGE
}
if (-not ($nominatimImage.Equals($nominatimImageDigest, [StringComparison]::OrdinalIgnoreCase) -or
    $nominatimImage.EndsWith("@$nominatimImageDigest", [StringComparison]::OrdinalIgnoreCase))) {
  throw "NOMINATIM_IMAGE must be pinned to the approved digest $nominatimImageDigest."
}

if ($Plan) {
  [pscustomobject]@{
    Action = "Build isolated search and routing candidates, validate, then switch"
    Availability = "The current map, search and routing services stay online during the build"
    CandidateMemoryLimit = "${BuildMemoryGB}GB"
    CandidateCpuLimit = $BuildCpus
    CapabilitySource = $capabilitySource
    Command = "D:\TerraSys\rebuild-shared-indexes.cmd -ConfirmRebuild"
  } | Format-List
  exit 0
}
if (-not $ConfirmRebuild) { throw "Re-run with -ConfirmRebuild after reviewing -Plan output." }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required." }
docker info *> $null
Assert-NativeSuccess "Checking Docker"

New-Item -ItemType Directory -Force -Path $audit, $routingVersions, (Split-Path -Parent $statePath) | Out-Null
if ($MaintenanceJobId) { [IO.File]::WriteAllText((Join-Path $audit "maintenance-job-id.txt"), $MaintenanceJobId, $utf8) }

try {
  $previousNominatimVolume = Get-ActiveMount "terrasys-nominatim" "/var/lib/postgresql/16/main" "Name"
  $previousRoutingPath = Get-ActiveMount "terrasys-valhalla" "/custom_files" "Source"
  if (-not $previousNominatimVolume -or -not $previousRoutingPath) { throw "The active index pointers could not be identified." }
  $report.previous = [ordered]@{ nominatimVolume = $previousNominatimVolume; valhallaPath = $previousRoutingPath }

  # Migrate legacy state before the candidate source replaces the source
  # manifest. This keeps the active coverage distinct from work in progress.
  if ((Test-Path -LiteralPath $statePath -PathType Leaf) -and (Test-Path -LiteralPath $capabilityManifestPath -PathType Leaf)) {
    $activeState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if (-not $activeState.inputs) {
      $activeManifest = Get-Content -Raw -LiteralPath $capabilityManifestPath | ConvertFrom-Json
      $activeState | Add-Member -NotePropertyName inputs -NotePropertyValue @($activeManifest.inputs) -Force
      $activeState | Add-Member -NotePropertyName sourceSha256 -NotePropertyValue ([string]$activeManifest.product.sha256) -Force
      [IO.File]::WriteAllText($statePath, ($activeState | ConvertTo-Json -Depth 8), $utf8)
    }
  }

  if ($ResumeCandidateId) {
    Write-Host "Resuming completed shared-index candidates from $ResumeCandidateId..."
    if (-not (Test-Path -LiteralPath $capabilitySource -PathType Leaf)) { throw "The shared capability source is missing." }
    $validationPoints = @(Get-CapabilityValidationPoints)
    foreach ($name in @("terrasys-core-latest.osm.pbf", "valhalla_tiles.tar", "valhalla.json")) {
      if (-not (Test-Path -LiteralPath (Join-Path $candidateRouting $name) -PathType Leaf)) {
        throw "Resumable Valhalla candidate is missing $name."
      }
    }
    docker volume inspect $candidateNominatimVolume *> $null
    Assert-NativeSuccess "Finding the resumable Nominatim volume"
    Remove-CandidateContainers

    $resumeValhallaArgs = @(
      "run", "-d", "--name", $candidateValhallaContainer,
      "--label", "terrasys.role=shared-index-candidate", "--label", "terrasys.maintenance-job=$MaintenanceJobId",
      "--memory", "4g", "--memory-swap", "5g", "--cpus", ([string][math]::Min(3, $BuildCpus)),
      "-e", "use_tiles_ignore_pbf=True", "-e", "force_rebuild=False", "-e", "build_elevation=True",
      "-e", "build_admins=True", "-e", "build_time_zones=True", "-e", "build_tar=True",
      "-e", "server_threads=3", "-e", "use_default_speeds_config=True", "-e", "TZ=Asia/Shanghai",
      "-v", "${candidateRouting}:/custom_files", "-v", "${elevationRoot}:/custom_files/elevation_data", $valhallaImage
    )
    & docker @resumeValhallaArgs | Out-Null
    Assert-NativeSuccess "Starting the resumable Valhalla candidate"
    Wait-ContainerEndpoint $candidateValhallaContainer "http://127.0.0.1:8002/status" 20 "Valhalla"
    Test-ValhallaCoverage $candidateValhallaContainer $validationPoints
    docker stop -t 30 $candidateValhallaContainer | Out-Null
    Assert-NativeSuccess "Stopping the resumable Valhalla candidate"

    $dotenv = Read-DotEnv
    if (-not $dotenv.ContainsKey("NOMINATIM_PASSWORD") -or -not $dotenv.NOMINATIM_PASSWORD) { throw "NOMINATIM_PASSWORD is missing from services/.env." }
    $resumeNominatimArgs = @(
      "run", "-d", "--name", $candidateNominatimContainer,
      "--label", "terrasys.role=shared-index-candidate", "--label", "terrasys.maintenance-job=$MaintenanceJobId",
      "--memory", "${BuildMemoryGB}g", "--memory-swap", "$($BuildMemoryGB + 1)g", "--cpus", ([string]$BuildCpus), "--shm-size", "1g",
      "-e", "PBF_PATH=/data/terrasys-core-latest.osm.pbf", "-e", "UPDATE_MODE=none", "-e", "FREEZE=true",
      "-e", "IMPORT_STYLE=extratags", "-e", "IMPORT_WIKIPEDIA=false", "-e", "THREADS=3", "-e", "GUNICORN_WORKERS=2",
      "-e", "NOMINATIM_PASSWORD=$($dotenv.NOMINATIM_PASSWORD)", "-e", "TZ=Asia/Shanghai",
      "-v", "${candidateNominatimVolume}:/var/lib/postgresql/16/main", "-v", "${capabilityRoot}:/data:ro", $nominatimImage
    )
    & docker @resumeNominatimArgs | Out-Null
    Assert-NativeSuccess "Starting the resumable Nominatim candidate"
    Wait-ContainerEndpoint $candidateNominatimContainer "http://127.0.0.1:8080/status" 20 "Nominatim"
  }
  else {
  Write-Host "Building a shared source snapshot; active services remain online..."
  & (Join-Path $PSScriptRoot "build-capability-source.ps1")
  if (-not (Test-Path -LiteralPath $capabilitySource -PathType Leaf)) { throw "The shared source snapshot was not created." }
  $validationPoints = @(Get-CapabilityValidationPoints)

  Write-Host "Building Valhalla candidate in isolation; active routing remains online..."
  & (Join-Path $PSScriptRoot "sync-elevation.ps1")
  New-Item -ItemType Directory -Force -Path $candidateRouting | Out-Null
  New-CapabilitySourceLink (Join-Path $candidateRouting "terrasys-core-latest.osm.pbf")
  $valhallaArgs = @(
    "run", "-d", "--name", $candidateValhallaContainer,
    "--label", "terrasys.role=shared-index-candidate",
    "--label", "terrasys.maintenance-job=$MaintenanceJobId",
    "--memory", "4g", "--memory-swap", "5g", "--cpus", ([string][math]::Min(3, $BuildCpus)),
    "-e", "use_tiles_ignore_pbf=False", "-e", "force_rebuild=True", "-e", "build_elevation=True",
    "-e", "build_admins=True", "-e", "build_time_zones=True", "-e", "build_tar=True",
    "-e", "server_threads=3", "-e", "use_default_speeds_config=True", "-e", "TZ=Asia/Shanghai",
    "-v", "${candidateRouting}:/custom_files", "-v", "${elevationRoot}:/custom_files/elevation_data", $valhallaImage
  )
  & docker @valhallaArgs | Out-Null
  Assert-NativeSuccess "Starting the Valhalla candidate"
  Wait-ContainerEndpoint $candidateValhallaContainer "http://127.0.0.1:8002/status" $ValhallaTimeoutMinutes "Valhalla"
  Test-ValhallaCoverage $candidateValhallaContainer $validationPoints
  if (-not (Test-Path -LiteralPath (Join-Path $candidateRouting "valhalla_tiles.tar") -PathType Leaf)) { throw "Valhalla candidate has no tile archive." }
  docker stop -t 30 $candidateValhallaContainer | Out-Null
  Assert-NativeSuccess "Stopping the validated Valhalla candidate"
  $looseTiles = Join-Path $candidateRouting "valhalla_tiles"
  if (Test-Path -LiteralPath $looseTiles -PathType Container) {
    Remove-Item -LiteralPath $looseTiles -Recurse -Force
    Write-Host "Removed regenerable loose Valhalla tiles; the validated tile archive is retained."
  }

  Write-Host "Building Nominatim candidate in an isolated, resource-limited volume; active search remains online..."
  $dotenv = Read-DotEnv
  if (-not $dotenv.ContainsKey("NOMINATIM_PASSWORD") -or -not $dotenv.NOMINATIM_PASSWORD) { throw "NOMINATIM_PASSWORD is missing from services/.env." }
  & docker volume create --label "terrasys.role=shared-index-candidate" --label "terrasys.maintenance-job=$MaintenanceJobId" $candidateNominatimVolume | Out-Null
  Assert-NativeSuccess "Creating the Nominatim candidate volume"
  $nominatimArgs = @(
    "run", "-d", "--name", $candidateNominatimContainer,
    "--label", "terrasys.role=shared-index-candidate", "--label", "terrasys.maintenance-job=$MaintenanceJobId",
    "--memory", "${BuildMemoryGB}g", "--memory-swap", "$($BuildMemoryGB + 1)g", "--cpus", ([string]$BuildCpus), "--shm-size", "1g",
    "-e", "PBF_PATH=/data/terrasys-core-latest.osm.pbf", "-e", "UPDATE_MODE=none", "-e", "FREEZE=true",
    "-e", "IMPORT_STYLE=extratags", "-e", "IMPORT_WIKIPEDIA=false", "-e", "THREADS=3", "-e", "GUNICORN_WORKERS=2",
    "-e", "NOMINATIM_PASSWORD=$($dotenv.NOMINATIM_PASSWORD)", "-e", "POSTGRES_SHARED_BUFFERS=1GB",
    "-e", "POSTGRES_MAINTENANCE_WORK_MEM=1GB", "-e", "POSTGRES_AUTOVACUUM_WORK_MEM=256MB",
    "-e", "POSTGRES_WORK_MEM=24MB", "-e", "POSTGRES_EFFECTIVE_CACHE_SIZE=4GB", "-e", "POSTGRES_MAX_WAL_SIZE=2GB",
    "-e", "TZ=Asia/Shanghai", "-v", "${candidateNominatimVolume}:/var/lib/postgresql/16/main",
    "-v", "${capabilityRoot}:/data:ro", $nominatimImage
  )
  & docker @nominatimArgs | Out-Null
  Assert-NativeSuccess "Starting the Nominatim candidate"
  Wait-ContainerEndpoint $candidateNominatimContainer "http://127.0.0.1:8080/status" $NominatimTimeoutMinutes "Nominatim"
  }

  $candidateCapabilityManifest = Get-Content -Raw -LiteralPath $capabilityManifestPath | ConvertFrom-Json

  Write-Host "Validating candidate databases before switching..."
  docker exec -u nominatim $candidateNominatimContainer nominatim admin --check-database
  Assert-NativeSuccess "Checking the Nominatim candidate database"
  foreach ($point in $validationPoints) {
    $latitude = ([double]$point.latitude).ToString([Globalization.CultureInfo]::InvariantCulture)
    $longitude = ([double]$point.longitude).ToString([Globalization.CultureInfo]::InvariantCulture)
    $response = docker exec $candidateNominatimContainer curl -fsS --max-time 20 "http://127.0.0.1:8080/reverse?lat=$latitude&lon=$longitude&format=jsonv2"
    Assert-NativeSuccess "Testing Nominatim coverage for $($point.label)"
    if (-not (($response -join "") | ConvertFrom-Json).display_name) {
      throw "Nominatim returned no result for installed map pack $($point.id) at $latitude,$longitude."
    }
  }

  Write-Host "Promoting validated candidates and switching active pointers..."
  docker rm $candidateValhallaContainer | Out-Null
  docker rm -f $candidateNominatimContainer | Out-Null
  Move-Item -LiteralPath $candidateRouting -Destination $candidateRoutingFinal
  $routingPromoted = $true
  Set-DotEnvValue "NOMINATIM_VOLUME_NAME" $candidateNominatimVolume
  Set-DotEnvValue "VALHALLA_DATA_PATH" ($candidateRoutingFinal -replace '\\', '/')
  $switchStarted = Get-Date
  Invoke-Compose @("up", "-d", "--force-recreate", "nominatim", "valhalla") "Activating the validated shared indexes"
  Wait-Healthy "terrasys-nominatim" 20
  Wait-Healthy "terrasys-valhalla" 20
  Invoke-Compose @("up", "-d", "--force-recreate", "api") "Refreshing the API index mounts"
  Wait-Healthy "terrasys-api" 10
  Invoke-Compose @("up", "-d", "--force-recreate", "web") "Refreshing the local web entry"
  Wait-Healthy "terrasys-web" 5

  $report.switched = $true
  $report.switchSeconds = [math]::Round(((Get-Date) - $switchStarted).TotalSeconds, 1)
  $report.active = [ordered]@{ nominatimVolume = $candidateNominatimVolume; valhallaPath = $candidateRoutingFinal }
  $report.success = $true
  $state = [ordered]@{
    schemaVersion = 1
    strategy = "blue-green"
    status = "active"
    activatedAt = [DateTimeOffset]::Now.ToString("o")
    active = $report.active
    previous = $report.previous
    source = $capabilitySource
    sourceSha256 = [string]$candidateCapabilityManifest.product.sha256
    inputs = @($candidateCapabilityManifest.inputs)
    lastBuildMapAvailable = $true
    switchSeconds = $report.switchSeconds
  }
  [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), $utf8)
  Write-Host "Candidate indexes are active. The old versions are retained for rollback."
}
catch {
  $report.error = $_.Exception.Message
  Write-Warning "Candidate rebuild failed. The previously active map indexes remain selected."
  Remove-CandidateContainers
  if ($report.switched -or $routingPromoted) {
    try { Restore-ActivePointers }
    catch { Write-Warning "Automatic pointer rollback also failed: $($_.Exception.Message)" }
  }
  throw
}
finally {
  $report.completedAt = [DateTimeOffset]::Now.ToString("o")
  [IO.File]::WriteAllText((Join-Path $audit "report.json"), ($report | ConvertTo-Json -Depth 8), $utf8)
}

if ($report.success) {
  try {
    & (Join-Path $PSScriptRoot "prune-shared-index-versions.ps1") -KeepPrevious 1 -ConfirmPrune | Out-Host
  }
  catch {
    Write-Warning "The new indexes are active, but obsolete-version cleanup needs attention: $($_.Exception.Message)"
  }
}
