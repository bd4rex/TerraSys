$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root "raw\osm\china\terrasys-core-latest.osm.pbf"
$sourceManifest = Join-Path $root "raw\osm\china\terrasys-core.manifest.json"
$workDir = Join-Path $root "tmp\reference-search"
$filtered = Join-Path $workDir "named-nodes.osm.pbf"
$sequence = Join-Path $workDir "named-nodes.geojsonseq"
$containerSequence = "/tmp/terrasys-named-nodes.geojsonseq"
$osmiumImage = "terrasys-osmium:1"

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

if (-not (Test-Path -LiteralPath $source)) {
  throw "Shared province source PBF is missing. Run D:\TerraSys\build-capability-source.cmd first."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH."
}
docker info *> $null
Assert-NativeSuccess "Connecting to Docker"

if (-not (docker image ls -q $osmiumImage)) {
  docker build -t $osmiumImage (Join-Path $root "services\tools\osmium")
  Assert-NativeSuccess "Building the Osmium image"
}

New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$sourceTimestamp = $null
if (Test-Path -LiteralPath $sourceManifest) {
  $manifest = Get-Content -Raw -LiteralPath $sourceManifest | ConvertFrom-Json
  $sourceTimestamp = [string]$manifest.source.updatedAt
}
$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()

try {
  Write-Host "Extracting named OSM nodes..."
  docker run --rm -v "${root}:/data" $osmiumImage tags-filter -R `
    /data/raw/osm/china/terrasys-core-latest.osm.pbf n/name `
    -o /data/tmp/reference-search/named-nodes.osm.pbf -O
  Assert-NativeSuccess "Filtering named OSM nodes"

  Write-Host "Exporting the local reference index..."
  docker run --rm -v "${root}:/data" $osmiumImage export `
    /data/tmp/reference-search/named-nodes.osm.pbf -f geojsonseq `
    -o /data/tmp/reference-search/named-nodes.geojsonseq -O
  Assert-NativeSuccess "Exporting named OSM nodes"

  docker cp $sequence "terrasys-api:$containerSequence"
  Assert-NativeSuccess "Copying the reference index into the API container"
  $arguments = @("python", "-m", "app.import_reference", "--input", $containerSequence, "--source-sha256", $sourceHash)
  if ($sourceTimestamp) { $arguments += @("--source-updated-at", $sourceTimestamp) }
  docker exec terrasys-api @arguments
  Assert-NativeSuccess "Importing the reference search index"
}
finally {
  try {
    docker exec --user 0 terrasys-api rm -f $containerSequence 2>$null | Out-Null
  }
  catch {
    Write-Warning "Could not remove the temporary file from the API container."
  }
  foreach ($path in @($filtered, $sequence)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
}
