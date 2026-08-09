param(
  [int]$Keep = 14,
  [string]$MirrorRoot = $env:TERRASYS_BACKUP_MIRROR
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupRoot = Join-Path $root "backups"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$target = Join-Path $backupRoot $timestamp
$dumpFile = Join-Path $target "terrasys.dump"
$mediaRoot = Join-Path $root "data\media"

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

try {
  Write-Host "Creating PostGIS backup..."
  docker exec terrasys-postgis pg_dump -U gis -d terrasys -Fc -f /tmp/terrasys.dump
  Assert-NativeSuccess "Creating the PostgreSQL dump"
  docker cp "terrasys-postgis:/tmp/terrasys.dump" $dumpFile
  Assert-NativeSuccess "Copying the PostgreSQL dump"
  docker exec terrasys-postgis rm /tmp/terrasys.dump
  Assert-NativeSuccess "Removing the temporary container dump"
  if ((Get-Item $dumpFile).Length -lt 1024) {
    throw "Database backup is unexpectedly small."
  }

  if (Test-Path $mediaRoot) {
    Copy-Item -LiteralPath $mediaRoot -Destination (Join-Path $target "media") -Recurse -Force
  }

  $hashes = Get-ChildItem $target -Recurse -File | ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [pscustomobject]@{
      Path = $_.FullName.Substring($target.Length + 1).Replace("\", "/")
      Bytes = $_.Length
      SHA256 = $hash.Hash.ToLowerInvariant()
    }
  }
  $hashes | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $target "manifest.json")

  if ($MirrorRoot) {
    $mirrorRootFull = [IO.Path]::GetFullPath($MirrorRoot).TrimEnd('\')
    $projectDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))
    $mirrorDrive = [IO.Path]::GetPathRoot($mirrorRootFull)
    if ($projectDrive -eq $mirrorDrive) {
      throw "Backup mirror must be on a different drive from $projectDrive"
    }
    New-Item -ItemType Directory -Force -Path $mirrorRootFull | Out-Null
    $mirrorTarget = Join-Path $mirrorRootFull $timestamp
    Copy-Item -LiteralPath $target -Destination $mirrorTarget -Recurse -Force
    Write-Host "Backup mirrored to: $mirrorTarget"
  }

  $resolvedBackupRoot = (Resolve-Path $backupRoot).Path.TrimEnd('\')
  Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip $Keep | ForEach-Object {
    $resolved = (Resolve-Path $_.FullName).Path
    if (-not $resolved.StartsWith($resolvedBackupRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove backup outside $resolvedBackupRoot"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }

  Write-Host "Backup created: $target"
}
catch {
  docker exec terrasys-postgis rm -f /tmp/terrasys.dump 2>$null
  throw
}
