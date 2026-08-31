param(
  [string]$RasterUrl = "https://naciscdn.org/naturalearth/50m/raster/GRAY_50M_SR_OB.zip"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$rawDirectory = Join-Path $root "raw\natural-earth"
$outputDirectory = Join-Path $root "web\assets\overview"
$archive = Join-Path $rawDirectory "GRAY_50M_SR_OB.zip"
$tiff = Join-Path $rawDirectory "GRAY_50M_SR_OB.tif"
$image = Join-Path $outputDirectory "gray-earth.jpg"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $rawDirectory, $outputDirectory | Out-Null
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
  $archivePart = "$archive.part"
  curl.exe --fail --location --continue-at - --connect-timeout 20 --retry 8 --retry-delay 5 --retry-all-errors `
    --speed-limit 1024 --speed-time 120 --output $archivePart $RasterUrl
  $downloadExitCode = $LASTEXITCODE
  if ($downloadExitCode -eq 33 -and (Test-Path -LiteralPath $archivePart -PathType Leaf)) {
    Write-Warning "The Natural Earth CDN rejected the saved byte range; restarting this staging download once."
    Remove-Item -LiteralPath $archivePart -Force
    curl.exe --fail --location --connect-timeout 20 --retry 8 --retry-delay 5 --retry-all-errors `
      --speed-limit 1024 --speed-time 120 --output $archivePart $RasterUrl
    $downloadExitCode = $LASTEXITCODE
  }
  if ($downloadExitCode -ne 0) { throw "Downloading the Natural Earth raster failed with exit code $downloadExitCode." }
  Move-Item -LiteralPath $archivePart -Destination $archive -Force
}
if (-not (Test-Path -LiteralPath $tiff -PathType Leaf)) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq "GRAY_50M_SR_OB.tif" } | Select-Object -First 1
    if (-not $entry) { throw "Natural Earth archive does not contain the expected TIFF." }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tiff, $true)
  }
  finally { $zip.Dispose() }
}

foreach ($asset in @(
  @{ Name = "countries.geojson"; Url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson" },
  @{ Name = "places.geojson"; Url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_populated_places_simple.geojson" }
)) {
  $target = Join-Path $outputDirectory $asset.Name
  curl.exe --fail --location --retry 5 --retry-delay 3 --output "$target.part" $asset.Url
  if ($LASTEXITCODE -ne 0) { throw "Downloading $($asset.Name) failed." }
  Move-Item -LiteralPath "$target.part" -Destination $target -Force
}

if (-not (docker image ls -q "terrasys-api:1")) {
  docker compose --env-file (Join-Path $root "services\.env") -f (Join-Path $root "services\docker-compose.yml") build api
  if ($LASTEXITCODE -ne 0) { throw "Building the local image converter failed." }
}
$conversion = @'
import math
from PIL import Image

source = Image.open('/data/raw/natural-earth/GRAY_50M_SR_OB.tif').convert('RGB')
# A MapLibre image source is uploaded as one WebGL texture. Keep it within
# the common 4096px hardware limit. Natural Earth is equirectangular, while
# MapLibre uses Web Mercator, so warp latitude before overlaying boundaries.
output_size = 4096
source = source.resize((output_size, output_size // 2), Image.Resampling.LANCZOS)

def source_y(output_y):
    normalized_y = output_y / output_size
    latitude = math.atan(math.sinh(math.pi * (1 - 2 * normalized_y)))
    return (math.pi / 2 - latitude) / math.pi * source.height

mesh = []
strip_height = 8
for top in range(0, output_size, strip_height):
    bottom = min(top + strip_height, output_size)
    source_top = source_y(top)
    source_bottom = source_y(bottom)
    mesh.append((
        (0, top, output_size, bottom),
        (0, source_top, 0, source_bottom, source.width, source_bottom, source.width, source_top)
    ))

mercator = source.transform(
    (output_size, output_size),
    Image.Transform.MESH,
    mesh,
    resample=Image.Resampling.BICUBIC
)
mercator.save('/data/web/assets/overview/gray-earth.jpg', quality=86, optimize=True, progressive=True)
'@
docker run --rm --user 0 -v "${root}:/data" --entrypoint python terrasys-api:1 -c $conversion
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) { throw "Converting the Natural Earth raster failed." }

$files = @(Get-ChildItem -LiteralPath $outputDirectory -File | Where-Object { $_.Name -ne "overview.manifest.json" })
$manifest = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  snapshot = "Natural Earth 5.1 / raster 3.2"
  sourceUrls = @($RasterUrl, "https://github.com/nvkelso/natural-earth-vector")
  bytes = ($files | Measure-Object Length -Sum).Sum
  files = @($files | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() } })
  attribution = "Made with Natural Earth"
}
[IO.File]::WriteAllText((Join-Path $outputDirectory "overview.manifest.json"), ($manifest | ConvertTo-Json -Depth 6), $utf8NoBom)
Get-ChildItem -LiteralPath $outputDirectory -File | Select-Object Name, Length, LastWriteTime
