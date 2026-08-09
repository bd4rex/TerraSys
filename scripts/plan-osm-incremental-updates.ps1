param([switch]$Json)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")

$catalog = Get-TerraSysExpandedCatalog -Root $root
$packStatePath = Join-Path $root "data\maintenance\map-pack-state.json"
$packState = if (Test-Path -LiteralPath $packStatePath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $packStatePath | ConvertFrom-Json
} else { $null }
$disabled = @($packState.disabledPackIds | ForEach-Object { [string]$_ })
$installed = @()

foreach ($dataset in @($catalog.datasets)) {
  $product = Join-Path $root "products\tiles\pmtiles\$($dataset.id).pmtiles"
  $manifestPath = Join-Path $root "products\tiles\pmtiles\$($dataset.id).manifest.json"
  if (-not (Test-Path -LiteralPath $product -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $profile = $dataset.sourceProfile
  $installed += [pscustomobject][ordered]@{
    id = [string]$dataset.id
    name = [string]$dataset.name
    enabled = $disabled -notcontains [string]$dataset.id
    sourceSequence = [string]$manifest.source.sequenceNumber
    sourceUpdatedAt = [string]$manifest.source.updatedAt
    replicationStateUrl = [string]$profile.stateUrl
    snapshotUrl = [string]$profile.snapshotUrl
    eligibleForPilot = [bool]$profile.stateUrl
  }
}

$drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).TrimEnd('\').TrimEnd(':'))
$osmiumReady = [bool](docker image ls -q terrasys-osmium:1 2>$null)
$report = [ordered]@{
  schemaVersion = 1
  generatedAt = [DateTimeOffset]::Now.ToString("o")
  mode = "read-only-readiness"
  productionIncrementalUpdatesEnabled = $false
  disasterRecoveryBaseline = "full-snapshot"
  osmiumImageReady = $osmiumReady
  freeBytes = [int64]$drive.Free
  installedPacks = $installed
  pilotRecommendation = [ordered]@{
    packIds = @($installed | Where-Object { $_.enabled -and $_.eligibleForPilot } | Select-Object -First 1 -ExpandProperty id)
    steps = @(
      "Copy the verified full snapshot into an isolated staging directory",
      "Resolve and persist the exact replication sequence",
      "Download a bounded diff range and retain every diff with SHA256",
      "Apply changes to a staged PBF and run fileinfo/check-refs",
      "Rebuild one PMTiles pack and compare counts, bounds, and sampled tiles",
      "Promote atomically only after verification; retain the previous snapshot"
    )
  }
}

if ($Json) { $report | ConvertTo-Json -Depth 8 }
else {
  $report | Format-List schemaVersion, generatedAt, mode, productionIncrementalUpdatesEnabled, disasterRecoveryBaseline, osmiumImageReady, freeBytes
  $installed | Format-Table id, enabled, sourceSequence, sourceUpdatedAt, eligibleForPilot -AutoSize
  Write-Host "No files were changed. See docs\OSM_INCREMENTAL_UPDATES.md before enabling a pilot."
}
