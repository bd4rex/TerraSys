$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Join-Path $root "runtime") | Out-Null

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  throw "curl.exe was not found on PATH."
}
$curlSupportsParallel = ((curl.exe --help all 2>$null) -join "`n") -match '--parallel\s'

function Invoke-Download {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile
  )

  $dir = Split-Path -Parent $OutFile
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $part = "$OutFile.part"
  try {
    curl.exe -L --fail --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 3 --retry-all-errors -o $part $Url
    if ($LASTEXITCODE -ne 0) {
      throw "Downloading asset failed with exit code $LASTEXITCODE`: $Url"
    }
    if ((Get-Item $part).Length -eq 0) {
      throw "Downloaded asset is empty: $Url"
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
  }
  finally {
    if (Test-Path $part) { Remove-Item -LiteralPath $part -Force }
  }
}

function Invoke-ParallelDownloads {
  param(
    [Parameter(Mandatory = $true)][object[]]$Downloads,
    [int]$ThrottleLimit = 8
  )

  if (-not $Downloads.Count) { return }
  if (-not $curlSupportsParallel) {
    foreach ($download in $Downloads) {
      Invoke-Download -Url $download.Url -OutFile $download.OutFile
      if ((Get-Item $download.OutFile).Length -ne [int64]$download.ExpectedSize) {
        throw "Downloaded size mismatch: $($download.Label)"
      }
    }
    return
  }

  $arguments = New-Object System.Collections.Generic.List[string]
  foreach ($argument in @(
    "--silent", "--show-error", "--location", "--fail", "--connect-timeout", "20",
    "--max-time", "300", "--retry", "3", "--retry-delay", "3", "--retry-all-errors",
    "--parallel", "--parallel-immediate", "--parallel-max", "$ThrottleLimit"
  )) { $arguments.Add($argument) }

  foreach ($download in $Downloads) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $download.OutFile) | Out-Null
    $part = "$($download.OutFile).part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    $arguments.Add("--output")
    $arguments.Add($part)
    $arguments.Add("--url")
    $arguments.Add([string]$download.Url)
  }

  try {
    $curlArguments = $arguments.ToArray()
    curl.exe @curlArguments
    if ($LASTEXITCODE -ne 0) {
      throw "Parallel asset download failed with exit code $LASTEXITCODE."
    }
    foreach ($download in $Downloads) {
      $part = "$($download.OutFile).part"
      if (-not (Test-Path -LiteralPath $part -PathType Leaf) -or
          (Get-Item -LiteralPath $part).Length -ne [int64]$download.ExpectedSize) {
        throw "Downloaded size mismatch: $($download.Label)"
      }
      Move-Item -LiteralPath $part -Destination $download.OutFile -Force
    }
  }
  finally {
    foreach ($download in $Downloads) {
      $part = "$($download.OutFile).part"
      if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    }
  }
}

Write-Host "Downloading MapLibre and PMTiles browser assets..."
Invoke-Download `
  -Url "https://unpkg.com/maplibre-gl@5.6.0/dist/maplibre-gl.js" `
  -OutFile (Join-Path $root "web\vendor\maplibre\maplibre-gl.js")
Invoke-Download `
  -Url "https://unpkg.com/maplibre-gl@5.6.0/dist/maplibre-gl.css" `
  -OutFile (Join-Path $root "web\vendor\maplibre\maplibre-gl.css")
Invoke-Download `
  -Url "https://unpkg.com/pmtiles@4.3.0/dist/pmtiles.js" `
  -OutFile (Join-Path $root "web\vendor\pmtiles\pmtiles.js")
Invoke-Download `
  -Url "https://unpkg.com/maplibre-contour@0.1.0/dist/index.min.js" `
  -OutFile (Join-Path $root "web\vendor\maplibre-contour\index.min.js")
Invoke-Download `
  -Url "https://unpkg.com/lucide@0.468.0/dist/umd/lucide.min.js" `
  -OutFile (Join-Path $root "web\vendor\lucide\lucide.min.js")

Write-Host "Downloading OpenFreeMap Liberty style and sprites..."
Invoke-Download `
  -Url "https://tiles.openfreemap.org/styles/liberty" `
  -OutFile (Join-Path $root "web\styles\liberty\openfreemap-liberty.json")
Invoke-Download `
  -Url "https://tiles.openfreemap.org/sprites/ofm_f384/ofm.json" `
  -OutFile (Join-Path $root "web\assets\sprites\ofm_f384\ofm.json")
Invoke-Download `
  -Url "https://tiles.openfreemap.org/sprites/ofm_f384/ofm.png" `
  -OutFile (Join-Path $root "web\assets\sprites\ofm_f384\ofm.png")
Invoke-Download `
  -Url "https://tiles.openfreemap.org/sprites/ofm_f384/ofm@2x.json" `
  -OutFile (Join-Path $root "web\assets\sprites\ofm_f384\ofm@2x.json")
Invoke-Download `
  -Url "https://tiles.openfreemap.org/sprites/ofm_f384/ofm@2x.png" `
  -OutFile (Join-Path $root "web\assets\sprites\ofm_f384\ofm@2x.png")

Write-Host "Downloading MapLibre demo glyphs for Noto Sans Regular/Bold/Italic..."
$fontRoot = Join-Path $root "web\assets\glyphs"
$fonts = @("Noto Sans Regular", "Noto Sans Bold", "Noto Sans Italic")

foreach ($font in $fonts) {
  $target = Join-Path $fontRoot $font
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  $encoded = [uri]::EscapeDataString($font)
  $items = Invoke-RestMethod -Uri "https://api.github.com/repos/maplibre/demotiles/contents/font/$encoded`?ref=gh-pages"
  $files = $items | Where-Object { $_.type -eq "file" -and $_.name -like "*.pbf" }
  $pending = New-Object System.Collections.Generic.List[object]

  foreach ($file in $files) {
    $dest = Join-Path $target $file.name
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq [int64]$file.size)) {
      continue
    }
    # raw.githubusercontent.com is unreliable on some server networks. jsDelivr
    # distributes the same immutable branch content; retain the GitHub API size
    # as an independent post-download check.
    $encodedFile = [uri]::EscapeDataString([string]$file.name)
    $pending.Add([pscustomobject]@{
      Url = "https://cdn.jsdelivr.net/gh/maplibre/demotiles@gh-pages/font/$encoded/$encodedFile"
      OutFile = $dest
      ExpectedSize = [int64]$file.size
      Label = "$font/$($file.name)"
    })
  }

  $batchSize = 32
  for ($offset = 0; $offset -lt $pending.Count; $offset += $batchSize) {
    $batch = @($pending | Select-Object -Skip $offset -First $batchSize)
    Invoke-ParallelDownloads -Downloads $batch -ThrottleLimit 8
    $ready = [math]::Min($files.Count, $files.Count - $pending.Count + $offset + $batch.Count)
    Write-Host "$font $ready / $($files.Count)"
  }
}

Invoke-Download `
  -Url "https://cdn.jsdelivr.net/gh/unvt/nsft@main/fonts/SIL%20Open%20Font%20License%20FOR%20NotoSans.txt" `
  -OutFile (Join-Path $fontRoot "SIL Open Font License FOR MapLibre Noto Sans.txt")

Get-ChildItem $fontRoot -Directory | ForEach-Object {
  $items = Get-ChildItem $_.FullName -Filter *.pbf -File
  $sum = ($items | Measure-Object Length -Sum).Sum
  [pscustomobject]@{
    Font = $_.Name
    Files = $items.Count
    MB = [math]::Round($sum / 1MB, 1)
  }
} | Format-Table -AutoSize

$manifest = Get-ChildItem (Join-Path $root "web\vendor"), (Join-Path $root "web\assets") -Recurse -File |
  ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [pscustomobject]@{
      Path = $_.FullName.Substring($root.Length + 1).Replace("\", "/")
      Bytes = $_.Length
      SHA256 = $hash.Hash.ToLowerInvariant()
    }
  }
$manifest | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $root "runtime\web-assets-manifest.json")
