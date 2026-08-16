$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$osmiumImage = "terrasys-osmium:1"
$items = @(
  @{
    Name = "china"
    Dir = "raw\osm\china"
    Pbf = "https://download.openstreetmap.fr/extracts/asia/china-latest.osm.pbf"
    State = "https://download.openstreetmap.fr/extracts/asia/china.state.txt"
    MaxMissingReferences = 100000
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
  $containerPart = "/data/$($item.Dir.Replace('\', '/'))/$($item.Name)-staged.osm.pbf"

  try {
    $stagedComplete = $false
    if (Test-Path -LiteralPath $pbfPart -PathType Leaf) {
      docker run --rm -v "${root}:/data" $osmiumImage fileinfo -e $containerPart *> $null
      $stagedComplete = $LASTEXITCODE -eq 0
    }
    if (-not $stagedComplete) {
      Write-Host "Downloading $($item.Name) to a resumable staging file..."
      curl.exe --fail --location --continue-at - --connect-timeout 20 --retry 8 --retry-delay 5 --retry-all-errors `
        --speed-limit 1024 --speed-time 120 --output $pbfPart $item.Pbf
      $downloadExitCode = $LASTEXITCODE
      if ($downloadExitCode -eq 33 -and (Test-Path -LiteralPath $pbfPart -PathType Leaf)) {
        Write-Warning "The server rejected the saved byte range; restarting this staging download once."
        Remove-Item -LiteralPath $pbfPart -Force
        curl.exe --fail --location --connect-timeout 20 --retry 8 --retry-delay 5 --retry-all-errors `
          --speed-limit 1024 --speed-time 120 --output $pbfPart $item.Pbf
        $downloadExitCode = $LASTEXITCODE
      }
      if ($downloadExitCode -ne 0) { throw "Downloading $($item.Name) PBF failed with exit code $downloadExitCode." }
    }
    else {
      Write-Host "Reusing the complete staged $($item.Name) PBF."
    }
    curl.exe --fail --location --connect-timeout 20 --max-time 120 --retry 5 --retry-delay 5 --retry-all-errors `
      --output $statePart $item.State
    Assert-NativeSuccess "Downloading $($item.Name) state"

    if ((Get-Item $pbfPart).Length -lt 1MB) {
      throw "$($item.Name) PBF is unexpectedly small."
    }

    docker run --rm -v "${root}:/data" $osmiumImage fileinfo -e $containerPart | Out-Host
    Assert-NativeSuccess "Reading $($item.Name) PBF metadata"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $referenceCheck = docker run --rm -v "${root}:/data" $osmiumImage check-refs $containerPart 2>&1
    $referenceExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    $referenceLines = @($referenceCheck | ForEach-Object { "$_" })
    $referenceLines | ForEach-Object { Write-Host $_ }
    if ($referenceExitCode -ne 0) {
      $missingCounts = @([regex]::Matches(
        ($referenceLines -join "`n"),
        '(?:Nodes in ways|Members in relations) missing:\s+(\d+)'
      ) | ForEach-Object { [int64]$_.Groups[1].Value })
      $missingTotal = [int64](($missingCounts | Measure-Object -Sum).Sum)
      if ($missingCounts.Count -gt 0 -and $missingTotal -le [int64]$item.MaxMissingReferences) {
        Write-Warning "$($item.Name) contains $missingTotal references omitted at the provider's outer extract boundary; the configured limit is $($item.MaxMissingReferences)."
      }
      else {
        throw "Checking $($item.Name) PBF references failed with exit code $referenceExitCode."
      }
    }

    if (Test-Path $pbfPath) {
      Copy-Item -LiteralPath $pbfPath -Destination "$pbfPath.previous" -Force
    }
    Move-Item -LiteralPath $pbfPart -Destination $pbfPath -Force
    Move-Item -LiteralPath $statePart -Destination $statePath -Force
  }
  finally {
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
