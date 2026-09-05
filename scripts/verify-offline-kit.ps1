param(
  [Parameter(Mandatory = $true)]
  [string]$KitDirectory
)

$ErrorActionPreference = "Stop"
$kit = (Resolve-Path -LiteralPath $KitDirectory).Path.TrimEnd('\')
$manifestPath = Join-Path $kit "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Offline-kit manifest is missing: $manifestPath"
}

$parsedManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$entries = @($parsedManifest)
if ($entries.Count -lt 1) { throw "Offline-kit manifest is empty." }
$verificationPath = Join-Path $kit "verification.json"
if (Test-Path -LiteralPath $verificationPath) {
  Remove-Item -LiteralPath $verificationPath -Force
}
$kitInfoPath = Join-Path $kit "kit-info.json"
if (-not (Test-Path -LiteralPath $kitInfoPath -PathType Leaf)) { throw "Offline-kit metadata is missing." }
$kitInfo = Get-Content -Raw -LiteralPath $kitInfoPath | ConvertFrom-Json

$verifiedBytes = [int64]0
foreach ($entry in $entries) {
  $relative = ([string]$entry.Path).Replace('\', '/')
  $segments = @($relative.Split('/'))
  if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or
      $segments.Count -lt 1 -or $segments -contains '..' -or $segments -contains '.' -or
      $segments -contains '') {
    throw "Unsafe path in offline-kit manifest: $relative"
  }
  # Avoid GetFullPath here: deeply nested browser assets can exceed legacy MAX_PATH.
  $candidate = Join-Path $kit $relative.Replace('/', '\')
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Offline-kit file is missing: $relative"
  }
  $file = Get-Item -LiteralPath $candidate
  if ($file.Length -ne [int64]$entry.Bytes) {
    throw "Offline-kit size mismatch: $relative"
  }
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash.ToLowerInvariant()
  if ($hash -ne ([string]$entry.SHA256).ToLowerInvariant()) {
    throw "Offline-kit checksum mismatch: $relative"
  }
  $verifiedBytes += $file.Length
}

$projectComplete = $false
$imagesComplete = $false
$includesDockerImages = $kitInfo.PSObject.Properties['includesDockerImages'] -and [bool]$kitInfo.includesDockerImages
if ([int]$kitInfo.schemaVersion -ge 5) {
  $contractEntry = "payload/TerraSys/config/offline-kit.json"
  if (-not ($entries.Path -contains $contractEntry)) { throw "Offline-kit build contract is missing: $contractEntry" }
  $contract = Get-Content -Raw -LiteralPath (Join-Path $kit $contractEntry) | ConvertFrom-Json
  if ([int]$contract.schemaVersion -ne 1 -or @($contract.requiredFiles).Count -lt 1 -or
      -not $contract.PSObject.Properties['images'] -or @($contract.images.PSObject.Properties).Count -lt 1) {
    throw "Offline-kit build contract is invalid."
  }
  foreach ($relative in $contract.requiredFiles) {
    $requiredEntry = "payload/TerraSys/$relative"
    if (-not ($entries.Path -contains $requiredEntry)) { throw "Rebuild-ready offline-kit payload is incomplete: $requiredEntry" }
  }
  $projectComplete = $true
  if ($includesDockerImages) {
    $inventory = if ($kitInfo.PSObject.Properties['dockerImages']) { @($kitInfo.dockerImages) } else { @() }
    # Keep the top-level verifier standalone; do not execute scripts from the kit payload.
    foreach ($property in $contract.images.PSObject.Properties) {
      $required = [string]$property.Value
      $digest = if ($required -match '@(sha256:[a-fA-F0-9]{64})$') { $Matches[1] } else { $null }
      $found = $false
      foreach ($image in $inventory) {
        $candidate = ([string]$image).Trim()
        if ($candidate.Equals($required, [StringComparison]::Ordinal) -or
            ($digest -and ($candidate.Equals($digest, [StringComparison]::OrdinalIgnoreCase) -or
              $candidate.EndsWith("@$digest", [StringComparison]::OrdinalIgnoreCase)))) {
          $found = $true
          break
        }
      }
      if (-not $found) { throw "Offline-kit Docker image inventory is incomplete: $required" }
    }
    $imagesComplete = $true
  }
}
else {
  Write-Warning "Legacy offline kit: existing files are verified, but Linux entry points and rebuild inputs are not guaranteed. Refresh the kit to validate rebuild completeness."
}
if ($includesDockerImages -and -not ($entries.Path -contains "docker/terrasys-images.tar")) {
  throw "Offline-kit metadata references a missing Docker image archive."
}
$rebuildReady = $projectComplete -and $imagesComplete

if ($kitInfo.advancedCapabilities) {
  foreach ($relative in @(
    "payload/TerraSys/raw/osm/china/terrasys-core-latest.osm.pbf",
    "payload/TerraSys/raw/osm/china/terrasys-core.manifest.json",
    "payload/TerraSys/products/routing/valhalla/valhalla_tiles.tar",
    "payload/TerraSys/products/encyclopedia/encyclopedia.manifest.json"
  )) {
    if (-not ($entries.Path -contains $relative)) { throw "Advanced offline-kit payload is incomplete: $relative" }
  }
}
if (@($kitInfo.operationalResources).Count) {
  foreach ($relative in @(
    "payload/TerraSys/web/assets/overview/overview.manifest.json",
    "payload/TerraSys/products/weather/latest.geojson",
    "payload/TerraSys/products/weather/weather.manifest.json",
    "payload/TerraSys/products/nautical/seamarks.geojson",
    "payload/TerraSys/products/nautical/nautical.manifest.json",
    "payload/TerraSys/products/encyclopedia/travel-guide.manifest.json"
  )) {
    if (-not ($entries.Path -contains $relative)) { throw "Operational offline-kit payload is incomplete: $relative" }
  }
  $wikipedia = @($entries.Path | Where-Object { $_ -like "payload/TerraSys/products/encyclopedia/wikipedia_zh_all_*.zim" })
  $wikivoyage = @($entries.Path | Where-Object { $_ -like "payload/TerraSys/products/encyclopedia/wikivoyage_zh_all_*.zim" })
  if ($wikipedia.Count -lt 1 -or $wikivoyage.Count -lt 1) {
    throw "Operational offline-kit knowledge archives are incomplete."
  }
}
if ($kitInfo.nominatimIndexIncluded -and -not ($entries.Path -contains $kitInfo.nominatimIndexArchive)) {
  throw "Offline-kit metadata references a missing Nominatim index archive."
}
if ($kitInfo.osmCartoIncluded) {
  $cartoManifestPath = Join-Path $kit "payload\TerraSys\products\osm-carto\osm-carto.manifest.json"
  if (-not (Test-Path -LiteralPath $cartoManifestPath -PathType Leaf)) {
    throw "OSM Carto offline-kit manifest is missing."
  }
  $cartoManifest = Get-Content -Raw -LiteralPath $cartoManifestPath | ConvertFrom-Json
  $cartoSource = "payload/TerraSys/$(([string]$cartoManifest.source.file).Replace('\', '/').TrimStart('/'))"
  foreach ($relative in @(
    [string]$kitInfo.osmCartoArchive,
    "payload/TerraSys/products/osm-carto/osm-carto.manifest.json",
    $cartoSource
  )) {
    if (-not $relative -or -not ($entries.Path -contains $relative)) {
      throw "OSM Carto offline-kit payload is incomplete: $relative"
    }
  }
}

$verification = [ordered]@{
  schemaVersion = 1
  status = "verified"
  projectComplete = $projectComplete
  rebuildReady = $rebuildReady
  verifiedAt = (Get-Date).ToUniversalTime().ToString("o")
  manifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  files = $entries.Count
  bytes = $verifiedBytes
}
$verificationTempPath = "$verificationPath.tmp"
$verificationJson = $verification | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($verificationTempPath, $verificationJson, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $verificationTempPath -Destination $verificationPath -Force

[pscustomobject]@{
  Status = "verified"
  ProjectComplete = $projectComplete
  RebuildReady = $rebuildReady
  Kit = $kit
  Files = $entries.Count
  Bytes = $verifiedBytes
  GiB = [math]::Round($verifiedBytes / 1GB, 2)
}
