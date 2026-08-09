param(
  [Parameter(Mandatory = $true)]
  [string]$PackId
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "catalog-utils.ps1")
$catalog = Get-TerraSysExpandedCatalog -Root $root
$pack = @($catalog.datasets) | Where-Object { $_.id -eq $PackId } | Select-Object -First 1
if (-not $pack) { throw "Unknown region pack: $PackId" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe was not found on PATH." }

$polygonRoot = Join-Path $root "raw\osm\polygons"
New-Item -ItemType Directory -Force -Path $polygonRoot | Out-Null
foreach ($member in @($pack.members)) {
  $target = Join-Path $polygonRoot "$($member.id).poly"
  $staged = "$target.part"
  try {
    Write-Host "Downloading $($member.name) boundary..."
    curl.exe -L --fail --retry 3 --retry-delay 5 -o $staged $member.polygonUrl
    if ($LASTEXITCODE -ne 0) { throw "Downloading $($member.name) boundary failed." }
    if ((Get-Item -LiteralPath $staged).Length -lt 100) { throw "$($member.name) boundary is unexpectedly small." }
    $firstLine = Get-Content -LiteralPath $staged -TotalCount 1
    if (-not $firstLine.Trim()) { throw "$($member.name) boundary is empty." }
    Move-Item -LiteralPath $staged -Destination $target -Force
  }
  finally {
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
  }
}

Get-Item (@($pack.members) | ForEach-Object { Join-Path $polygonRoot "$($_.id).poly" }) |
  Select-Object FullName, Length, LastWriteTime
