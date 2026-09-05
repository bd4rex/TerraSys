param(
  [Parameter(Mandatory = $true)]
  [string]$KitDirectory,
  [switch]$SkipDockerImages
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "offline-kit-support.ps1")
$offlineRoot = [IO.Path]::GetFullPath((Join-Path $root "offline-kit")).TrimEnd([char[]]@('\', '/'))
$kit = [IO.Path]::GetFullPath($KitDirectory).TrimEnd([char[]]@('\', '/'))
if (-not $kit.StartsWith("$offlineRoot$([IO.Path]::DirectorySeparatorChar)", $(if ([IO.Path]::DirectorySeparatorChar -eq "\") { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
  throw "KitDirectory must be an existing child of $offlineRoot."
}
if (-not (Test-Path -LiteralPath (Join-Path $kit "kit-info.json") -PathType Leaf)) {
  throw "The target is not a complete offline kit: $kit"
}

$payload = Join-Path $kit "payload\TerraSys"
$utf8 = New-Object Text.UTF8Encoding($false)
$infoPath = Join-Path $kit "kit-info.json"
$info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
$contract = Get-TerraSysOfflineKitContract -Root $root
$images = @(Get-TerraSysOfflineKitImages -Root $root)
if ($SkipDockerImages -and $info.PSObject.Properties['includesDockerImages'] -and $info.includesDockerImages) {
  $existingImages = if ($info.PSObject.Properties['dockerImages']) { @($info.dockerImages) } else { @() }
  $missingImages = @(Get-TerraSysOfflineKitMissingImages -Contract $contract -Images $existingImages)
  if ($missingImages.Count) {
    throw "Cannot skip Docker image refresh: the existing image inventory is missing $($missingImages -join ', '). Refresh with Docker images before upgrading this kit."
  }
}

function Copy-PayloadFile([string]$Source, [string]$RelativePath) {
  $destination = Join-Path $payload $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination -Force
}

Copy-TerraSysOfflineProject -Root $root -Destination $payload

$mapPackState = Join-Path $root "data\maintenance\map-pack-state.json"
if (Test-Path -LiteralPath $mapPackState -PathType Leaf) {
  Copy-PayloadFile $mapPackState "data\maintenance\map-pack-state.json"
}

Copy-Item -LiteralPath (Join-Path $root "docs\OFFLINE_RECOVERY.md") -Destination (Join-Path $kit "README-OFFLINE.md") -Force
Copy-Item -LiteralPath (Join-Path $root "scripts\restore-offline-kit.ps1") -Destination (Join-Path $kit "restore-offline-kit.ps1") -Force
Copy-Item -LiteralPath (Join-Path $root "scripts\verify-offline-kit.ps1") -Destination (Join-Path $kit "verify-offline-kit.ps1") -Force

if (-not $SkipDockerImages) {
  Write-Host "Refreshing Docker image archive..."
  $archive = Join-Path $kit "docker/terrasys-images.tar"
  $stagedArchive = "$archive.staged"
  docker save --output $stagedArchive $images
  if ($LASTEXITCODE -ne 0) { throw "Docker image export failed; previous archive retained." }
  Move-Item -LiteralPath $stagedArchive -Destination $archive -Force
}

$info | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 5 -Force
if (-not $SkipDockerImages) {
  $info | Add-Member -NotePropertyName includesDockerImages -NotePropertyValue $true -Force
  $info | Add-Member -NotePropertyName dockerImages -NotePropertyValue $images -Force
}
$info | Add-Member -NotePropertyName refreshedAt -NotePropertyValue ([DateTimeOffset]::Now.ToUniversalTime().ToString("o")) -Force
[IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json -Depth 8), $utf8)

Write-Host "Hashing refreshed offline kit..."
$manifestPath = Join-Path $kit "manifest.json"
$manifest = Get-ChildItem -LiteralPath $kit -Recurse -File |
  Where-Object { $_.FullName -ne $manifestPath -and $_.Name -notin @("verification.json", "verification.json.tmp") } |
  Sort-Object FullName |
  ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [ordered]@{
      Path = $_.FullName.Substring($kit.Length + 1).Replace('\', '/')
      Bytes = $_.Length
      SHA256 = $hash.Hash.ToLowerInvariant()
    }
  }
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), $utf8)

& (Join-Path $PSScriptRoot "verify-offline-kit.ps1") -KitDirectory $kit
Write-Host "Offline recovery kit refreshed: $kit"
