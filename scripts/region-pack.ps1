param(
  [ValidateSet("List", "Verify", "Plan", "Build", "Update", "Rollback", "Remove")]
  [string]$Action = "List",
  [string]$PackId = "",
  [switch]$ConfirmRemove,
  [string]$MaintenanceJobId = ""
)

$ErrorActionPreference = "Stop"
trap {
  Write-Error $_
  exit 1
}
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$packs = @($catalog.datasets)
if ($PackId) {
  $packs = @($packs | Where-Object { $_.id -eq $PackId })
  if ($packs.Count -ne 1) { throw "Unknown region pack: $PackId" }
}

if ($Action -eq "Plan") {
  if (-not $PackId) { throw "-Plan requires -PackId." }
  $pack = $packs[0]
  $snapshot = Join-Path $root ([string]$pack.sourceProfile.snapshotFile).Replace('/', '\')
  $source = Join-Path $root ([string]$pack.sourceFile).Replace('/', '\')
  $boundaries = @($pack.members | ForEach-Object {
    $path = Join-Path $root "raw\osm\polygons\$($_.id).poly"
    [pscustomobject]@{ Id = $_.id; Name = $_.name; Ready = Test-Path -LiteralPath $path -PathType Leaf; Path = $path }
  })
  [pscustomobject][ordered]@{
    Id = $pack.id
    Name = $pack.name
    Kind = $pack.kind
    AdministrativeType = $pack.administrativeType
    Group = $pack.groupName
    SourceProvider = $pack.sourceProfile.provider
    SourceMode = $pack.sourceProfile.mode
    SnapshotReady = Test-Path -LiteralPath $snapshot -PathType Leaf
    Snapshot = $snapshot
    RegionalSource = $source
    BoundariesReady = @($boundaries | Where-Object { -not $_.Ready }).Count -eq 0
    EstimatedInstallGiB = (@($pack.estimatedInstallGiB) -join "-")
    EstimatedTemporaryGiB = $pack.estimatedTemporaryGiB
    EstimatedBuildMinutes = (@($pack.estimatedBuildMinutes) -join "-")
    BuildCommand = "D:\TerraSys\region-pack.cmd Build -PackId $($pack.id)"
  } | Format-List
  $boundaries | Format-Table -AutoSize
  exit 0
}

if ($Action -eq "Remove") {
  if (-not $PackId) { throw "-Remove requires -PackId." }
  if (-not $ConfirmRemove) { throw "Removal requires -ConfirmRemove." }
  $productRoot = [IO.Path]::GetFullPath((Join-Path $root "products\tiles\pmtiles"))
  $targets = @(
    Join-Path $productRoot "$PackId.pmtiles"
    Join-Path $productRoot "$PackId.manifest.json"
    Join-Path $productRoot "$PackId.previous.pmtiles"
    Join-Path $productRoot "$PackId.previous.manifest.json"
    Join-Path $productRoot "$PackId.staged.pmtiles"
    Join-Path $productRoot "$PackId.details.staged.pmtiles"
  )
  $targets += Get-ChildItem -LiteralPath $productRoot -File -Filter "$PackId.details.*.pmtiles" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName }
  $targets += Get-ChildItem -LiteralPath $productRoot -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$PackId.swap-*.pmtiles" -or $_.Name -like "$PackId.swap-*.manifest.json" } |
    ForEach-Object { $_.FullName }
  foreach ($target in $targets) {
    $resolved = [IO.Path]::GetFullPath($target)
    if (-not $resolved.StartsWith("$productRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove a path outside the PMTiles product root."
    }
    if (Test-Path -LiteralPath $resolved -PathType Leaf) { Remove-Item -LiteralPath $resolved -Force }
  }
  Write-Host "$PackId current, rollback, and incomplete map products removed. Regional PBF, boundaries, and version audit metadata were retained."
  exit 0
}

if ($Action -eq "Rollback") {
  if (-not $PackId) { throw "-Rollback requires -PackId." }
  $productRoot = [IO.Path]::GetFullPath((Join-Path $root "products\tiles\pmtiles"))
  $currentProduct = Join-Path $productRoot "$PackId.pmtiles"
  $currentManifest = Join-Path $productRoot "$PackId.manifest.json"
  $previousProduct = Join-Path $productRoot "$PackId.previous.pmtiles"
  $previousManifest = Join-Path $productRoot "$PackId.previous.manifest.json"
  foreach ($required in @($currentProduct, $currentManifest, $previousProduct, $previousManifest)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Rollback is unavailable because a complete current and previous version pair is required."
    }
  }
  foreach ($versionManifest in @($currentManifest, $previousManifest)) {
    $version = Get-Content -Raw -LiteralPath $versionManifest | ConvertFrom-Json
    if (-not $version.details.file) { throw "Rollback requires rich-detail metadata for both map versions." }
    $detailsPath = Join-Path $root ([string]$version.details.file).Replace('/', '\')
    if (-not (Test-Path -LiteralPath $detailsPath -PathType Leaf)) {
      throw "Rollback detail companion is missing: $detailsPath"
    }
  }
  $swapId = [Guid]::NewGuid().ToString("N")
  $swapProduct = Join-Path $productRoot "$PackId.swap-$swapId.pmtiles"
  $swapManifest = Join-Path $productRoot "$PackId.swap-$swapId.manifest.json"
  try {
    Move-Item -LiteralPath $currentProduct -Destination $swapProduct
    Move-Item -LiteralPath $currentManifest -Destination $swapManifest
    Move-Item -LiteralPath $previousProduct -Destination $currentProduct
    Move-Item -LiteralPath $previousManifest -Destination $currentManifest
    Move-Item -LiteralPath $swapProduct -Destination $previousProduct
    Move-Item -LiteralPath $swapManifest -Destination $previousManifest
  }
  catch {
    if ((Test-Path -LiteralPath $swapProduct) -and -not (Test-Path -LiteralPath $currentProduct)) {
      Move-Item -LiteralPath $swapProduct -Destination $currentProduct -Force
    }
    if ((Test-Path -LiteralPath $swapManifest) -and -not (Test-Path -LiteralPath $currentManifest)) {
      Move-Item -LiteralPath $swapManifest -Destination $currentManifest -Force
    }
    throw
  }
  Write-Host "$PackId current and previous map versions were swapped atomically."
  exit 0
}

if ($Action -in @("Build", "Update")) {
  if (-not $PackId) { throw "-$Action requires -PackId." }
  if ($Action -eq "Update") {
    & (Join-Path $PSScriptRoot "download-region-polygons.ps1") -PackId $PackId
    $selected = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
    Write-Host "Refreshing $($selected.sourceProfile.provider) source snapshot before rebuilding $($selected.name)..."
    & (Join-Path $PSScriptRoot "download-region-source.ps1") -PackId $PackId -Refresh
  }
  & (Join-Path $PSScriptRoot "build-region-pack.ps1") -PackId $PackId -MaintenanceJobId $MaintenanceJobId
  $selected = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
  $statePath = if ($selected.sourceProfile.stateFile) {
    Join-Path $root ([string]$selected.sourceProfile.stateFile).Replace('/', '\')
  } else { $null }
  $expectedSequence = if ($statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    ((Get-Content -LiteralPath $statePath | Where-Object { $_ -match '^sequenceNumber=' } | Select-Object -First 1) -replace '^sequenceNumber=', '').Trim()
  } else { "" }
  $manifestPath = Join-Path $root "products\tiles\pmtiles\$PackId.manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "$PackId build did not produce a manifest."
  }
  $completedManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $manifestSequence = ([string]$completedManifest.source.sequenceNumber).Trim()
  if ($Action -eq "Update" -and $selected.sourceProfile.stateUrl -and -not $expectedSequence) {
    throw "$PackId update completed without a trusted source sequence."
  }
  if ($expectedSequence -and $manifestSequence -ne $expectedSequence) {
    throw "$PackId manifest sequence $manifestSequence does not match source state $expectedSequence."
  }
  if ($expectedSequence) {
    Write-Host "$PackId lifecycle verified at source sequence $manifestSequence."
  }
  else {
    $sourcePath = Join-Path $root ([string]$selected.sourceProfile.snapshotFile).Replace('/', '\')
    $sourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
    if (([string]$completedManifest.source.sha256).ToLowerInvariant() -ne $sourceSha256) {
      throw "$PackId manifest source hash does not match its verified source snapshot."
    }
    Write-Host "$PackId lifecycle verified at source SHA256 $sourceSha256."
  }
  exit 0
}

$results = foreach ($pack in $packs) {
  $product = Join-Path $root "products\tiles\pmtiles\$($pack.id).pmtiles"
  $manifestPath = Join-Path $root "products\tiles\pmtiles\$($pack.id).manifest.json"
  $installed = (Test-Path -LiteralPath $product -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)
  $verified = $false
  $bytes = 0
  $sourceUpdatedAt = $null
  $detailsReady = $false
  if ($installed) {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $info = Get-Item -LiteralPath $product
    $detailsPath = if ($manifest.details.file) { Join-Path $root ([string]$manifest.details.file).Replace('/', '\') } else { $null }
    $detailsReady = $detailsPath -and (Test-Path -LiteralPath $detailsPath -PathType Leaf)
    $detailsInfo = if ($detailsReady) { Get-Item -LiteralPath $detailsPath } else { $null }
    $bytes = $info.Length + $(if ($detailsInfo) { $detailsInfo.Length } else { 0 })
    $headerStream = [IO.File]::OpenRead($product)
    try {
      $header = New-Object byte[] 7
      [void]$headerStream.Read($header, 0, 7)
    }
    finally { $headerStream.Dispose() }
    $verified = $info.Length -eq [int64]$manifest.product.bytes -and $detailsReady -and
      $detailsInfo.Length -eq [int64]$manifest.details.bytes -and
      [Text.Encoding]::ASCII.GetString($header) -eq "PMTiles"
    if ($Action -eq "Verify") {
      $verified = $verified -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $product).Hash.ToLowerInvariant() -eq
          ([string]$manifest.product.sha256).ToLowerInvariant() -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $detailsPath).Hash.ToLowerInvariant() -eq
          ([string]$manifest.details.sha256).ToLowerInvariant()
    }
    $sourceUpdatedAt = $manifest.source.updatedAt
  }
  [pscustomobject]@{
    Id = $pack.id
    Name = $pack.name
    Installed = $installed
    Verified = $verified
    MiB = [math]::Round($bytes / 1MB, 1)
    SourceUpdatedAt = $sourceUpdatedAt
    RichDetails = [bool]$detailsReady
    Kind = $pack.kind
  }
}

$results | Format-Table -AutoSize
if ($Action -eq "Verify" -and @($results | Where-Object { $_.Installed -and -not $_.Verified }).Count -gt 0) {
  throw "One or more installed region packs failed verification."
}
