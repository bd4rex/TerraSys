[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot "scripts/offline-kit-support.ps1")
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("terrasys-kit-test-" + [Guid]::NewGuid().ToString("N"))
$utf8 = [Text.UTF8Encoding]::new($false)
$assertions = 0

function Assert-KitTest([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:assertions++
}

function Write-FixtureFile([string]$Path, [string]$Content = "fixture") {
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  [IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Write-KitManifest([string]$Kit) {
  $entries = @(Get-ChildItem -LiteralPath $Kit -Recurse -File | Where-Object {
    $_.Name -notin @("manifest.json", "verification.json", "verification.json.tmp")
  } | ForEach-Object {
    [ordered]@{
      Path = $_.FullName.Substring($Kit.Length + 1).Replace('\', '/')
      Bytes = $_.Length
      SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  })
  Write-FixtureFile (Join-Path $Kit "manifest.json") (ConvertTo-Json -InputObject $entries -Depth 6)
}

try {
  $fixtureRoot = Join-Path $testRoot "source"
  $contract = Get-TerraSysOfflineKitContract -Root $repositoryRoot
  foreach ($directory in $contract.projectDirectories) {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force | Out-Null
  }
  foreach ($relative in @($contract.requiredFiles) + @($contract.rootFiles)) {
    Write-FixtureFile (Join-Path $fixtureRoot $relative)
  }
  Copy-Item -LiteralPath (Join-Path $repositoryRoot "config/offline-kit.json") -Destination (Join-Path $fixtureRoot "config/offline-kit.json") -Force
  foreach ($name in @("offline-kit-support.ps1", "refresh-offline-kit.ps1", "verify-offline-kit.ps1", "restore-offline-kit.ps1")) {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts/$name") -Destination (Join-Path $fixtureRoot "scripts/$name") -Force
  }
  Write-FixtureFile (Join-Path $fixtureRoot "docs/OFFLINE_RECOVERY.md")
  Write-FixtureFile (Join-Path $fixtureRoot "services/.env") "POSTGRES_PASSWORD=fixture-only"
  Write-FixtureFile (Join-Path $fixtureRoot "services/api/app/__pycache__/ignored.pyc")
  $kit = Join-Path $fixtureRoot "offline-kit/test-kit"
  $payload = Join-Path $kit "payload/TerraSys"
  Copy-TerraSysOfflineProject -Root $fixtureRoot -Destination $payload
  foreach ($relative in $contract.requiredFiles) {
    Assert-KitTest (Test-Path -LiteralPath (Join-Path $payload $relative) -PathType Leaf) "Missing required copied file: $relative"
  }
  Assert-KitTest (-not (Test-Path -LiteralPath (Join-Path $payload "services/.env"))) "Project credentials were copied."
  Assert-KitTest (-not (Test-Path -LiteralPath (Join-Path $payload "services/api/app/__pycache__/ignored.pyc"))) "Python cache was copied."
  $images = @(Get-TerraSysOfflineKitImages -Root $fixtureRoot)
  Assert-KitTest ($images -contains (Get-TerraSysToolImage -Root $fixtureRoot -Name planetiler)) "Packaged Planetiler differs from build dependency."
  Assert-KitTest (-not @($images | Where-Object { $_ -match ':latest$' }).Count) "Mutable latest image found in kit."
  Assert-KitTest ($images -contains [string]$contract.images.osmCarto) "Carto image missing from refresh image inventory."
  $nominatimDigest = ([string]$contract.images.nominatim).Split('@')[1]
  Write-FixtureFile (Join-Path $fixtureRoot "services/.env") "NOMINATIM_IMAGE=$nominatimDigest"
  Assert-KitTest (@(Get-TerraSysOfflineKitImages -Root $fixtureRoot) -contains $nominatimDigest) "Approved digest-only recovery reference was rejected."
  Write-FixtureFile (Join-Path $fixtureRoot "services/.env") "NOMINATIM_IMAGE=untrusted:latest"
  $rejected = $false
  try { Get-TerraSysOfflineKitImages -Root $fixtureRoot | Out-Null } catch { $rejected = $true }
  Assert-KitTest $rejected "Mismatched image override was accepted."
  Write-FixtureFile (Join-Path $fixtureRoot "services/.env") "POSTGRES_PASSWORD=fixture-only"
  Write-FixtureFile (Join-Path $kit "kit-info.json") (@{
    schemaVersion = 5; advancedCapabilities = $false; operationalResources = @(); includesDockerImages = $false
    nominatimIndexIncluded = $false; osmCartoIncluded = $false
  } | ConvertTo-Json)
  Write-KitManifest $kit
  $verify = Join-Path $repositoryRoot "scripts/verify-offline-kit.ps1"
  $result = & $verify -KitDirectory $kit
  Assert-KitTest $result.ProjectComplete "Complete project was not marked project-complete."
  Assert-KitTest (-not $result.RebuildReady) "A project without Docker images was marked rebuild-ready."
  $missing = Join-Path $payload "config/planetiler/poi-details.yml"
  Remove-Item -LiteralPath $missing -Force
  Write-KitManifest $kit
  $rejected = $false
  try { & $verify -KitDirectory $kit | Out-Null } catch { $rejected = $_.Exception.Message -match "poi-details.yml" }
  Assert-KitTest $rejected "Hash-consistent kit missing rebuild input was accepted."
  Write-FixtureFile $missing
  Write-KitManifest $kit
  & $verify -KitDirectory $kit | Out-Null
  # Run the actual refresh twice: verification.json must never hash itself into the next manifest.
  & (Join-Path $fixtureRoot "scripts/refresh-offline-kit.ps1") -KitDirectory $kit -SkipDockerImages | Out-Null
  & (Join-Path $fixtureRoot "scripts/refresh-offline-kit.ps1") -KitDirectory $kit -SkipDockerImages | Out-Null
  $result = & $verify -KitDirectory $kit
  Assert-KitTest $result.ProjectComplete "Repeated refresh broke project verification."
  Assert-KitTest (-not $result.RebuildReady) "Repeated refresh claimed missing images were present."
  $entries = Get-Content -Raw -LiteralPath (Join-Path $kit "manifest.json") | ConvertFrom-Json
  Assert-KitTest (-not ($entries.Path -contains "verification.json")) "Ephemeral verification receipt was included in manifest."

  # The archive bytes are a fixture: these tests validate declared image coverage,
  # not docker load or the contents of a real image tar archive.
  $archive = Join-Path $kit "docker/terrasys-images.tar"
  Write-FixtureFile $archive "old-image-archive-fixture"
  $infoPath = Join-Path $kit "kit-info.json"
  $info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
  $info.schemaVersion = 4
  $info.includesDockerImages = $true
  $info | Add-Member -NotePropertyName dockerImages -NotePropertyValue @("legacy/planetiler:latest") -Force
  Write-FixtureFile $infoPath ($info | ConvertTo-Json -Depth 8)
  Write-KitManifest $kit
  $legacy = & $verify -KitDirectory $kit
  Assert-KitTest (-not $legacy.ProjectComplete) "A legacy kit claimed project completeness."
  Assert-KitTest (-not $legacy.RebuildReady) "A legacy kit claimed rebuild readiness."

  $beforeInfoHash = (Get-FileHash -LiteralPath $infoPath -Algorithm SHA256).Hash
  $beforeManifestHash = (Get-FileHash -LiteralPath (Join-Path $kit "manifest.json") -Algorithm SHA256).Hash
  $payloadBuildScript = Join-Path $payload "scripts/build-region-details.ps1"
  $beforePayloadHash = (Get-FileHash -LiteralPath $payloadBuildScript -Algorithm SHA256).Hash
  Write-FixtureFile (Join-Path $fixtureRoot "scripts/build-region-details.ps1") "new-source-that-must-not-be-copied"
  $rejected = $false
  try { & (Join-Path $fixtureRoot "scripts/refresh-offline-kit.ps1") -KitDirectory $kit -SkipDockerImages | Out-Null }
  catch { $rejected = $_.Exception.Message -match "Cannot skip Docker image refresh" }
  Assert-KitTest $rejected "Refresh upgraded an old image inventory while skipping Docker images."
  Assert-KitTest ((Get-FileHash -LiteralPath $infoPath -Algorithm SHA256).Hash -eq $beforeInfoHash) "Rejected refresh changed kit metadata."
  Assert-KitTest ((Get-FileHash -LiteralPath (Join-Path $kit "manifest.json") -Algorithm SHA256).Hash -eq $beforeManifestHash) "Rejected refresh changed the kit manifest."
  Assert-KitTest ((Get-FileHash -LiteralPath $payloadBuildScript -Algorithm SHA256).Hash -eq $beforePayloadHash) "Rejected refresh copied new project files."

  $info.schemaVersion = 5
  Write-FixtureFile $infoPath ($info | ConvertTo-Json -Depth 8)
  Write-KitManifest $kit
  $rejected = $false
  try { & $verify -KitDirectory $kit | Out-Null }
  catch { $rejected = $_.Exception.Message -match "Docker image inventory is incomplete" }
  Assert-KitTest $rejected "Schema 5 accepted a hash-consistent archive with obsolete image metadata."

  $approvedImages = @($contract.images.PSObject.Properties | ForEach-Object {
    if ($_.Name -eq "nominatim") { ([string]$_.Value).Split('@')[1] }
    elseif ($_.Name -eq "osmCarto") { "mirror.example/osm-carto@$(([string]$_.Value).Split('@')[1])" }
    else { [string]$_.Value }
  })
  Assert-KitTest (@(Get-TerraSysOfflineKitMissingImages -Contract $contract -Images $approvedImages).Count -eq 0) "Approved digest aliases failed the shared image inventory check."
  $info.dockerImages = $approvedImages
  Write-FixtureFile $infoPath ($info | ConvertTo-Json -Depth 8)
  Write-KitManifest $kit
  $result = & $verify -KitDirectory $kit
  Assert-KitTest ($result.ProjectComplete -and $result.RebuildReady) "A complete project and approved image inventory were not marked rebuild-ready."

  Remove-Item -LiteralPath $archive -Force
  Write-KitManifest $kit
  $rejected = $false
  try { & $verify -KitDirectory $kit | Out-Null }
  catch { $rejected = $_.Exception.Message -match "missing Docker image archive" }
  Assert-KitTest $rejected "Complete image metadata without an archive was accepted."
  Write-FixtureFile $archive "old-image-archive-fixture"
  Write-KitManifest $kit
  $beforeArchiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
  & (Join-Path $fixtureRoot "scripts/refresh-offline-kit.ps1") -KitDirectory $kit -SkipDockerImages | Out-Null
  $result = & $verify -KitDirectory $kit
  Assert-KitTest $result.RebuildReady "Skipping an already complete image inventory broke readiness."
  Assert-KitTest ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -eq $beforeArchiveHash) "SkipDockerImages changed the existing archive."

  $restored = Join-Path $testRoot "restored"
  & (Join-Path $fixtureRoot "scripts/restore-offline-kit.ps1") -KitDirectory $kit -TargetDirectory $restored -SkipImageLoad -PrepareOnly | Out-Null
  foreach ($relative in @("terrasys.sh", "config/planetiler/poi-details.yml", "config/planetiler/world-overview.yml")) {
    Assert-KitTest (Test-Path -LiteralPath (Join-Path $restored $relative) -PathType Leaf) "Empty-directory restore omitted $relative"
  }
  Write-Host "Offline-kit reliability tests passed ($assertions assertions)."
}
finally {
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($resolvedTestRoot) -notlike "terrasys-kit-test-*") { throw "Unsafe fixture cleanup path." }
  if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
