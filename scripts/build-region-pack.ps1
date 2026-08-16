param(
  [Parameter(Mandatory = $true)]
  [string]$PackId,
  [string]$MaintenanceJobId = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$pack = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
if (-not $pack) { throw "Unknown region pack: $PackId" }

$osmiumImage = "terrasys-osmium:1"
$planetilerImage = "ghcr.io/onthegomap/planetiler@sha256:90c9d29ef013fb30af30b8e117a7847c7ef56e9bf05f25633c7d7228d6955cf0"
$profile = $pack.sourceProfile
$buildMode = if ($profile.mode) { [string]$profile.mode } else { "extract" }
$snapshotRelative = ([string]$profile.snapshotFile).Replace('/', '\')
$snapshotHost = Join-Path $root $snapshotRelative
$workRelative = "tmp\osmium-$PackId"
$workHost = Join-Path $root $workRelative
$sourceRelative = if ($buildMode -eq "direct") { $snapshotRelative } else { ([string]$pack.sourceFile).Replace('/', '\') }
$sourceHost = Join-Path $root $sourceRelative
$sourceStaged = if ($buildMode -eq "extract") { Join-Path (Split-Path -Parent $sourceHost) "$PackId-staged.osm.pbf" } else { $null }
$outputRoot = Join-Path $root "products\tiles\pmtiles"
$output = Join-Path $outputRoot "$PackId.pmtiles"
$outputStaged = Join-Path $outputRoot "$PackId.staged.pmtiles"
$dockerJobArguments = if ($MaintenanceJobId) { @("--label", "terrasys.maintenance-job=$MaintenanceJobId") } else { @() }

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Get-ReferenceIntegrity {
  param(
    [Parameter(Mandatory = $true)][string]$ContainerPath,
    [Parameter(Mandatory = $true)][int64]$MaximumMissingReferences,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $checkErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $referenceCheck = docker run --rm @dockerJobArguments -v "${root}:/data" $osmiumImage check-refs $ContainerPath 2>&1
  $referenceExitCode = $LASTEXITCODE
  $ErrorActionPreference = $checkErrorAction
  $referenceLines = @($referenceCheck | ForEach-Object { "$_" })
  $referenceLines | ForEach-Object { Write-Host $_ }
  $referenceText = $referenceLines -join "`n"
  $missingWayNodes = if ($referenceText -match 'Nodes in ways missing:\s+(\d+)') { [int64]$matches[1] } else { [int64]0 }
  $missingRelationMembers = if ($referenceText -match 'Members in relations missing:\s+(\d+)') { [int64]$matches[1] } else { [int64]0 }
  $missingTotal = $missingWayNodes + $missingRelationMembers
  $recognizedFailure = $referenceText -match '(?:Nodes in ways|Members in relations) missing:\s+\d+'
  if ($referenceExitCode -ne 0) {
    if ($recognizedFailure -and $missingTotal -le $MaximumMissingReferences) {
      Write-Warning "$Label contains $missingTotal references omitted by its public provider; the configured limit is $MaximumMissingReferences."
    }
    else {
      throw "Checking $Label references failed with exit code $referenceExitCode."
    }
  }
  return [pscustomobject][ordered]@{
    missingWayNodes = $missingWayNodes
    missingRelationMembers = $missingRelationMembers
    missingTotal = $missingTotal
    maximumMissingReferences = $MaximumMissingReferences
  }
}

if (-not (Test-Path -LiteralPath $snapshotHost)) {
  if ($buildMode -eq "direct") {
    & (Join-Path $PSScriptRoot "download-region-source.ps1") -PackId $PackId
  }
  else {
    throw "Common source PBF is missing: $snapshotHost. Run download-osm.cmd first."
  }
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }
if (-not (docker image ls -q $osmiumImage)) {
  docker build -t $osmiumImage (Join-Path $root "services\tools\osmium")
  Assert-NativeSuccess "Building the Osmium image"
}

foreach ($member in @($pack.members)) {
  if (-not (Test-Path -LiteralPath (Join-Path $root "raw\osm\polygons\$($member.id).poly"))) {
    & (Join-Path $PSScriptRoot "download-region-polygons.ps1") -PackId $PackId
    break
  }
}

New-Item -ItemType Directory -Force -Path $workHost, $outputRoot, (Split-Path -Parent $sourceHost) | Out-Null
$containerExtracts = New-Object System.Collections.Generic.List[string]
$hostExtracts = New-Object System.Collections.Generic.List[string]
$maximumMissingReferences = if ($null -ne $profile.maxMissingReferences) {
  [int64]$profile.maxMissingReferences
} elseif ($buildMode -eq "extract") { [int64]100 } else { [int64]0 }
$sourceReferenceIntegrity = $null

try {
  if ($buildMode -eq "extract") {
    foreach ($member in @($pack.members)) {
      $hostExtract = Join-Path $workHost "$($member.id).osm.pbf"
      $containerExtract = "/data/$($workRelative.Replace('\', '/'))/$($member.id).osm.pbf"
      $containerExtracts.Add($containerExtract)
      $hostExtracts.Add($hostExtract)
      Write-Host "Extracting $($member.name) from $($profile.provider) common snapshot..."
      docker run --rm @dockerJobArguments -v "${root}:/data" $osmiumImage extract `
        -p "/data/raw/osm/polygons/$($member.id).poly" -s complete_ways `
        "/data/$($snapshotRelative.Replace('\', '/'))" -o $containerExtract -O
      Assert-NativeSuccess "Extracting $($member.name)"
    }

    if (Test-Path -LiteralPath $sourceStaged) { Remove-Item -LiteralPath $sourceStaged -Force }
    Write-Host "Merging $($pack.name) extracts and deduplicating shared boundary objects..."
    $stagedContainer = "/data/$((($sourceStaged.Substring($root.Length)).TrimStart('\')).Replace('\', '/'))"
    docker run --rm @dockerJobArguments -v "${root}:/data" $osmiumImage merge @containerExtracts -o $stagedContainer
    Assert-NativeSuccess "Merging $PackId extracts"
    docker run --rm @dockerJobArguments -v "${root}:/data" $osmiumImage fileinfo -e $stagedContainer | Out-Host
    Assert-NativeSuccess "Reading $PackId metadata"
    $sourceReferenceIntegrity = Get-ReferenceIntegrity `
      -ContainerPath $stagedContainer `
      -MaximumMissingReferences $maximumMissingReferences `
      -Label $PackId
    Move-Item -LiteralPath $sourceStaged -Destination $sourceHost -Force
  }
  else {
    Write-Host "Using verified direct source for $($pack.name): $sourceRelative"
    $sourceReferenceIntegrity = Get-ReferenceIntegrity `
      -ContainerPath "/data/$($sourceRelative.Replace('\', '/'))" `
      -MaximumMissingReferences $maximumMissingReferences `
      -Label $PackId
  }

  & (Join-Path $PSScriptRoot "download-planetiler-sources.ps1")

  if (Test-Path -LiteralPath $outputStaged) { Remove-Item -LiteralPath $outputStaged -Force }
  $bounds = (@($pack.bounds) -join ',')
  Write-Host "Building staged $($pack.name) PMTiles..."
  docker run --rm @dockerJobArguments `
    --memory 5g --memory-swap 6g --cpus 4 `
    -e JAVA_TOOL_OPTIONS="-Xmx4g" `
    -v "${root}:/data" `
    $planetilerImage `
    --osm-path="/data/$($sourceRelative.Replace('\', '/'))" `
    --output="/data/products/tiles/pmtiles/$PackId.staged.pmtiles" `
    --download=false `
    --download-dir=/data/raw/planetiler-sources `
    --tmpdir="/data/tmp/planetiler-$PackId" `
    --bounds=$bounds `
    --maxzoom=16 `
    --osm_lazy_reads=false `
    --natural_earth_keep_unzipped=true `
    --force=true
  Assert-NativeSuccess "Building $PackId PMTiles"

  if ((Get-Item -LiteralPath $outputStaged).Length -lt 64KB) { throw "$PackId PMTiles is unexpectedly small." }
  $stream = [IO.File]::OpenRead($outputStaged)
  try {
    $header = New-Object byte[] 7
    [void]$stream.Read($header, 0, 7)
  }
  finally { $stream.Dispose() }
  if ([Text.Encoding]::ASCII.GetString($header) -ne "PMTiles") { throw "$PackId PMTiles header is invalid." }

  $previousOutput = Join-Path $outputRoot "$PackId.previous.pmtiles"
  $manifestPath = Join-Path $outputRoot "$PackId.manifest.json"
  $previousManifestPath = Join-Path $outputRoot "$PackId.previous.manifest.json"
  $historyRoot = Join-Path $outputRoot "history\$PackId"
  $sameProduct = (Test-Path -LiteralPath $output) -and
    ((Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $outputStaged).Hash)

  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    New-Item -ItemType Directory -Force -Path $historyRoot | Out-Null
    $currentManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $historySequence = if ($currentManifest.source.sequenceNumber) { [string]$currentManifest.source.sequenceNumber } else { "unknown" }
    $historyGenerated = if ($currentManifest.generatedAt) {
      ([DateTimeOffset]::Parse([string]$currentManifest.generatedAt)).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    } else { (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.ToString("yyyyMMddTHHmmssZ") }
    $historyManifest = Join-Path $historyRoot "$historySequence-$historyGenerated.manifest.json"
    if (-not (Test-Path -LiteralPath $historyManifest -PathType Leaf)) {
      Copy-Item -LiteralPath $manifestPath -Destination $historyManifest
    }
  }

  if ($sameProduct) {
    Write-Host "$PackId generated product is byte-identical; keeping one copy and refreshing its manifest."
    Remove-Item -LiteralPath $outputStaged -Force
    & (Join-Path $PSScriptRoot "write-region-manifest.ps1") -PackId $PackId `
      -MissingWayNodes $sourceReferenceIntegrity.missingWayNodes `
      -MissingRelationMembers $sourceReferenceIntegrity.missingRelationMembers `
      -MaxMissingReferences $sourceReferenceIntegrity.maximumMissingReferences
    & (Join-Path $PSScriptRoot "build-region-details.ps1") -PackId $PackId -MaintenanceJobId $MaintenanceJobId
  }
  else {
    if (Test-Path -LiteralPath $output) { Move-Item -LiteralPath $output -Destination $previousOutput -Force }
    if (Test-Path -LiteralPath $manifestPath) { Move-Item -LiteralPath $manifestPath -Destination $previousManifestPath -Force }
    try {
      Move-Item -LiteralPath $outputStaged -Destination $output -Force
      & (Join-Path $PSScriptRoot "write-region-manifest.ps1") -PackId $PackId `
        -MissingWayNodes $sourceReferenceIntegrity.missingWayNodes `
        -MissingRelationMembers $sourceReferenceIntegrity.missingRelationMembers `
        -MaxMissingReferences $sourceReferenceIntegrity.maximumMissingReferences
      & (Join-Path $PSScriptRoot "build-region-details.ps1") -PackId $PackId -MaintenanceJobId $MaintenanceJobId
    }
    catch {
      if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
      if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
      if ((Test-Path -LiteralPath $previousOutput) -and -not (Test-Path -LiteralPath $output)) {
        Move-Item -LiteralPath $previousOutput -Destination $output -Force
      }
      if ((Test-Path -LiteralPath $previousManifestPath) -and -not (Test-Path -LiteralPath $manifestPath)) {
        Move-Item -LiteralPath $previousManifestPath -Destination $manifestPath -Force
      }
      throw
    }
  }
}
finally {
  if ($sourceStaged -and (Test-Path -LiteralPath $sourceStaged)) { Remove-Item -LiteralPath $sourceStaged -Force }
  if (Test-Path -LiteralPath $outputStaged) { Remove-Item -LiteralPath $outputStaged -Force }
  foreach ($hostExtract in $hostExtracts) {
    if (Test-Path -LiteralPath $hostExtract) { Remove-Item -LiteralPath $hostExtract -Force }
  }
}

Get-Item -LiteralPath $sourceHost, $output, (Join-Path $outputRoot "$PackId.manifest.json") |
  Select-Object FullName, Length, LastWriteTime
