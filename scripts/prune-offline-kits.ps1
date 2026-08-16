param(
  [int]$Keep = 1,
  [switch]$KeepFailed
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$kitRoot = Join-Path $root "offline-kit"
if (-not (Test-Path -LiteralPath $kitRoot -PathType Container)) { exit 0 }

$resolvedRoot = (Resolve-Path -LiteralPath $kitRoot).Path.TrimEnd([char[]]@('\', '/'))
$pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$rootPrefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
$directories = @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Force)
$valid = @($directories | Where-Object {
  if ($_.Name.EndsWith(".failed", [StringComparison]::OrdinalIgnoreCase)) { return $false }
  $manifestPath = Join-Path $_.FullName "manifest.json"
  $verificationPath = Join-Path $_.FullName "verification.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $verificationPath -PathType Leaf)) { return $false }
  try {
    $verification = Get-Content -Raw -LiteralPath $verificationPath | ConvertFrom-Json
    return $verification.status -eq "verified" -and
      $verification.manifestSha256 -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  }
  catch { return $false }
} | Sort-Object Name -Descending)

if ($valid.Count -lt 1) { throw "Refusing to prune offline kits because no verified kit was found." }
$remove = New-Object System.Collections.Generic.List[IO.DirectoryInfo]
foreach ($directory in @($valid | Select-Object -Skip ([math]::Max(1, $Keep)))) { $remove.Add($directory) }
if (-not $KeepFailed) {
  foreach ($directory in @($directories | Where-Object { $_.Name.EndsWith(".failed", [StringComparison]::OrdinalIgnoreCase) })) { $remove.Add($directory) }
}

foreach ($directory in $remove | Sort-Object FullName -Unique) {
  $resolved = (Resolve-Path -LiteralPath $directory.FullName).Path
  if (-not $resolved.StartsWith($rootPrefix, $pathComparison)) {
    throw "Refusing to remove an offline kit outside $resolvedRoot"
  }
  Write-Host "Removing old offline kit: $resolved"
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

Write-Host "Offline-kit retention complete. Kept $([math]::Min($valid.Count, [math]::Max(1, $Keep))) verified kits."
