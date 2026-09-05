[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('terrasys-operations-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$passed = [Collections.Generic.List[string]]::new()

function Assert-Operation([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Write-Archive([string]$Path, [byte]$Marker, [int]$Length = 65537) {
  $bytes = New-Object byte[] $Length
  [Text.Encoding]::ASCII.GetBytes('PMTiles').CopyTo($bytes, 0)
  $bytes[7] = $Marker
  [IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-Version([string]$Directory, [string]$Stem, [byte]$Marker) {
  $product = Join-Path $Directory "$Stem.pmtiles"
  $detailsName = "fixture.details.$Marker.pmtiles"
  $details = Join-Path $Directory $detailsName
  Write-Archive $product $Marker
  Write-Archive $details $Marker 16385
  $manifest = [ordered]@{
    schemaVersion = 3; generatedAt = '2026-01-01T00:00:00Z'
    source = @{ sha256 = "source-$Marker"; sequenceNumber = "$Marker" }
    product = @{ bytes = (Get-Item $product).Length; sha256 = (Get-FileHash $product).Hash.ToLowerInvariant() }
    details = @{ file = "products/tiles/pmtiles/$detailsName"; bytes = (Get-Item $details).Length; sha256 = (Get-FileHash $details).Hash.ToLowerInvariant() }
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Directory "$Stem.manifest.json")
}

function New-OperationFixture([string]$Name) {
  $directory = Join-Path $fixtureRoot $Name
  foreach ($relative in @('scripts', 'config/planetiler', 'raw', 'products/tiles/pmtiles', 'services', 'data/media', 'backups/sample')) {
    New-Item -ItemType Directory -Path (Join-Path $directory $relative) -Force | Out-Null
  }
  foreach ($script in @('map-version-utils.ps1', 'build-region-pack.ps1', 'build-region-details.ps1', 'write-region-manifest.ps1', 'region-pack.ps1', 'restore-terrasys.ps1', 'offline-kit-support.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repository "scripts/$script") -Destination (Join-Path $directory "scripts/$script")
  }
  Copy-Item -LiteralPath (Join-Path $repository 'config/offline-kit.json') -Destination (Join-Path $directory 'config/offline-kit.json')
  'fixture schema' | Set-Content -LiteralPath (Join-Path $directory 'config/planetiler/poi-details.yml')
  'fixture source' | Set-Content -LiteralPath (Join-Path $directory 'raw/source.pbf')
  @'
function Get-TerraSysExpandedCatalog {
  param([string]$Root)
  return [pscustomobject]@{ datasets = @([pscustomobject]@{
    id = 'fixture'; name = 'Fixture'; kind = 'region'; sourceProfileId = 'fixture'; sourceFile = 'raw/source.pbf'
    members = @(); bounds = @(0, 0, 1, 1)
    sourceProfile = [pscustomobject]@{ mode = 'direct'; snapshotFile = 'raw/source.pbf'; provider = 'fixture' }
  }) }
}
'@ | Set-Content -LiteralPath (Join-Path $directory 'scripts/catalog-utils.ps1')
  '# Fixture: shared source download is deliberately disabled.' | Set-Content -LiteralPath (Join-Path $directory 'scripts/download-planetiler-sources.ps1')
  @'
if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.fail')) { throw 'Injected migration failure' }
'@ | Set-Content -LiteralPath (Join-Path $directory 'scripts/migrate-terrasys.ps1')
  $products = Join-Path $directory 'products/tiles/pmtiles'
  Write-Version $products 'fixture' 2
  Write-Version $products 'fixture.previous' 1
  Write-Version $products 'fixture.staged' 3
  'original-media' | Set-Content -LiteralPath (Join-Path $directory 'data/media/original.txt')
  'original-database' | Set-Content -LiteralPath (Join-Path $directory 'database.state')
  $backup = Join-Path $directory 'backups/sample'
  New-Item -ItemType Directory -Path (Join-Path $backup 'media') | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $backup 'terrasys.dump'), (New-Object byte[] 2048))
  'restored-media' | Set-Content -LiteralPath (Join-Path $backup 'media/restored.txt')
  $entries = @(Get-ChildItem -LiteralPath $backup -Recurse -File | ForEach-Object {
    @{ Path = $_.FullName.Substring($backup.Length + 1).Replace('\', '/'); Bytes = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
  })
  $entries | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json')
  @'
$ErrorActionPreference = 'Stop'
$fixture = $PSScriptRoot
if (Test-Path -LiteralPath (Join-Path $fixture 'strict.mode')) { Set-StrictMode -Version Latest }
if (Test-Path -LiteralPath (Join-Path $fixture 'suspend.fail')) {
  function Get-Process { param([int]$Id, [string]$ErrorAction); throw 'Injected suspend failure' }
}
function docker {
  $arguments = @($args | ForEach-Object { [string]$_ })
  ($arguments | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Join-Path $fixture 'docker.calls')
  $global:LASTEXITCODE = 0
  if ($arguments[0] -eq 'image') { 'fixture-image'; return }
  if ($arguments -contains 'check-refs') { 'Nodes in ways missing: 0'; 'Members in relations missing: 0'; return }
  if ($arguments[0] -eq 'compose') {
    if ($arguments -contains 'ps') {
      if (Test-Path -LiteralPath (Join-Path $fixture 'compose-ps.fail')) { $global:LASTEXITCODE = 1; return }
      'api'; 'martin'
    }
    if ($arguments -contains 'stop') {
      'stopped' | Set-Content -LiteralPath (Join-Path $fixture 'services.state')
      if (Test-Path -LiteralPath (Join-Path $fixture 'compose-stop.fail')) { $global:LASTEXITCODE = 1; return }
    }
    if ($arguments -contains 'up') { 'running' | Set-Content -LiteralPath (Join-Path $fixture 'services.state') }
    return
  }
  if ($arguments[0] -eq 'cp') {
    if ($arguments[1].StartsWith('terrasys-postgis:')) { [IO.File]::WriteAllBytes($arguments[2], (New-Object byte[] 2048)) }
    return
  }
  if ($arguments -contains 'pg_restore') {
    if ($arguments -notcontains '--single-transaction') { throw 'Restore must use a single transaction' }
    $applicationNames = @($arguments | Where-Object { $_.StartsWith('PGAPPNAME=') })
    if ($applicationNames.Count -ne 1) { throw 'Every restore and recovery connection must have a recoverable application name' }
    $applicationName = $applicationNames[0].Substring('PGAPPNAME='.Length)
    $connectionPath = Join-Path $fixture 'pending.restore-connection'
    if (Test-Path -LiteralPath $connectionPath) { throw 'Previous restore connection was not terminated before replay' }
    if ($arguments[-1].EndsWith('.before.dump')) {
      $applicationName | Set-Content -LiteralPath $connectionPath
      if (Test-Path -LiteralPath (Join-Path $fixture 'recovery.pause')) { 'ready' | Set-Content -LiteralPath (Join-Path $fixture 'pause.marker'); Start-Sleep -Seconds 30 }
      'original-database' | Set-Content -LiteralPath (Join-Path $fixture 'database.state')
      Remove-Item -LiteralPath $connectionPath -Force
      return
    }
    if (Test-Path -LiteralPath (Join-Path $fixture 'database.fail')) { $global:LASTEXITCODE = 1; return }
    'restored-database' | Set-Content -LiteralPath (Join-Path $fixture 'database.state')
    if (Test-Path -LiteralPath (Join-Path $fixture 'restore.pause')) {
      $applicationName | Set-Content -LiteralPath $connectionPath
      'ready' | Set-Content -LiteralPath (Join-Path $fixture 'pause.marker')
      Start-Sleep -Seconds 30
      Remove-Item -LiteralPath $connectionPath -Force
    }
    return
  }
  if ($arguments -contains 'psql' -and $arguments[-1].Contains('pg_terminate_backend')) {
    $connectionPath = Join-Path $fixture 'pending.restore-connection'
    if (Test-Path -LiteralPath $connectionPath) {
      $applicationName = (Get-Content -Raw -LiteralPath $connectionPath).Trim()
      if (-not $arguments[-1].Contains("application_name='$applicationName'")) { throw 'Recovery did not target the interrupted restore connection' }
      $applicationName | Add-Content -LiteralPath (Join-Path $fixture 'terminated.restore-connections')
      Remove-Item -LiteralPath $connectionPath -Force
    }
    return
  }
  if ($arguments[0] -eq 'exec') { return }
  if ($arguments[0] -eq 'run') {
    $detail = $arguments -contains 'generate-custom'
    if ($detail -and (Test-Path -LiteralPath (Join-Path $fixture 'details.fail'))) { $global:LASTEXITCODE = 1; return }
    if ($detail -and (Test-Path -LiteralPath (Join-Path $fixture 'details.pause'))) { 'ready' | Set-Content -LiteralPath (Join-Path $fixture 'pause.marker'); Start-Sleep -Seconds 30 }
    $name = if ($detail) { 'fixture.details.staged.pmtiles' } else { 'fixture.staged.pmtiles' }
    $bytes = New-Object byte[] 65537
    [Text.Encoding]::ASCII.GetBytes('PMTiles').CopyTo($bytes, 0)
    $bytes[7] = 4
    [IO.File]::WriteAllBytes((Join-Path $fixture "products/tiles/pmtiles/$name"), $bytes)
    return
  }
  throw "Unexpected mocked Docker call: $($arguments -join ' ')"
}
if (Test-Path -LiteralPath (Join-Path $fixture 'media.fail')) {
  function Move-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ($LiteralPath.EndsWith('media.staged') -and -not $script:mediaFailed) { $script:mediaFailed = $true; throw 'Injected media move failure' }
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
  }
}
switch ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'mode')).Trim()) {
  'build' { & (Join-Path $fixture 'scripts/build-region-pack.ps1') -PackId fixture -MaintenanceJobId fixture }
  'rollback' { & (Join-Path $fixture 'scripts/region-pack.ps1') -Action Rollback -PackId fixture }
  'restore' { & (Join-Path $fixture 'scripts/restore-terrasys.ps1') -BackupDirectory (Join-Path $fixture 'backups/sample') }
  'recover' { & (Join-Path $fixture 'scripts/restore-terrasys.ps1') -RecoverInterrupted }
}
'@ | Set-Content -LiteralPath (Join-Path $directory 'run.ps1')
  return $directory
}

function Start-Fixture([string]$Directory, [string]$Mode, [switch]$Pause) {
  $Mode | Set-Content -LiteralPath (Join-Path $Directory 'mode')
  if ($Pause -and (Test-Path -LiteralPath (Join-Path $Directory 'pause.marker'))) {
    Remove-Item -LiteralPath (Join-Path $Directory 'pause.marker') -Force
  }
  $parameters = @{
    FilePath = (Get-Command pwsh).Source
    ArgumentList = @('-NoLogo', '-NoProfile', '-File', ('"' + (Join-Path $Directory 'run.ps1') + '"'))
    RedirectStandardOutput = Join-Path $Directory "$Mode.stdout"
    RedirectStandardError = Join-Path $Directory "$Mode.stderr"
    PassThru = $true
  }
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
  $child = Start-Process @parameters
  if ($Pause) {
    for ($attempt = 0; $attempt -lt 200; $attempt++) {
      if ((Test-Path -LiteralPath (Join-Path $Directory 'pause.marker')) -or $child.HasExited) { break }
      Start-Sleep -Milliseconds 50
      $child.Refresh()
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Directory 'pause.marker'))) {
      if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
      throw "Fixture did not reach pause point: $Directory"
    }
    Stop-Process -Id $child.Id -Force
  }
  if (-not $child.WaitForExit(15000)) { Stop-Process -Id $child.Id -Force; throw "Fixture timed out: $Directory" }
  $child.Refresh()
  return $child.ExitCode
}

function Version-Hashes([string]$Directory) {
  return @('fixture.pmtiles', 'fixture.manifest.json', 'fixture.previous.pmtiles', 'fixture.previous.manifest.json') | ForEach-Object {
    (Get-FileHash -LiteralPath (Join-Path $Directory "products/tiles/pmtiles/$_")).Hash
  }
}

function Start-FixtureWorker([string]$Directory) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Directory 'data/maintenance') | Out-Null
  @'
$fixture = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $fixture 'data/maintenance/worker.json'
if (Test-Path -LiteralPath (Join-Path $fixture 'worker.was-stopped')) {
  'resumed' | Set-Content -LiteralPath (Join-Path $fixture 'worker.resumed')
  return
}
@{ status = 'running'; pid = $PID } | ConvertTo-Json | Set-Content -LiteralPath $statePath
while (-not (Test-Path -LiteralPath (Join-Path $fixture 'data/maintenance/stop.request'))) { Start-Sleep -Milliseconds 50 }
'stopped' | Set-Content -LiteralPath (Join-Path $fixture 'worker.was-stopped')
@{ status = 'stopped'; pid = $PID } | ConvertTo-Json | Set-Content -LiteralPath $statePath
'@ | Set-Content -LiteralPath (Join-Path $Directory 'scripts/maintenance-worker.ps1')
  $parameters = @{
    FilePath = (Get-Command pwsh).Source
    ArgumentList = @('-NoProfile', '-File', ('"' + (Join-Path $Directory 'scripts/maintenance-worker.ps1') + '"'))
    PassThru = $true
  }
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
  $worker = Start-Process @parameters
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if (Test-Path -LiteralPath (Join-Path $Directory 'data/maintenance/worker.json')) { return $worker }
    Start-Sleep -Milliseconds 50
  }
  Stop-Process -Id $worker.Id -Force
  throw 'Fixture worker did not become ready'
}

function Assert-WorkerResumed([string]$Directory) {
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if (Test-Path -LiteralPath (Join-Path $Directory 'worker.resumed')) { return }
    Start-Sleep -Milliseconds 50
  }
  throw "Fixture worker was not resumed: $Directory"
}

try {
  foreach ($scenario in @('details-failure', 'details-cancel')) {
    $fixture = New-OperationFixture $scenario
    $before = (Version-Hashes $fixture) -join ','
    $flag = if ($scenario -eq 'details-failure') { 'details.fail' } else { 'details.pause' }
    'true' | Set-Content -LiteralPath (Join-Path $fixture $flag)
    $exitCode = Start-Fixture $fixture build -Pause:($scenario -eq 'details-cancel')
    Assert-Operation ($exitCode -ne 0) "$scenario unexpectedly succeeded"
    Assert-Operation (((Version-Hashes $fixture) -join ',') -eq $before) "$scenario modified an active or previous version"
    Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $fixture 'products/tiles/pmtiles/fixture.activation.json'))) "$scenario published an incomplete candidate"
    $passed.Add($scenario)
  }

  $fixture = New-OperationFixture 'build-success'
  Assert-Operation ((Start-Fixture $fixture build) -eq 0) "Build failed; inspect $fixture"
  . (Join-Path $repository 'scripts/map-version-utils.ps1')
  $products = Join-Path $fixture 'products/tiles/pmtiles'
  $null = Assert-TerraSysMapVersion $products (Join-Path $products 'fixture.pmtiles') (Join-Path $products 'fixture.manifest.json')
  $null = Assert-TerraSysMapVersion $products (Join-Path $products 'fixture.previous.pmtiles') (Join-Path $products 'fixture.previous.manifest.json')
  $previousBeforeRefresh = (Get-FileHash -LiteralPath (Join-Path $products 'fixture.previous.manifest.json')).Hash
  Assert-Operation ((Start-Fixture $fixture build) -eq 0) 'Identical candidate refresh failed'
  Assert-Operation ((Get-FileHash -LiteralPath (Join-Path $products 'fixture.previous.manifest.json')).Hash -eq $previousBeforeRefresh) 'Identical refresh discarded the earlier rollback version'
  Assert-Operation ((Start-Fixture $fixture rollback) -eq 0) "Successful version rollback failed; inspect $fixture"
  $passed.Add('complete-build-and-rollback')

  foreach ($failurePoint in 1..4) {
    $fixture = New-OperationFixture "rollback-failure-$failurePoint"
    $products = Join-Path $fixture 'products/tiles/pmtiles'
    $before = (Version-Hashes $fixture) -join ','
    & {
      $script:moves = 0
      function Move-Item {
        param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        if ($LiteralPath -match '\.activation-[a-f0-9]{32}\.tmp$') {
          $script:moves++
          if ($script:moves -eq $failurePoint) { throw 'Injected activation replacement failure' }
        }
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
      }
      $lock = Enter-TerraSysMapLock $products fixture
      try {
        $failed = $false
        try { Invoke-TerraSysMapActivation $products fixture -Rollback } catch { $failed = $true }
        Assert-Operation $failed 'Injected rollback failure was not observed'
      }
      finally { $lock.Dispose() }
    }
    Assert-Operation (((Version-Hashes $fixture) -join ',') -eq $before) "Rollback failure at $failurePoint mixed map versions"
    Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $products 'fixture.activation.json'))) 'Recovered rollback left its journal active'
    $passed.Add("rollback-failure-$failurePoint")
  }

  $fixture = New-OperationFixture 'commit-cancel-recovery'
  @'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/map-version-utils.ps1')
$products = Join-Path $PSScriptRoot 'products/tiles/pmtiles'
$script:moves = 0
function Move-Item {
  param([string]$LiteralPath, [string]$Destination, [switch]$Force)
  Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
  if ($LiteralPath -match '\.activation-[a-f0-9]{32}\.tmp$') {
    $script:moves++
    if ($script:moves -eq 3) { 'ready' | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'pause.marker'); Start-Sleep -Seconds 30 }
  }
}
$lock = Enter-TerraSysMapLock $products fixture
try { Invoke-TerraSysMapActivation $products fixture (Join-Path $products 'fixture.staged.pmtiles') (Join-Path $products 'fixture.staged.manifest.json') }
finally { $lock.Dispose() }
'@ | Set-Content -LiteralPath (Join-Path $fixture 'run.ps1')
  $before = (Version-Hashes $fixture) -join ','
  $null = Start-Fixture $fixture commit -Pause
  $products = Join-Path $fixture 'products/tiles/pmtiles'
  Assert-Operation (Test-Path -LiteralPath (Join-Path $products 'fixture.activation.json')) 'Killed commit lost its recovery journal'
  # Recovery itself fails after replacing one file, then resumes from the same
  # immutable snapshots on the next invocation.
  & {
    $script:recoveryMoves = 0
    function Move-Item {
      param([string]$LiteralPath, [string]$Destination, [switch]$Force)
      Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
      if ($LiteralPath -match '\.activation-[a-f0-9]{32}\.tmp$' -and ++$script:recoveryMoves -eq 1) { throw 'Injected recovery interruption' }
    }
    try { Repair-TerraSysMapActivations $products fixture } catch { }
  }
  Assert-Operation (Test-Path -LiteralPath (Join-Path $products 'fixture.activation.json')) 'Failed recovery erased its journal'
  Repair-TerraSysMapActivations $products fixture
  Repair-TerraSysMapActivations $products fixture
  Assert-Operation (((Version-Hashes $fixture) -join ',') -eq $before) 'Interrupted commit recovery did not restore both original versions'
  $passed.Add('commit-cancel-and-idempotent-recovery')

  foreach ($scenario in @('suspend', 'compose-ps', 'compose-stop')) {
    $fixture = New-OperationFixture "restore-early-$scenario-failure"
    'true' | Set-Content -LiteralPath (Join-Path $fixture 'strict.mode')
    'true' | Set-Content -LiteralPath (Join-Path $fixture "$scenario.fail")
    if ($scenario -eq 'suspend') {
      New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'data/maintenance') | Out-Null
      @{ status = 'running'; pid = 1234 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'data/maintenance/worker.json')
    }
    Assert-Operation ((Start-Fixture $fixture restore) -ne 0) "Early $scenario failure unexpectedly succeeded"
    $errorText = Get-Content -Raw -LiteralPath (Join-Path $fixture 'restore.stderr')
    $expectedError = switch ($scenario) {
      'suspend' { 'Injected suspend failure' }
      'compose-ps' { 'Inspecting services before restore failed with exit code 1' }
      'compose-stop' { 'Stopping API and Martin failed with exit code 1' }
    }
    Assert-Operation ($errorText.Contains($expectedError)) "Finally masked the original $scenario error: $errorText"
    Assert-Operation ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'database.state')).Trim() -eq 'original-database') "Early $scenario failure changed the database"
    Assert-Operation (Test-Path -LiteralPath (Join-Path $fixture 'data/media/original.txt')) "Early $scenario failure changed original media"
    Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $fixture 'data/restore-recovery/active.json'))) "Early $scenario failure published restore state"
    $callsPath = Join-Path $fixture 'docker.calls'
    if (Test-Path -LiteralPath $callsPath) {
      $callsText = Get-Content -Raw -LiteralPath $callsPath
      Assert-Operation ($callsText -notmatch 'pg_dump|pg_restore') "Early $scenario failure still attempted database mutation"
    }
    if ($scenario -eq 'compose-stop') {
      Assert-Operation ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'services.state')).Trim() -eq 'running') 'A partial stop failure did not resume originally running services'
    }
    $passed.Add("restore-early-$scenario-failure")
  }

  foreach ($scenario in @('database', 'media', 'migration')) {
    $fixture = New-OperationFixture "restore-$scenario-failure"
    'true' | Set-Content -LiteralPath (Join-Path $fixture "$scenario.fail")
    Assert-Operation ((Start-Fixture $fixture restore) -ne 0) "Restore $scenario failure unexpectedly succeeded"
    Assert-Operation ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'database.state')).Trim() -eq 'original-database') "Restore $scenario failure changed the database"
    Assert-Operation (Test-Path -LiteralPath (Join-Path $fixture 'data/media/original.txt')) "Restore $scenario failure lost original media"
    Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $fixture 'data/media/restored.txt'))) "Restore $scenario failure left mixed media"
    Assert-Operation ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'services.state')).Trim() -eq 'running') "Restore $scenario failure did not resume services"
    Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $fixture 'data/restore-recovery/active.json'))) "Restore $scenario failure left a recovered journal"
    $passed.Add("restore-$scenario-failure")
  }
  $fixture = New-OperationFixture 'restore-success'
  Assert-Operation ((Start-Fixture $fixture restore) -eq 0) "Restore success failed; inspect $fixture"
  Assert-Operation (Test-Path -LiteralPath (Join-Path $fixture 'data/media/restored.txt')) 'Restored media is absent'
  Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $fixture 'data/media/original.txt'))) 'Successful restore merged obsolete media'
  $passed.Add('restore-success-exact-media')

  $fixture = New-OperationFixture 'restore-interrupted'
  $fixtureWorker = Start-FixtureWorker $fixture
  'true' | Set-Content -LiteralPath (Join-Path $fixture 'restore.pause')
  try {
    $null = Start-Fixture $fixture restore -Pause
    Assert-Operation (Test-Path -LiteralPath (Join-Path $fixture 'data/restore-recovery/active.json')) 'Interrupted restore lacks recovery state'
    $interruptedState = Get-Content -Raw -LiteralPath (Join-Path $fixture 'data/restore-recovery/active.json') | ConvertFrom-Json
    Assert-Operation ([bool]$interruptedState.workerWasRunning) 'Interrupted restore lost the original worker state'
    'true' | Set-Content -LiteralPath (Join-Path $fixture 'recovery.pause')
    $null = Start-Fixture $fixture recover -Pause
    Assert-Operation (Test-Path -LiteralPath (Join-Path $fixture 'data/restore-recovery/active.json')) 'Interrupted recovery erased the recovery journal'
    Assert-Operation ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'pending.restore-connection')).Trim() -eq "terrasys-restore-$($interruptedState.id)") 'Safety-dump replay used an untracked connection'
    Remove-Item -LiteralPath (Join-Path $fixture 'recovery.pause') -Force
    Assert-Operation ((Start-Fixture $fixture recover) -eq 0) "Interrupted restore recovery failed; inspect $fixture"
    Assert-Operation ((Get-Content -Raw -LiteralPath (Join-Path $fixture 'database.state')).Trim() -eq 'original-database') 'Interrupted restore did not recover the original database'
    Assert-Operation (Test-Path -LiteralPath (Join-Path $fixture 'data/media/original.txt')) 'Interrupted restore did not recover original media'
    $terminated = @(Get-Content -LiteralPath (Join-Path $fixture 'terminated.restore-connections'))
    Assert-Operation ($terminated.Count -eq 2 -and @($terminated | Where-Object { $_ -ne "terrasys-restore-$($interruptedState.id)" }).Count -eq 0) 'Repeated recovery did not terminate both interrupted connections before replay'
    Assert-Operation (-not (Test-Path -LiteralPath (Join-Path $fixture 'pending.restore-connection'))) 'Successful recovery left an active restore connection'
    Assert-WorkerResumed $fixture
  }
  finally { if (-not $fixtureWorker.HasExited) { Stop-Process -Id $fixtureWorker.Id -Force } }
  $passed.Add('restore-and-recovery-interrupted-twice')

  [pscustomobject]@{ Status = 'passed'; Cases = $passed.Count; Passed = @($passed); Fixtures = $fixtureRoot } | ConvertTo-Json -Depth 4
}
catch {
  Write-Host "Reliability fixtures retained for diagnosis: $fixtureRoot"
  throw
}
