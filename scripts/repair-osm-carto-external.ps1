param(
  [string]$Image = "",
  [string]$DataVolume = "terrasys_osm_carto_data"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$imageDigest = "sha256:b6a79da39b6d0758368f7c62d22e49dd3ec59e78b194a5ef9dee2723b1f3fa79"
$canonicalImage = "overv/openstreetmap-tile-server@$imageDigest"
$envFile = Join-Path $root "services\.env"
if (-not $Image -and (Test-Path -LiteralPath $envFile -PathType Leaf)) {
  $imageLine = Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^\s*OSM_CARTO_IMAGE=' } | Select-Object -First 1
  if ($imageLine) { $Image = ([string]$imageLine).Substring(([string]$imageLine).IndexOf('=') + 1).Trim() }
}
if (-not $Image) { $Image = $canonicalImage }
if (-not $Image.EndsWith("@$imageDigest", [StringComparison]::OrdinalIgnoreCase)) {
  throw "The OSM Carto repair image must be pinned to the approved digest $imageDigest."
}
$externalRoot = Join-Path $root "raw\osm\carto\external"
$externalConfig = Join-Path $root "config\osm-carto\external-data.local.yml"
$repairScript = Join-Path $root "scripts\osm-carto-repair.sh"
$normalizedRepairScript = Join-Path $root "runtime\osm-carto-support\repair-external.sh"
$network = "services_default"
$assetContainer = "terrasys-osm-carto-assets"

$required = @(
  "simplified-water-polygons-split-3857.zip",
  "water-polygons-split-3857.zip",
  "antarctica-icesheet-polygons-3857.zip",
  "antarctica-icesheet-outlines-3857.zip",
  "ne_110m_admin_0_boundary_lines_land.zip"
)
foreach ($name in $required) {
  $path = Join-Path $externalRoot $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing OSM Carto external dataset: $path"
  }
}
$normalizedRepairRoot = Split-Path -Parent $normalizedRepairScript
New-Item -ItemType Directory -Force -Path $normalizedRepairRoot | Out-Null
$repairContents = (Get-Content -Raw -LiteralPath $repairScript).Replace("`r`n", "`n")
[IO.File]::WriteAllText($normalizedRepairScript, $repairContents, (New-Object Text.UTF8Encoding($false)))

if (-not (docker network ls -q --filter "name=^${network}$")) {
  docker network create $network | Out-Null
}
if (docker ps -aq --filter "name=^${assetContainer}$") {
  docker rm -f $assetContainer | Out-Null
}
try {
  docker run -d --rm --name $assetContainer --network $network `
    -v "${externalRoot}:/external:ro" `
    --entrypoint python3 $Image `
    -m http.server 8090 --bind 0.0.0.0 --directory /external | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not start the local Carto dataset server." }

  $assetServerReady = $false
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    docker exec $assetContainer python3 -c `
      "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8090/ne_110m_admin_0_boundary_lines_land.zip', timeout=2).read(1)" *> $null
    if ($LASTEXITCODE -eq 0) {
      $assetServerReady = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $assetServerReady) { throw "The local Carto dataset server did not become ready." }

  $repairArgs = @(
    "run", "--rm", "--name", "terrasys-osm-carto-repair",
    "--network", $network, "--shm-size", "1g",
    "-v", "${DataVolume}:/data/database/",
    "-v", "${externalConfig}:/repair/external-data.yml:ro",
    "-v", "${normalizedRepairScript}:/repair/repair-external.sh:ro",
    "--entrypoint", "bash", $Image, "/repair/repair-external.sh"
  )
  & docker @repairArgs
  if ($LASTEXITCODE -ne 0) { throw "Repairing the OSM Carto external tables failed." }
} finally {
  if (docker ps -aq --filter "name=^${assetContainer}$") {
    docker rm -f $assetContainer | Out-Null
  }
}

Write-Host "OSM Carto external tables are complete."
