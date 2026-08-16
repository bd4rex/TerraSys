param(
  [ValidateSet(0, 1)][int]$KeepPrevious = 1,
  [switch]$ConfirmPrune
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $root "data\maintenance\shared-index-state.json"
$routingRoot = [IO.Path]::GetFullPath((Join-Path $root "products\routing"))
$versionsRoot = Join-Path $routingRoot "versions"
$utf8 = New-Object Text.UTF8Encoding($false)

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Get-ActiveMount([string]$Container, [string]$Destination, [string]$Property) {
  $inspect = (docker inspect $Container | ConvertFrom-Json)[0]
  Assert-NativeSuccess "Inspecting $Container"
  $mount = $inspect.Mounts | Where-Object { $_.Destination -eq $Destination } | Select-Object -First 1
  if (-not $mount) { throw "$Container does not mount $Destination." }
  return [string]$mount.$Property
}

function Normalize-Path([string]$Path) {
  if (-not $Path) { return "" }
  return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required." }
docker info *> $null
Assert-NativeSuccess "Checking Docker"

$activeVolume = Get-ActiveMount "terrasys-nominatim" "/var/lib/postgresql/16/main" "Name"
$activeRouting = Normalize-Path (Get-ActiveMount "terrasys-valhalla" "/custom_files" "Source")
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
} else { $null }
$previousVolume = if ($state -and $state.previous) { [string]$state.previous.nominatimVolume } else { "" }
$previousRouting = if ($state -and $state.previous) { Normalize-Path ([string]$state.previous.valhallaPath) } else { "" }

$keepVolumes = @($activeVolume)
$keepRouting = @($activeRouting)
if ($KeepPrevious -eq 1) {
  if ($previousVolume) { $keepVolumes += $previousVolume }
  if ($previousRouting) { $keepRouting += $previousRouting }
}

$volumeCandidates = @(docker volume ls --filter "label=terrasys.role=shared-index-candidate" --format '{{.Name}}')
if ($KeepPrevious -eq 0 -and $previousVolume) { $volumeCandidates += $previousVolume }
$removeVolumes = @($volumeCandidates | Where-Object { $_ -and $keepVolumes -notcontains $_ } | Sort-Object -Unique)

$routingCandidates = @()
if (Test-Path -LiteralPath $versionsRoot -PathType Container) {
  $routingCandidates += @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force | ForEach-Object { Normalize-Path $_.FullName })
}
if ($KeepPrevious -eq 0 -and $previousRouting) { $routingCandidates += $previousRouting }
$removeRouting = @($routingCandidates | Where-Object { $_ -and $keepRouting -notcontains $_ } | Sort-Object -Unique)

[pscustomobject]@{
  ActiveNominatim = $activeVolume
  ActiveValhalla = $activeRouting
  PreviousRetention = $KeepPrevious
  VolumesToRemove = @($removeVolumes)
  RoutingPathsToRemove = @($removeRouting)
} | Format-List

if (-not $ConfirmPrune) {
  Write-Host "Plan only. Re-run with -ConfirmPrune to remove the listed obsolete shared-index versions."
  exit 0
}

foreach ($volume in $removeVolumes) {
  $mountedBy = @(docker ps -a --filter "volume=$volume" --format '{{.Names}}')
  if ($mountedBy.Count -gt 0) { throw "Refusing to remove mounted volume $volume ($($mountedBy -join ', '))." }
  docker volume rm $volume | Out-Null
  Assert-NativeSuccess "Removing obsolete Nominatim volume $volume"
}

foreach ($path in $removeRouting) {
  $resolved = Normalize-Path $path
  $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  $routingPrefix = (Normalize-Path $routingRoot) + [IO.Path]::DirectorySeparatorChar
  if ($resolved -eq $activeRouting -or -not $resolved.StartsWith($routingPrefix, $pathComparison)) {
    throw "Refusing to remove unsafe or active routing path: $resolved"
  }
  if (Test-Path -LiteralPath $resolved -PathType Container) {
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}

if ($KeepPrevious -eq 0 -and $state -and $state.previous) {
  $state.previous = $null
  [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), $utf8)
}

Write-Host "Shared-index retention complete."
