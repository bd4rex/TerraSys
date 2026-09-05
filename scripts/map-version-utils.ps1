# Fixed public filenames are retained for existing clients. The activation journal
# hides the short multi-file commit from readers and keeps immutable originals for
# idempotent recovery after exceptions, cancellation, or a host restart.
function Get-TerraSysMapPaths {
  param([string]$ProductRoot, [string]$PackId)
  if ($PackId -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Invalid map pack id: $PackId" }
  $directory = [IO.Path]::GetFullPath($ProductRoot)
  return [pscustomobject]@{
    Root = $directory
    Journal = Join-Path $directory "$PackId.activation.json"
    Lock = Join-Path $directory ".$PackId.operation.lock"
    Names = @("$PackId.pmtiles", "$PackId.manifest.json", "$PackId.previous.pmtiles", "$PackId.previous.manifest.json")
  }
}

function Enter-TerraSysMapLock {
  param([string]$ProductRoot, [string]$PackId)
  $paths = Get-TerraSysMapPaths $ProductRoot $PackId
  New-Item -ItemType Directory -Force -Path $paths.Root | Out-Null
  try { return [IO.File]::Open($paths.Lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { throw "Another operation is using map pack '$PackId'; retry after it completes. $($_.Exception.Message)" }
}

function Write-TerraSysMapJournal {
  param([string]$Path, [object]$Journal)
  $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Journal | ConvertTo-Json -Depth 8))
  $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
  finally { $stream.Dispose() }
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Copy-TerraSysMapSnapshot {
  param([string]$Source, [string]$Destination)
  # Map archives are immutable: a hard link preserves an old inode without
  # doubling multi-gigabyte maps. Filesystems without hard links use a full copy.
  if ([IO.Path]::GetExtension($Source) -eq '.pmtiles') {
    try { New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null; return }
    catch { if (Test-Path -LiteralPath $Destination) { throw } }
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Set-TerraSysMapFile {
  param([string]$Source, [string]$Destination, [string]$TransactionId)
  $temporary = "$Destination.activation-$TransactionId.tmp"
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  Copy-TerraSysMapSnapshot -Source $Source -Destination $temporary
  Move-Item -LiteralPath $temporary -Destination $Destination -Force
}

function Assert-TerraSysMapVersion {
  param([string]$ProductRoot, [string]$ProductPath, [string]$ManifestPath)
  foreach ($path in @($ProductPath, $ManifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Map version file is missing: $path" }
  }
  $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
  if (-not $manifest.details.file) { throw "Map version has no complete rich-detail companion: $ManifestPath" }
  $detailsName = [IO.Path]::GetFileName(([string]$manifest.details.file).Replace('\', '/'))
  $detailPath = Join-Path $ProductRoot $detailsName
  foreach ($file in @(
    @{ Path = $ProductPath; Metadata = $manifest.product },
    @{ Path = $detailPath; Metadata = $manifest.details }
  )) {
    if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) { throw "Map archive is missing: $($file.Path)" }
    if ((Get-Item -LiteralPath $file.Path).Length -ne [int64]$file.Metadata.bytes) { throw "Map archive size does not match its manifest: $($file.Path)" }
    $stream = [IO.File]::OpenRead($file.Path)
    try {
      $header = New-Object byte[] 7
      if ($stream.Read($header, 0, 7) -ne 7 -or [Text.Encoding]::ASCII.GetString($header) -ne 'PMTiles') { throw "Invalid map archive header: $($file.Path)" }
    }
    finally { $stream.Dispose() }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file.Path).Hash.ToLowerInvariant() -ne ([string]$file.Metadata.sha256).ToLowerInvariant()) {
      throw "Map archive checksum does not match its manifest: $($file.Path)"
    }
  }
  return $manifest
}

function Restore-TerraSysMapActivation {
  # Caller must hold the pack lock. Originals are never consumed while restoring,
  # so this operation can itself be killed and replayed without losing a version.
  param([string]$ProductRoot, [string]$PackId)
  $paths = Get-TerraSysMapPaths $ProductRoot $PackId
  if (-not (Test-Path -LiteralPath $paths.Journal -PathType Leaf)) { return }
  $journal = Get-Content -Raw -LiteralPath $paths.Journal | ConvertFrom-Json
  if ($journal.schemaVersion -ne 1 -or $journal.packId -ne $PackId -or $journal.transactionId -notmatch '^[a-f0-9]{32}$' -or $journal.phase -notin @('pending', 'committed')) {
    throw "Map activation journal is invalid; preserve it for recovery: $($paths.Journal)"
  }
  $transactionRoot = Join-Path $paths.Root ".$PackId.activation-$($journal.transactionId)"
  if (@($journal.originalFiles).Count -ne $paths.Names.Count) { throw "Incomplete map activation journal: $($paths.Journal)" }
  foreach ($name in $paths.Names) {
    if (@($journal.originalFiles | Where-Object { $_.name -eq $name }).Count -ne 1) { throw "Invalid original map version list: $($paths.Journal)" }
  }
  if ($journal.phase -eq 'pending') {
    foreach ($entry in $journal.originalFiles) {
      $destination = Join-Path $paths.Root ([string]$entry.name)
      if ($entry.existed) {
        $snapshot = Join-Path $transactionRoot ([string]$entry.name)
        if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) { throw "Map recovery snapshot is missing; journal retained: $snapshot" }
        Set-TerraSysMapFile -Source $snapshot -Destination $destination -TransactionId $journal.transactionId
      }
      elseif (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    }
  }
  # 'committed' is written only after all destination replacements succeed.
  # Never erase diagnostics on recovery failure. Removing the journal publishes
  # the stable pair; obsolete private snapshots may then be cleaned best-effort.
  Remove-Item -LiteralPath $paths.Journal -Force
  if (Test-Path -LiteralPath $transactionRoot) {
    $resolvedTransaction = [IO.Path]::GetFullPath($transactionRoot)
    if (-not $resolvedTransaction.StartsWith($paths.Root.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
      throw "Refusing to clean a transaction outside its product root."
    }
    Remove-Item -LiteralPath $resolvedTransaction -Recurse -Force -ErrorAction SilentlyContinue
  }
  foreach ($name in $paths.Names) {
    Remove-Item -LiteralPath (Join-Path $paths.Root "$name.activation-$($journal.transactionId).tmp") -Force -ErrorAction SilentlyContinue
  }
}

function Repair-TerraSysMapActivations {
  param([string]$ProductRoot, [string]$PackId = '')
  if (-not (Test-Path -LiteralPath $ProductRoot -PathType Container)) { return }
  $ids = if ($PackId) { @($PackId) } else {
    @(Get-ChildItem -LiteralPath $ProductRoot -Filter '*.activation.json' -File | ForEach-Object { $_.Name.Substring(0, $_.Name.Length - '.activation.json'.Length) })
  }
  foreach ($id in $ids) {
    $paths = Get-TerraSysMapPaths $ProductRoot $id
    if (-not (Test-Path -LiteralPath $paths.Journal -PathType Leaf)) { continue }
    $operationLock = Enter-TerraSysMapLock $ProductRoot $id
    try { Restore-TerraSysMapActivation $ProductRoot $id }
    finally { $operationLock.Dispose() }
  }
}

function Invoke-TerraSysMapActivation {
  # Caller holds the pack lock throughout candidate validation and activation.
  param([string]$ProductRoot, [string]$PackId, [string]$CandidateProduct = '', [string]$CandidateManifest = '', [switch]$Rollback)
  $paths = Get-TerraSysMapPaths $ProductRoot $PackId
  Restore-TerraSysMapActivation $ProductRoot $PackId
  $currentProduct = Join-Path $paths.Root $paths.Names[0]
  $currentManifest = Join-Path $paths.Root $paths.Names[1]
  $previousProduct = Join-Path $paths.Root $paths.Names[2]
  $previousManifest = Join-Path $paths.Root $paths.Names[3]
  $current = $null
  if ($Rollback) {
    $current = Assert-TerraSysMapVersion $paths.Root $currentProduct $currentManifest
    $null = Assert-TerraSysMapVersion $paths.Root $previousProduct $previousManifest
  }
  else {
    $candidate = Assert-TerraSysMapVersion $paths.Root $CandidateProduct $CandidateManifest
    if ((Test-Path -LiteralPath $currentProduct -PathType Leaf) -and (Test-Path -LiteralPath $currentManifest -PathType Leaf)) {
      try { $current = Assert-TerraSysMapVersion $paths.Root $currentProduct $currentManifest }
      catch { Write-Warning "The existing map version is incomplete; retaining its earlier rollback version." }
    }
  }
  $transactionId = [Guid]::NewGuid().ToString('N')
  $transactionRoot = Join-Path $paths.Root ".$PackId.activation-$transactionId"
  New-Item -ItemType Directory -Path $transactionRoot | Out-Null
  $originalFiles = @()
  foreach ($name in $paths.Names) {
    $source = Join-Path $paths.Root $name
    $exists = Test-Path -LiteralPath $source -PathType Leaf
    if ($exists) { Copy-TerraSysMapSnapshot -Source $source -Destination (Join-Path $transactionRoot $name) }
    $originalFiles += [ordered]@{ name = $name; existed = $exists }
  }
  $journal = [ordered]@{ schemaVersion = 1; packId = $PackId; transactionId = $transactionId; phase = 'pending'; originalFiles = $originalFiles }
  Write-TerraSysMapJournal -Path $paths.Journal -Journal $journal
  try {
    if ($Rollback) {
      Set-TerraSysMapFile (Join-Path $transactionRoot $paths.Names[2]) $currentProduct $transactionId
      Set-TerraSysMapFile (Join-Path $transactionRoot $paths.Names[3]) $currentManifest $transactionId
      Set-TerraSysMapFile (Join-Path $transactionRoot $paths.Names[0]) $previousProduct $transactionId
      Set-TerraSysMapFile (Join-Path $transactionRoot $paths.Names[1]) $previousManifest $transactionId
    }
    else {
      $unchanged = $current -and $current.product.sha256 -eq $candidate.product.sha256 -and $current.details.sha256 -eq $candidate.details.sha256 -and $current.source.sha256 -eq $candidate.source.sha256
      if ($current -and -not $unchanged) {
        Set-TerraSysMapFile (Join-Path $transactionRoot $paths.Names[0]) $previousProduct $transactionId
        Set-TerraSysMapFile (Join-Path $transactionRoot $paths.Names[1]) $previousManifest $transactionId
      }
      Set-TerraSysMapFile $CandidateProduct $currentProduct $transactionId
      Set-TerraSysMapFile $CandidateManifest $currentManifest $transactionId
    }
    $journal.phase = 'committed'
    Write-TerraSysMapJournal -Path $paths.Journal -Journal $journal
  }
  catch {
    $activationError = $_
    try { Restore-TerraSysMapActivation $ProductRoot $PackId }
    catch { throw "Map activation failed and recovery must be retried before use. Journal: $($paths.Journal). $($_.Exception.Message)" }
    throw $activationError
  }
  Restore-TerraSysMapActivation $ProductRoot $PackId
}

function Remove-TerraSysUnusedMapDetails {
  param([string]$ProductRoot, [string]$PackId)
  $paths = Get-TerraSysMapPaths $ProductRoot $PackId
  if (Test-Path -LiteralPath $paths.Journal) { return }
  $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @($paths.Names[1], $paths.Names[3])) {
    $manifestPath = Join-Path $paths.Root $name
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.details.file) { [void]$referenced.Add([IO.Path]::GetFileName(([string]$manifest.details.file).Replace('\', '/'))) }
  }
  Get-ChildItem -LiteralPath $paths.Root -Filter "$PackId.details.*.pmtiles" -File |
    Where-Object { $_.Name -ne "$PackId.details.staged.pmtiles" -and -not $referenced.Contains($_.Name) } |
    Remove-Item -Force
}
