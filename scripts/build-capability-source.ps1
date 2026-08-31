param(
  [string]$OutputId = "terrasys-core"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
$disabledPackIds = @()
if (Test-Path -LiteralPath $packStatePath -PathType Leaf) {
  $packState = Get-Content -Raw -LiteralPath $packStatePath | ConvertFrom-Json
  $disabledPackIds = @($packState.disabledPackIds | ForEach-Object { [string]$_ })
}
$osmiumImage = "terrasys-osmium:1"
$outputDirectory = Join-Path $root "raw\osm\china"
$output = Join-Path $outputDirectory "$OutputId-latest.osm.pbf"
$staged = Join-Path $outputDirectory "$OutputId-staged.osm.pbf"
$merged = Join-Path $outputDirectory "$OutputId-merged.osm.pbf"
$manifestPath = Join-Path $outputDirectory "$OutputId.manifest.json"
$statePath = Join-Path $outputDirectory "china.state.txt"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker was not found on PATH." }
if (-not (docker image ls -q $osmiumImage)) {
  docker build -t $osmiumImage (Join-Path $root "services\tools\osmium")
  Assert-NativeSuccess "Building the Osmium image"
}

$inputs = @()
$skippedCount = 0
foreach ($dataset in @($catalog.datasets)) {
  if ($disabledPackIds -contains [string]$dataset.id) {
    $skippedCount++
    continue
  }
  $productPath = Join-Path $root "products\tiles\pmtiles\$($dataset.id).pmtiles"
  $packManifestPath = Join-Path $root "products\tiles\pmtiles\$($dataset.id).manifest.json"
  $productExists = Test-Path -LiteralPath $productPath -PathType Leaf
  $manifestExists = Test-Path -LiteralPath $packManifestPath -PathType Leaf
  if (-not $productExists -and -not $manifestExists) {
    $skippedCount++
    continue
  }
  if ($productExists -ne $manifestExists) {
    throw "Regional pack $($dataset.id) is partially installed; both PMTiles and manifest are required."
  }
  $packManifest = Get-Content -Raw -LiteralPath $packManifestPath | ConvertFrom-Json
  $sourceRelative = ([string]$packManifest.source.file).Replace('/', '\')
  $sourcePath = Join-Path $root $sourceRelative
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Regional source is missing for $($dataset.id): $sourcePath"
  }
  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
  if ($sourceHash -ne ([string]$packManifest.source.sha256).ToLowerInvariant()) {
    throw "Regional source hash does not match the $($dataset.id) manifest."
  }
  $maximumMissingReferences = if ($null -ne $dataset.sourceProfile.maxMissingReferences) {
    [int64]$dataset.sourceProfile.maxMissingReferences
  } elseif ([string]$dataset.sourceProfile.mode -eq "extract") { [int64]100 } else { [int64]0 }
  $inputs += [pscustomobject][ordered]@{
    id = [string]$dataset.id
    relativePath = $sourceRelative.Replace('\', '/')
    bytes = (Get-Item -LiteralPath $sourcePath).Length
    sha256 = $sourceHash
    sourceSequence = [string]$packManifest.source.sequenceNumber
    sourceUpdatedAt = [string]$packManifest.source.updatedAt
    maximumMissingReferences = $maximumMissingReferences
  }
}

if ($inputs.Count -lt 1) { throw "The map catalog contains no capability-source inputs." }
Write-Host "Capability scope: $($inputs.Count) installed packs; skipped $skippedCount disabled or uninstalled catalog entries."
$sequences = @($inputs.sourceSequence | Select-Object -Unique)
$sourceSequence = if ($sequences.Count -eq 1) { $sequences[0] } else { "mixed" }
$maximumMissingReferences = [int64](($inputs | Measure-Object maximumMissingReferences -Sum).Sum)

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
if (Test-Path -LiteralPath $merged) { Remove-Item -LiteralPath $merged -Force }
$containerInputs = @($inputs | ForEach-Object { "/data/$($_.relativePath)" })
$snapshotTime = [DateTime]::UtcNow.AddYears(10).ToString("yyyy-MM-ddTHH:mm:ssZ")

try {
  Write-Host "Merging $($inputs.Count) verified regional sources into $OutputId..."
  docker run --rm -v "${root}:/data" $osmiumImage merge @containerInputs `
    -o "/data/raw/osm/china/$OutputId-merged.osm.pbf"
  Assert-NativeSuccess "Merging the capability source"

  Write-Host "Deduplicating overlapping regional boundaries..."
  docker run --rm -v "${root}:/data" $osmiumImage time-filter -F pbf `
    "/data/raw/osm/china/$OutputId-merged.osm.pbf" $snapshotTime `
    -o "/data/raw/osm/china/$OutputId-staged.osm.pbf" --overwrite
  Assert-NativeSuccess "Deduplicating the capability source"

  docker run --rm -v "${root}:/data" $osmiumImage fileinfo -e "/data/raw/osm/china/$OutputId-staged.osm.pbf" | Out-Host
  Assert-NativeSuccess "Reading capability-source metadata"

  $savedErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $referenceCheck = docker run --rm -v "${root}:/data" $osmiumImage check-refs "/data/raw/osm/china/$OutputId-staged.osm.pbf" 2>&1
  $referenceExitCode = $LASTEXITCODE
  $ErrorActionPreference = $savedErrorAction
  $referenceLines = @($referenceCheck | ForEach-Object { "$_" })
  $referenceLines | ForEach-Object { Write-Host $_ }
  $referenceText = $referenceLines -join "`n"
  $missingWayNodes = if ($referenceText -match 'Nodes in ways missing:\s+(\d+)') { [int64]$matches[1] } else { [int64]0 }
  $missingRelationMembers = if ($referenceText -match 'Members in relations missing:\s+(\d+)') { [int64]$matches[1] } else { [int64]0 }
  $missingTotal = $missingWayNodes + $missingRelationMembers
  $recognizedFailure = $referenceText -match '(?:Nodes in ways|Members in relations) missing:\s+\d+'
  if ($referenceExitCode -ne 0) {
    if ($recognizedFailure -and $missingTotal -le $maximumMissingReferences) {
      Write-Warning "$OutputId inherited $missingTotal omitted references from its public regional extracts; the aggregate configured limit is $maximumMissingReferences."
    }
    else {
      throw "Checking capability-source references failed with exit code $referenceExitCode."
    }
  }

  if (Test-Path -LiteralPath $output) {
    Copy-Item -LiteralPath $output -Destination (Join-Path $outputDirectory "$OutputId.previous.osm.pbf") -Force
  }
  Move-Item -LiteralPath $staged -Destination $output -Force

  $state = @{}
  if (Test-Path -LiteralPath $statePath) {
    foreach ($line in Get-Content -LiteralPath $statePath) {
      if ($line -match '^([^=]+)=(.*)$') { $state[$matches[1]] = $matches[2].Replace('\:', ':') }
    }
  }
  $manifest = [ordered]@{
    schemaVersion = 1
    id = $OutputId
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    source = [ordered]@{
      sequence = $sourceSequence
      inputSequences = @($sequences)
      updatedAt = if ($state.timestamp) { $state.timestamp } else { $inputs[0].sourceUpdatedAt }
      catalogVersion = [string]$catalog.version
    }
    inputs = $inputs
    referenceIntegrity = [ordered]@{
      missingWayNodes = $missingWayNodes
      missingRelationMembers = $missingRelationMembers
      missingTotal = $missingTotal
      maximumMissingReferences = $maximumMissingReferences
    }
    product = [ordered]@{
      path = "raw/osm/china/$OutputId-latest.osm.pbf"
      bytes = (Get-Item -LiteralPath $output).Length
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()
    }
  }
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)
}
finally {
  if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
  if (Test-Path -LiteralPath $merged) { Remove-Item -LiteralPath $merged -Force }
}

Get-Item -LiteralPath $output, $manifestPath | Select-Object FullName, Length, LastWriteTime
