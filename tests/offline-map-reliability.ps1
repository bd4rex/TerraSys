$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts/offline-map-snapshot.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("terrasys-map-snapshot-" + [Guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $fixture 'source'
$productRoot = Join-Path $sourceRoot 'products/tiles/pmtiles'
$destination = Join-Path $fixture 'copied'
$dataset = [pscustomobject]@{ id = 'test-pack'; url = '/tiles/test-pack.pmtiles'; manifestUrl = '/tiles/test-pack.manifest.json' }
function Assert-Snapshot([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
  New-Item -ItemType Directory -Force -Path $productRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $productRoot 'test-pack.pmtiles'), 'PMTiles-base')
  [IO.File]::WriteAllText((Join-Path $productRoot 'test-pack.details.hash.pmtiles'), 'PMTiles-detail')
  [IO.File]::WriteAllText((Join-Path $sourceRoot 'source.pbf'), 'source')
  $manifest = [ordered]@{
    product = @{ bytes = 12; sha256 = (Get-FileHash (Join-Path $productRoot 'test-pack.pmtiles')).Hash }
    details = @{ bytes = 14; file = 'products/tiles/pmtiles/test-pack.details.hash.pmtiles'; sha256 = (Get-FileHash (Join-Path $productRoot 'test-pack.details.hash.pmtiles')).Hash }
    source = @{ file = 'source.pbf'; sha256 = (Get-FileHash (Join-Path $sourceRoot 'source.pbf')).Hash }
  }
  [IO.File]::WriteAllText((Join-Path $productRoot 'test-pack.manifest.json'), ($manifest | ConvertTo-Json -Depth 6))
  $result = Copy-TerraSysOfflineMap -Root $sourceRoot -Destination $destination -Dataset $dataset
  Assert-Snapshot ($result.id -eq 'test-pack') 'A complete map was not copied.'
  $lock = Enter-TerraSysMapLock -ProductRoot $productRoot -PackId 'test-pack'
  try {
    $rejected = $false
    try { Copy-TerraSysOfflineMap -Root $sourceRoot -Destination $destination -Dataset $dataset | Out-Null } catch { $rejected = $_.Exception.Message -match 'Another operation' }
    Assert-Snapshot $rejected 'Map snapshot ignored an active mutation lock.'
  }
  finally { $lock.Dispose() }
  $journal = Join-Path $productRoot 'test-pack.activation.json'
  [IO.File]::WriteAllText($journal, '{}')
  $rejected = $false
  try { Copy-TerraSysOfflineMap -Root $sourceRoot -Destination $destination -Dataset $dataset | Out-Null } catch { $rejected = $_.Exception.Message -match 'recovery before backup' }
  Assert-Snapshot $rejected 'Interrupted activation was copied as a stable map.'
  Remove-Item -LiteralPath $journal
  [IO.File]::WriteAllText((Join-Path $sourceRoot 'source.pbf'), 'changed-source')
  $rejected = $false
  try { Copy-TerraSysOfflineMap -Root $sourceRoot -Destination $destination -Dataset $dataset | Out-Null } catch { $rejected = $_.Exception.Message -match 'inconsistent offline snapshot' }
  Assert-Snapshot $rejected 'Map source hash mismatch was accepted.'
  Write-Host 'Offline map snapshot tests passed (4 scenarios).'
}
finally {
  $resolvedFixture = [IO.Path]::GetFullPath($fixture)
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixture) -notlike 'terrasys-map-snapshot-*') { throw 'Unsafe fixture cleanup path.' }
  if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
