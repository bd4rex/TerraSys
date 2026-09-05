[CmdletBinding(DefaultParameterSetName = 'Restore')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Restore')][string]$BackupDirectory,
  [Parameter(Mandatory = $true, ParameterSetName = 'Recover')][switch]$RecoverInterrupted
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "map-version-utils.ps1")
$recoveryRoot = Join-Path $root "data\restore-recovery"
$recoveryState = Join-Path $recoveryRoot 'active.json'
$mediaRoot = Join-Path $root "data\media"
$services = Join-Path $root 'services'
$maintenanceRoot = Join-Path $root 'data\maintenance'
$workerStopRequest = Join-Path $maintenanceRoot 'stop.request'
$workerStatePath = Join-Path $maintenanceRoot 'worker.json'
$workerResume = $false
New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
$restoreLock = [IO.File]::Open((Join-Path $recoveryRoot 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Suspend-RestoreWorker {
  $alreadyRequested = Test-Path -LiteralPath $workerStopRequest
  if (-not (Test-Path -LiteralPath $workerStatePath -PathType Leaf)) { return $false }
  $worker = Get-Content -Raw -LiteralPath $workerStatePath | ConvertFrom-Json
  if ($worker.status -ne 'running') { return $false }
  $workerProcess = Get-Process -Id ([int]$worker.pid) -ErrorAction SilentlyContinue
  if (-not $workerProcess) { return $false }
  [IO.File]::WriteAllText($workerStopRequest, [DateTimeOffset]::Now.ToString('o'))
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    if (-not (Get-Process -Id ([int]$worker.pid) -ErrorAction SilentlyContinue)) { return (-not $alreadyRequested) }
    $latest = Get-Content -Raw -LiteralPath $workerStatePath | ConvertFrom-Json
    if ($latest.status -ne 'running') { return (-not $alreadyRequested) }
    Start-Sleep -Seconds 1
  }
  throw 'The maintenance worker did not stop; no personal-data restore was started.'
}

function Resume-RestoreWorker {
  if (Test-Path -LiteralPath $workerStopRequest) { Remove-Item -LiteralPath $workerStopRequest -Force }
  $executable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
  $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + (Join-Path $PSScriptRoot 'maintenance-worker.ps1') + '"'))
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'maintenance-worker.ps1') + '"')) }
  $parameters = @{ FilePath = $executable; ArgumentList = $arguments }
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
  else {
    $parameters.RedirectStandardOutput = Join-Path $maintenanceRoot 'worker-console.log'
    $parameters.RedirectStandardError = Join-Path $maintenanceRoot 'worker-error.log'
  }
  Start-Process @parameters | Out-Null
}

function Restore-OriginalPersonalData([object]$State, [string]$Work) {
  $originalMedia = Join-Path $Work 'media.original'
  if ($State.databaseAttempted) {
    # A killed host-side docker client may leave pg_restore running in the
    # container. End only this restore's connection before replaying its safety dump.
    docker exec terrasys-postgis psql -v ON_ERROR_STOP=1 -U gis -d terrasys -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='terrasys-restore-$($State.id)' AND pid<>pg_backend_pid()" | Out-Host
    Assert-NativeSuccess 'Stopping an interrupted restore connection'
    $safetyDump = Join-Path $Work 'before.dump'
    if (-not (Test-Path -LiteralPath $safetyDump -PathType Leaf)) { throw "Restore safety dump is missing: $safetyDump" }
    docker cp $safetyDump "terrasys-postgis:/tmp/terrasys-restore-$($State.id).before.dump"
    Assert-NativeSuccess 'Copying the restore safety dump'
    docker exec -e "PGAPPNAME=terrasys-restore-$($State.id)" terrasys-postgis pg_restore -U gis -d terrasys --single-transaction --clean --if-exists --no-owner "/tmp/terrasys-restore-$($State.id).before.dump" | Out-Host
    Assert-NativeSuccess 'Restoring the previous personal database'
  }
  if ($State.originalMediaExists) {
    if (Test-Path -LiteralPath $originalMedia -PathType Container) {
      $restoredMedia = Join-Path $Work ("media.recover-" + [Guid]::NewGuid().ToString('N'))
      Copy-Item -LiteralPath $originalMedia -Destination $restoredMedia -Recurse -Force
      if (Test-Path -LiteralPath $mediaRoot) { Move-Item -LiteralPath $mediaRoot -Destination (Join-Path $Work ("media.failed-" + [Guid]::NewGuid().ToString('N'))) }
      Move-Item -LiteralPath $restoredMedia -Destination $mediaRoot
    }
    elseif ($State.databaseAttempted -or -not (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
      throw 'The original media snapshot is missing; recovery requires manual attention.'
    }
  }
  elseif (Test-Path -LiteralPath $mediaRoot) {
    Move-Item -LiteralPath $mediaRoot -Destination (Join-Path $Work ("media.failed-" + [Guid]::NewGuid().ToString('N')))
  }
}

try {
if ($RecoverInterrupted) {
  if (-not (Test-Path -LiteralPath $recoveryState -PathType Leaf)) { throw 'No interrupted personal-data restore needs recovery.' }
  $state = Get-Content -Raw -LiteralPath $recoveryState | ConvertFrom-Json
  if ($state.schemaVersion -ne 1 -or $state.id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid restore recovery journal; preserve it for manual recovery.' }
  $work = Join-Path $recoveryRoot ([string]$state.id)
  Push-Location $services
  try {
    $recoveryWorkerWasRunning = Suspend-RestoreWorker
    if ($recoveryWorkerWasRunning) {
      $state | Add-Member -NotePropertyName workerWasRunning -NotePropertyValue $true -Force
      Write-TerraSysMapJournal -Path $recoveryState -Journal $state
    }
    docker compose up -d postgis | Out-Host
    Assert-NativeSuccess 'Starting PostgreSQL for interrupted-restore recovery'
    $databaseReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
      docker exec terrasys-postgis pg_isready -h 127.0.0.1 -U gis -d terrasys *> $null
      if ($LASTEXITCODE -eq 0) { $databaseReady = $true; break }
      Start-Sleep -Seconds 1
    }
    if (-not $databaseReady) { throw 'PostgreSQL did not become ready for recovery; restore journal retained.' }
    docker compose stop api martin | Out-Host
    Assert-NativeSuccess 'Stopping readers for restore recovery'
    Restore-OriginalPersonalData -State $state -Work $work
    Remove-Item -LiteralPath $recoveryState -Force
    $restart = @($state.runningServices | Where-Object { $_ -in @('api', 'martin') })
    if ($restart.Count) { docker compose up -d --force-recreate @restart | Out-Host; Assert-NativeSuccess 'Restarting recovered services' }
    if ($state.workerWasRunning) { Resume-RestoreWorker }
  }
  finally { Pop-Location }
  Write-Host "Interrupted restore rolled back. Safety checkpoint retained at $work"
  return
}
if (Test-Path -LiteralPath $recoveryState) { throw 'An earlier restore was interrupted. Run this script with -RecoverInterrupted first.' }
$backupRoot = (Resolve-Path (Join-Path $root "backups")).Path.TrimEnd([char[]]@('\', '/'))
$target = (Resolve-Path $BackupDirectory).Path

$pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$pathPrefix = $backupRoot + [IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($pathPrefix, $pathComparison)) {
  throw "BackupDirectory must be inside $backupRoot"
}

$dump = Join-Path $target "terrasys.dump"
if (-not (Test-Path -LiteralPath $dump -PathType Leaf)) {
  $legacyDump = Join-Path $target "personal_gis.dump"
  if (Test-Path -LiteralPath $legacyDump -PathType Leaf) { $dump = $legacyDump }
}
$manifest = Join-Path $target "manifest.json"
$mediaBackup = Join-Path $target "media"
if (-not (Test-Path $dump) -or -not (Test-Path $manifest)) {
  throw "The backup is incomplete."
}

$parsedManifest = Get-Content -Raw $manifest | ConvertFrom-Json
$entries = @($parsedManifest)
if ($entries.Count -eq 0) {
  throw "The backup manifest is empty."
}
foreach ($entry in $entries) {
  $relative = ([string]$entry.Path).Replace('\', '/')
  if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)') {
    throw "Unsafe path in backup manifest: $relative"
  }
  $file = Join-Path $target $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
    throw "Backup file is missing: $relative"
  }
  $resolvedFile = (Resolve-Path -LiteralPath $file).Path
  if (-not $resolvedFile.StartsWith($target.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar, $pathComparison)) {
    throw "Backup file resolves outside the selected directory: $relative"
  }
  if ((Get-Item -LiteralPath $resolvedFile).Length -ne [int64]$entry.Bytes) {
    throw "Backup size verification failed: $relative"
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedFile).Hash.ToLowerInvariant()
  if ($actual -ne ([string]$entry.SHA256).ToLowerInvariant()) {
    throw "Backup checksum verification failed: $relative"
  }
}

# Only manifest-listed files are staged. An empty backup media set intentionally
# restores an empty directory rather than retaining unrelated current uploads.
if (-not @($entries | Where-Object { ([string]$_.Path).Replace('\', '/') -eq [IO.Path]::GetFileName($dump) }).Count) {
  throw 'The database dump is not covered by the backup checksum manifest.'
}
$restoreId = [Guid]::NewGuid().ToString('N')
$work = Join-Path $recoveryRoot $restoreId
$stagedMedia = Join-Path $work 'media.staged'
New-Item -ItemType Directory -Force -Path $stagedMedia | Out-Null
foreach ($entry in $entries) {
  $relative = ([string]$entry.Path).Replace('\', '/')
  if (-not $relative.StartsWith('media/', [StringComparison]::Ordinal)) { continue }
  $destination = Join-Path $stagedMedia $relative.Substring(6)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath (Join-Path $target $relative) -Destination $destination -Force
}

Push-Location $services
$state = $null
$servicesStopped = $false
$safeToRestart = $true
$runningServices = @()
$safetyContainerPath = $null
$restoreContainerPath = $null
try {
  $workerResume = Suspend-RestoreWorker
  $runningServices = @(docker compose ps --status running --services | Where-Object { $_ -in @('api', 'martin') })
  Assert-NativeSuccess 'Inspecting services before restore'
  docker compose stop api martin | Out-Host
  $servicesStopped = $true
  Assert-NativeSuccess "Stopping API and Martin"
  $safetyContainerPath = "/tmp/terrasys-restore-$restoreId.before.dump"
  $restoreContainerPath = "/tmp/terrasys-restore-$restoreId.dump"
  docker exec terrasys-postgis pg_dump -U gis -d terrasys -Fc -f $safetyContainerPath
  Assert-NativeSuccess 'Creating the restore safety checkpoint'
  docker cp "terrasys-postgis:$safetyContainerPath" (Join-Path $work 'before.dump')
  Assert-NativeSuccess 'Saving the restore safety checkpoint'
  if ((Get-Item -LiteralPath (Join-Path $work 'before.dump')).Length -lt 1024) { throw 'The restore safety dump is unexpectedly small.' }
  docker cp $dump "terrasys-postgis:$restoreContainerPath"
  Assert-NativeSuccess "Copying the restore dump"
  $state = [ordered]@{ schemaVersion = 1; id = $restoreId; originalMediaExists = (Test-Path -LiteralPath $mediaRoot -PathType Container); runningServices = $runningServices; workerWasRunning = $workerResume; databaseAttempted = $false }
  Write-TerraSysMapJournal -Path $recoveryState -Journal $state
  if ($state.originalMediaExists) { Move-Item -LiteralPath $mediaRoot -Destination (Join-Path $work 'media.original') }
  Move-Item -LiteralPath $stagedMedia -Destination $mediaRoot
  $state.databaseAttempted = $true
  Write-TerraSysMapJournal -Path $recoveryState -Journal $state
  docker exec -e "PGAPPNAME=terrasys-restore-$restoreId" terrasys-postgis pg_restore -U gis -d terrasys --single-transaction --clean --if-exists --no-owner $restoreContainerPath | Out-Host
  $restoreExit = $LASTEXITCODE
  if ($restoreExit -ne 0) {
    # A nonzero Docker-client result can also mean a lost connection after the
    # server committed. Conservatively replay the safety dump before old media.
    throw "Restoring PostgreSQL failed with exit code $restoreExit."
  }
  & (Join-Path $PSScriptRoot "migrate-terrasys.ps1")
  Remove-Item -LiteralPath $recoveryState -Force
  docker compose up -d --force-recreate api martin web | Out-Host
  Assert-NativeSuccess "Restarting API, Martin, and web"
}
catch {
  $restoreError = $_
  if (Test-Path -LiteralPath $recoveryState -PathType Leaf) {
    try {
      Restore-OriginalPersonalData -State $state -Work $work
      Remove-Item -LiteralPath $recoveryState -Force
    }
    catch {
      $safeToRestart = $false
      throw "Restore failed and automatic recovery needs attention. Services remain stopped; run -RecoverInterrupted. Checkpoint: $work. $($_.Exception.Message)"
    }
  }
  throw $restoreError
}
finally {
  try {
    if ($servicesStopped -and $safeToRestart -and -not (Test-Path -LiteralPath $recoveryState) -and @($runningServices).Count) {
      docker compose up -d @runningServices | Out-Host
      Assert-NativeSuccess 'Restoring the previous service availability'
    }
    foreach ($temporaryDump in @($safetyContainerPath, $restoreContainerPath)) {
      if ($temporaryDump) { docker exec terrasys-postgis rm -f $temporaryDump 2>$null }
    }
    if ($workerResume -and $safeToRestart -and -not (Test-Path -LiteralPath $recoveryState)) { Resume-RestoreWorker }
  }
  finally { Pop-Location }
}

Write-Host "Restore completed from $target"
Write-Host "Previous personal data retained at $work"
}
finally { $restoreLock.Dispose() }
