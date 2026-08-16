$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Join-Path $root "runtime") | Out-Null

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  throw "curl.exe was not found on PATH."
}

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
  $i = 0

  foreach ($file in $files) {
    $i++
    $dest = Join-Path $target $file.name
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq [int64]$file.size)) {
      continue
    }
    # raw.githubusercontent.com is unreliable on some server networks. jsDelivr
    # distributes the same immutable branch content; retain the GitHub API size
    # as an independent post-download check.
    $encodedFile = [uri]::EscapeDataString([string]$file.name)
    Invoke-Download `
      -Url "https://cdn.jsdelivr.net/gh/maplibre/demotiles@gh-pages/font/$encoded/$encodedFile" `
      -OutFile $dest
    if ((Get-Item $dest).Length -ne [int64]$file.size) {
      throw "Glyph size mismatch for $font/$($file.name)."
    }
    if ($i % 50 -eq 0) {
      Write-Host "$font $i / $($files.Count)"
    }
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
