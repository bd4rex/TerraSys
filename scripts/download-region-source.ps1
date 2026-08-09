param(
  [Parameter(Mandatory = $true)]
  [string]$PackId,
  [switch]$Refresh
)

$ErrorActionPreference = "Stop"
trap {
  Write-Error $_
  exit 1
}
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$pack = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
if (-not $pack) { throw "Unknown region pack: $PackId" }
$profile = $pack.sourceProfile
$target = Join-Path $root ([string]$profile.snapshotFile).Replace('/', '\')
$stateTarget = if ($profile.stateFile) { Join-Path $root ([string]$profile.stateFile).Replace('/', '\') } else { $null }
$statePreflight = if ($stateTarget) { "$stateTarget.refresh.part" } else { $null }

function Get-StateSequence([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^sequenceNumber=(.+)$') { return $matches[1].Trim() }
  }
  return ""
}

if (-not $Refresh -and (Test-Path -LiteralPath $target -PathType Leaf)) {
  if ([string]$profile.mode -eq "extract") {
    Write-Host "$($pack.name) uses the existing verified shared source snapshot."
  }
  Get-Item -LiteralPath $target | Select-Object FullName, Length, LastWriteTime
  exit 0
}
if (-not $profile.snapshotUrl) { throw "$PackId has no source download URL." }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
$staged = "$target.download.osm.pbf"
$legacyStaged = "$target.part"
$checksumFile = "$target.md5.part"
$stagedActivated = $false

function Get-PbfHeaderSequence([string]$Path) {
  $relativePath = $Path.Substring($root.Length).TrimStart('\').Replace('\', '/')
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $metadata = docker run --rm -v "${root}:/data" $osmiumImage fileinfo -F pbf "/data/$relativePath" 2>&1
  $metadataExitCode = $LASTEXITCODE
  $ErrorActionPreference = $previousPreference
  $metadataLines = @($metadata | ForEach-Object { "$_" })
  $metadataLines | ForEach-Object { Write-Host $_ }
  if ($metadataExitCode -ne 0) { throw "$($pack.name) staged source header is not a readable PBF." }
  $metadataText = $metadataLines -join "`n"
  if ($metadataText -match 'osmosis_replication_sequence_number=(\d+)') { return $matches[1] }
  return ""
}

try {
  $osmiumImage = "terrasys-osmium:1"
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required to validate regional source data."
  }
  if (-not (docker image ls -q $osmiumImage)) {
    docker build -t $osmiumImage (Join-Path $root "services\tools\osmium")
    if ($LASTEXITCODE -ne 0) { throw "Building the Osmium validation image failed." }
  }

  $remoteSequence = ""
  if ($Refresh -and (Test-Path -LiteralPath $target -PathType Leaf) -and $profile.stateUrl -and $stateTarget) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stateTarget) | Out-Null
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $statePreflight ([string]$profile.stateUrl)
    if ($LASTEXITCODE -ne 0) { throw "Checking $($pack.name) source state failed." }
    $localSequence = Get-StateSequence -Path $stateTarget
    $remoteSequence = Get-StateSequence -Path $statePreflight
    if (-not $remoteSequence) { throw "$($pack.name) remote source state has no sequence number." }
    if ($localSequence -and $remoteSequence -and $localSequence -eq $remoteSequence) {
      $targetSequence = Get-PbfHeaderSequence -Path $target
      if ($targetSequence -and $targetSequence -ne $localSequence) {
        throw "$($pack.name) source state is $localSequence but its PBF header is $targetSequence."
      }
      Write-Host "$($profile.provider) source snapshot is already current at sequence $remoteSequence; reusing it."
      Remove-Item -LiteralPath $statePreflight -Force
      Get-Item -LiteralPath $target | Select-Object FullName, Length, LastWriteTime
      exit 0
    }
    Write-Host "Source sequence changed from $localSequence to $remoteSequence; downloading a new snapshot."
  }

  if ((Test-Path -LiteralPath $legacyStaged -PathType Leaf) -and -not (Test-Path -LiteralPath $staged -PathType Leaf)) {
    Move-Item -LiteralPath $legacyStaged -Destination $staged -Force
  }
  $reuseStaged = $false
  if (Test-Path -LiteralPath $staged -PathType Leaf) {
    $stagedSequence = Get-PbfHeaderSequence -Path $staged
    if ($remoteSequence -and $stagedSequence -eq $remoteSequence) {
      Write-Host "Reusing the complete staged source at sequence $stagedSequence."
      $reuseStaged = $true
    }
    elseif ($profile.checksumUrl) {
      Write-Host "A staged direct source is present; its provider checksum will decide whether it can be reused."
      $reuseStaged = $true
    }
    else {
      Write-Warning "Discarding a staged source whose sequence '$stagedSequence' does not match '$remoteSequence'."
      Remove-Item -LiteralPath $staged -Force
    }
  }
  if (-not $reuseStaged) {
    Write-Host "Downloading source for $($pack.name)..."
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $staged ([string]$profile.snapshotUrl)
    if ($LASTEXITCODE -ne 0) { throw "Downloading $($pack.name) source failed." }
  }
  if ((Get-Item -LiteralPath $staged).Length -lt 64KB) { throw "$($pack.name) source is unexpectedly small." }
  if ($profile.checksumUrl) {
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $checksumFile ([string]$profile.checksumUrl)
    if ($LASTEXITCODE -ne 0) { throw "Downloading $($pack.name) checksum failed." }
    $expected = ((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm MD5 -LiteralPath $staged).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "$($pack.name) source MD5 verification failed." }
  }
  else {
    $relativeStaged = $staged.Substring($root.Length).TrimStart('\').Replace('\', '/')
    Write-Host "Validating the staged shared source before activation..."
    docker run --rm -v "${root}:/data" $osmiumImage fileinfo -F pbf -e "/data/$relativeStaged" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$($pack.name) source metadata validation failed." }
    $stagedSequence = Get-PbfHeaderSequence -Path $staged
    if ($remoteSequence -and $stagedSequence -ne $remoteSequence) {
      throw "$($pack.name) staged PBF sequence $stagedSequence does not match remote state $remoteSequence."
    }
  }
  if ($profile.stateUrl -and $profile.stateFile -and -not (Test-Path -LiteralPath $statePreflight -PathType Leaf)) {
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $statePreflight ([string]$profile.stateUrl)
    if ($LASTEXITCODE -ne 0) { throw "Downloading $($pack.name) state failed." }
  }

  $previousTarget = "$target.previous"
  $previousState = if ($stateTarget) { "$stateTarget.previous" } else { $null }
  if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $previousTarget -Force }
  if ($previousState -and (Test-Path -LiteralPath $stateTarget)) {
    Move-Item -LiteralPath $stateTarget -Destination $previousState -Force
  }
  try {
    Move-Item -LiteralPath $staged -Destination $target -Force
    if ($profile.stateUrl -and $profile.stateFile) {
      Move-Item -LiteralPath $statePreflight -Destination $stateTarget -Force
    }
    $stagedActivated = $true
  }
  catch {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    if ($stateTarget -and (Test-Path -LiteralPath $stateTarget)) { Remove-Item -LiteralPath $stateTarget -Force }
    if ((Test-Path -LiteralPath $previousTarget) -and -not (Test-Path -LiteralPath $target)) {
      Move-Item -LiteralPath $previousTarget -Destination $target -Force
    }
    if ($previousState -and (Test-Path -LiteralPath $previousState) -and -not (Test-Path -LiteralPath $stateTarget)) {
      Move-Item -LiteralPath $previousState -Destination $stateTarget -Force
    }
    throw
  }
}
finally {
  if ($stagedActivated -and (Test-Path -LiteralPath $legacyStaged)) { Remove-Item -LiteralPath $legacyStaged -Force }
  if (Test-Path -LiteralPath $checksumFile) { Remove-Item -LiteralPath $checksumFile -Force }
  if ($stagedActivated -and $statePreflight -and (Test-Path -LiteralPath $statePreflight)) { Remove-Item -LiteralPath $statePreflight -Force }
}
Get-Item -LiteralPath $target | Select-Object FullName, Length, LastWriteTime
