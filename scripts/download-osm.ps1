$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$osmiumImage = "terrasys-osmium:1"
$items = @(
  @{
    Name = "china"
    Dir = "raw\osm\china"
    Pbf = "https://download.openstreetmap.fr/extracts/asia/china-latest.osm.pbf"
    State = "https://download.openstreetmap.fr/extracts/asia/china.state.txt"
  }
)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  throw "curl.exe was not found on PATH."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH."
}

if (-not (docker image ls -q $osmiumImage)) {
  docker build -t $osmiumImage (Join-Path $root "services\tools\osmium")
  Assert-NativeSuccess "Building the Osmium image"
}

foreach ($item in $items) {
  $dir = Join-Path $root $item.Dir
  New-Item -ItemType Directory -Force -Path $dir | Out-Null

  $pbfPath = Join-Path $dir "$($item.Name)-latest.osm.pbf"
  $statePath = Join-Path $dir "$($item.Name).state.txt"
  $pbfPart = Join-Path $dir "$($item.Name)-staged.osm.pbf"
  $statePart = "$statePath.part"

  try {
    Write-Host "Downloading $($item.Name) to a staging file..."
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $pbfPart $item.Pbf
    Assert-NativeSuccess "Downloading $($item.Name) PBF"
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $statePart $item.State
    Assert-NativeSuccess "Downloading $($item.Name) state"

    if ((Get-Item $pbfPart).Length -lt 1MB) {
      throw "$($item.Name) PBF is unexpectedly small."
    }

    $containerPart = "/data/$($item.Dir.Replace('\', '/'))/$($item.Name)-staged.osm.pbf"
    docker run --rm -v "${root}:/data" $osmiumImage fileinfo -e $containerPart | Out-Host
    Assert-NativeSuccess "Reading $($item.Name) PBF metadata"
    docker run --rm -v "${root}:/data" $osmiumImage check-refs $containerPart | Out-Host
    Assert-NativeSuccess "Checking $($item.Name) PBF references"

    if (Test-Path $pbfPath) {
      Copy-Item -LiteralPath $pbfPath -Destination "$pbfPath.previous" -Force
    }
    Move-Item -LiteralPath $pbfPart -Destination $pbfPath -Force
    Move-Item -LiteralPath $statePart -Destination $statePath -Force
  }
  finally {
    if (Test-Path $pbfPart) { Remove-Item -LiteralPath $pbfPart -Force }
    if (Test-Path $statePart) { Remove-Item -LiteralPath $statePart -Force }
  }
}

$polygonDir = Join-Path $root "raw\osm\polygons"
New-Item -ItemType Directory -Force -Path $polygonDir | Out-Null
foreach ($province in @("jiangsu", "anhui")) {
  $target = Join-Path $polygonDir "$province.poly"
  $part = "$target.part"
  try {
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $part `
      "https://download.openstreetmap.fr/polygons/asia/china/$province.poly"
    Assert-NativeSuccess "Downloading $province polygon"
    Move-Item -LiteralPath $part -Destination $target -Force
  }
  finally {
    if (Test-Path $part) { Remove-Item -LiteralPath $part -Force }
  }
}

Get-ChildItem (Join-Path $root "raw\osm\china") -Recurse -File |
  Where-Object { $_.Extension -in ".pbf", ".txt" } |
  Select-Object FullName, Length, LastWriteTime
