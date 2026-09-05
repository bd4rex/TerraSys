function Get-TerraSysOfflineKitContract {
  param([Parameter(Mandatory = $true)][string]$Root)
  $contract = Get-Content -Raw -LiteralPath (Join-Path $Root "config/offline-kit.json") | ConvertFrom-Json
  if ([int]$contract.schemaVersion -ne 1) { throw "Unsupported offline-kit contract." }
  return $contract
}

function Get-TerraSysToolImage {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Name)
  $contract = Get-TerraSysOfflineKitContract -Root $Root
  $property = $contract.images.PSObject.Properties[$Name]
  if (-not $property -or -not [string]$property.Value) { throw "Unknown offline image: $Name" }
  return [string]$property.Value
}

function Get-TerraSysOfflineKitMissingImages {
  param(
    [Parameter(Mandatory = $true)][object]$Contract,
    [AllowEmptyCollection()][string[]]$Images = @()
  )
  foreach ($property in $Contract.images.PSObject.Properties) {
    $required = [string]$property.Value
    $digest = if ($required -match '@(sha256:[a-fA-F0-9]{64})$') { $Matches[1] } else { $null }
    $found = $false
    foreach ($image in $Images) {
      $candidate = ([string]$image).Trim()
      if ($candidate.Equals($required, [StringComparison]::Ordinal) -or
          ($digest -and ($candidate.Equals($digest, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.EndsWith("@$digest", [StringComparison]::OrdinalIgnoreCase)))) {
        $found = $true
        break
      }
    }
    if (-not $found) { Write-Output $required }
  }
}

function Get-TerraSysOfflineKitImages {
  param([Parameter(Mandatory = $true)][string]$Root)
  $contract = Get-TerraSysOfflineKitContract -Root $Root
  $overrides = @{}
  $envPath = Join-Path $Root "services/.env"
  if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $envPath) {
      if ($line -match '^(OSM_CARTO_IMAGE|NOMINATIM_IMAGE)=(.+)$') { $overrides[$Matches[1]] = $Matches[2].Trim() }
    }
  }
  foreach ($property in $contract.images.PSObject.Properties) {
    $reference = [string]$property.Value
    $key = switch ($property.Name) { "osmCarto" { "OSM_CARTO_IMAGE" } "nominatim" { "NOMINATIM_IMAGE" } default { "" } }
    if ($key -and $overrides.ContainsKey($key)) {
      $candidate = [string]$overrides[$key]
      $digest = $reference.Substring($reference.IndexOf('@') + 1)
      if (-not ($candidate.Equals($digest, [StringComparison]::OrdinalIgnoreCase) -or
          $candidate.EndsWith("@$digest", [StringComparison]::OrdinalIgnoreCase))) {
        throw "$key must reference the approved digest $digest."
      }
      $reference = $candidate
    }
    Write-Output $reference
  }
}

function Copy-TerraSysOfflineProject {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Destination)
  $contract = Get-TerraSysOfflineKitContract -Root $Root
  $files = [System.Collections.Generic.List[object]]::new()
  foreach ($directory in $contract.projectDirectories) {
    $source = Join-Path $Root $directory
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Required project directory is missing: $directory" }
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File -Force) {
      if ($file.Name -eq ".env" -or $file.Extension -eq ".pyc" -or $file.FullName -match '[\\/]__pycache__[\\/]') { continue }
      $relative = Join-Path $directory $file.FullName.Substring($source.Length + 1)
      $files.Add([pscustomobject]@{ Source = $file.FullName; Relative = $relative })
    }
  }
  foreach ($name in $contract.rootFiles) {
    $source = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required project file is missing: $name" }
    $files.Add([pscustomobject]@{ Source = $source; Relative = $name })
  }
  foreach ($file in Get-ChildItem -LiteralPath $Root -File -Filter "*.cmd") {
    $files.Add([pscustomobject]@{ Source = $file.FullName; Relative = $file.Name })
  }
  foreach ($file in $files) {
    $target = Join-Path $Destination $file.Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $file.Source -Destination $target -Force
  }
  foreach ($relative in $contract.requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $relative) -PathType Leaf)) {
      throw "Required offline project file was not copied: $relative"
    }
  }
}
