[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$summary = [ordered]@{}

function Add-ContractFailure {
  param([Parameter(Mandatory = $true)][string]$Message)
  $failures.Add($Message)
}

function Get-MarkdownFiles {
  $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter "*.md")) { $files.Add($file) }
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root "docs") -File -Filter "*.md")) { $files.Add($file) }
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root "tests") -File -Filter "*.md")) { $files.Add($file) }
  return @($files)
}

# Parse every tracked JSON document that participates in configuration or tests.
$jsonFiles = @(
  Get-ChildItem -LiteralPath (Join-Path $root "config") -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath (Join-Path $root "web\config") -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue
  Get-Item -LiteralPath (Join-Path $root "tests\test-cases.json")
  Get-Item -LiteralPath (Join-Path $root "tests\performance-baseline.json")
)
foreach ($file in $jsonFiles) {
  try {
    Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json | Out-Null
  }
  catch {
    Add-ContractFailure "Invalid JSON: $($file.FullName) - $($_.Exception.Message)"
  }
}
$summary.JsonFiles = $jsonFiles.Count

# Source overrides must be explicit, bounded to known packs, and reflected by the shared catalog loader.
$worldCatalog = Get-Content -Raw -LiteralPath (Join-Path $root "web\config\world-region-catalog.json") | ConvertFrom-Json
$sourceOverrides = Get-Content -Raw -LiteralPath (Join-Path $root "web\config\world-region-source-overrides.json") | ConvertFrom-Json
$worldIds = @($worldCatalog.datasets | ForEach-Object { [string]$_.id })
if ([int]$sourceOverrides.schemaVersion -ne 1) {
  Add-ContractFailure "World source overrides use an unsupported schema."
}
foreach ($property in $sourceOverrides.datasets.PSObject.Properties) {
  $profile = $property.Value.sourceProfile
  if ($worldIds -notcontains [string]$property.Name) {
    Add-ContractFailure "World source override references an unknown pack: $($property.Name)"
  }
  if (-not $profile -or [string]$profile.mode -ne "direct" -or [Uri]$profile.snapshotUrl -isnot [Uri] -or
      ([Uri]$profile.snapshotUrl).Scheme -ne "https" -or ([Uri]$profile.snapshotUrl).Host -ne "tiles.osm.kr") {
    Add-ContractFailure "World source override is not a trusted direct OSM Korea source: $($property.Name)"
  }
}
. (Join-Path $root "scripts\catalog-utils.ps1")
$effectiveCatalog = Get-TerraSysExpandedCatalog -Root $root
foreach ($packId in @("gf-north-korea", "gf-south-korea")) {
  $pack = @($effectiveCatalog.datasets | Where-Object { $_.id -eq $packId }) | Select-Object -First 1
  if (-not $pack -or [string]$pack.sourceProfile.provider -ne "OpenStreetMap Korea") {
    Add-ContractFailure "Effective catalog did not apply the source override for $packId."
  }
}
$summary.WorldSourceOverrides = @($sourceOverrides.datasets.PSObject.Properties).Count

# Keep all PowerShell entry points parseable, including scripts not safe to execute in CI.
$powerShellFiles = @(
  Get-ChildItem -LiteralPath (Join-Path $root "scripts") -Recurse -File -Filter "*.ps1"
  Get-ChildItem -LiteralPath (Join-Path $root "tests") -Recurse -File -Filter "*.ps1"
)
$strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
foreach ($file in $powerShellFiles) {
  $tokens = $null
  $parseErrors = $null
  try {
    $source = [IO.File]::ReadAllText($file.FullName, $strictUtf8)
  }
  catch {
    Add-ContractFailure "PowerShell source is not valid UTF-8: $($file.FullName) - $($_.Exception.Message)"
    continue
  }
  [void][System.Management.Automation.Language.Parser]::ParseInput($source, $file.FullName, [ref]$tokens, [ref]$parseErrors)
  foreach ($parseError in @($parseErrors)) {
    Add-ContractFailure "PowerShell parse error in $($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)"
  }
}
$summary.PowerShellFiles = $powerShellFiles.Count

# Parse Linux entry points when Bash is available. CI always runs this on Ubuntu.
$bashFiles = @(
  Get-ChildItem -LiteralPath $root -File -Filter "*.sh" -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath (Join-Path $root "scripts") -Recurse -File -Filter "*.sh" -ErrorAction SilentlyContinue
  Get-Item -LiteralPath (Join-Path $root "scripts\linux\curl.exe") -ErrorAction SilentlyContinue
)
$bash = Get-Command bash -ErrorAction SilentlyContinue
$bashUsable = $false
if ($bash) {
  & $bash.Source --version *> $null
  $bashUsable = $LASTEXITCODE -eq 0
}
if ($bashUsable) {
  foreach ($file in $bashFiles) {
    & $bash.Source -n $file.FullName
    if ($LASTEXITCODE -ne 0) {
      Add-ContractFailure "Bash parse error in $($file.FullName)."
    }
  }
}
$summary.BashFiles = $bashFiles.Count

# Every maintained document has a language counterpart and an explicit cross-link.
$markdownFiles = Get-MarkdownFiles
$bilingualPairs = 0
foreach ($file in $markdownFiles) {
  if ($file.Name.EndsWith(".zh-CN.md", [StringComparison]::OrdinalIgnoreCase)) {
    $counterpartName = $file.Name.Substring(0, $file.Name.Length - ".zh-CN.md".Length) + ".md"
  }
  else {
    $counterpartName = [IO.Path]::GetFileNameWithoutExtension($file.Name) + ".zh-CN.md"
  }
  $counterpartPath = Join-Path $file.DirectoryName $counterpartName
  if (-not (Test-Path -LiteralPath $counterpartPath -PathType Leaf)) {
    Add-ContractFailure "Missing bilingual counterpart for $($file.FullName): $counterpartName"
    continue
  }
  $header = (Get-Content -LiteralPath $file.FullName -TotalCount 12) -join "`n"
  if ($header -notmatch [regex]::Escape($counterpartName)) {
    Add-ContractFailure "Missing language-switch link in $($file.FullName): $counterpartName"
  }
  if (-not $file.Name.EndsWith(".zh-CN.md", [StringComparison]::OrdinalIgnoreCase)) {
    $bilingualPairs += 1
  }
}
$summary.BilingualPairs = $bilingualPairs

# Validate relative file links. External URLs and same-page anchors are intentionally excluded.
$localLinkCount = 0
$markdownLinkPattern = '(?<!!)\[[^\]]+\]\((?<target>[^)]+)\)'
foreach ($file in $markdownFiles) {
  $content = Get-Content -Raw -LiteralPath $file.FullName
  foreach ($match in [regex]::Matches($content, $markdownLinkPattern)) {
    $target = $match.Groups["target"].Value.Trim()
    if ($target.StartsWith("<") -and $target.Contains(">")) {
      $target = $target.Substring(1, $target.IndexOf(">") - 1)
    }
    elseif ($target -match '^([^\s]+)\s+["'']') {
      $target = $matches[1]
    }
    if (-not $target -or $target.StartsWith("#") -or $target -match '^[a-z][a-z0-9+.-]*:') { continue }
    $pathOnly = ($target -split '[?#]', 2)[0]
    if (-not $pathOnly) { continue }
    try { $pathOnly = [Uri]::UnescapeDataString($pathOnly) } catch { }
    $resolvedCandidate = Join-Path $file.DirectoryName ($pathOnly.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $localLinkCount += 1
    if (-not (Test-Path -LiteralPath $resolvedCandidate)) {
      Add-ContractFailure "Broken local Markdown link in $($file.FullName): $target"
    }
  }
}
$summary.LocalMarkdownLinks = $localLinkCount

# Validate the machine-readable test catalog and its automation references.
$catalogPath = Join-Path $root "tests\test-cases.json"
$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
$validProfiles = @("static", "browser", "full", "recovery")
$seenIds = @{}
foreach ($case in @($catalog.cases)) {
  $caseId = [string]$case.id
  if ($caseId -notmatch '^TC-[A-Z]+-[0-9]{3}$') {
    Add-ContractFailure "Invalid test-case identifier: $caseId"
  }
  if ($seenIds.ContainsKey($caseId)) {
    Add-ContractFailure "Duplicate test-case identifier: $caseId"
  }
  else {
    $seenIds[$caseId] = $true
  }
  if (-not @($case.assertions).Count) {
    Add-ContractFailure "Test case $caseId has no assertions."
  }
  foreach ($profile in @($case.profiles)) {
    if ($validProfiles -notcontains [string]$profile) {
      Add-ContractFailure "Test case $caseId uses unknown profile: $profile"
    }
  }
  foreach ($relativeAutomationPath in @($case.automation)) {
    $automationPath = Join-Path $root ([string]$relativeAutomationPath).Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $automationPath -PathType Leaf)) {
      Add-ContractFailure "Test case $caseId references missing automation: $relativeAutomationPath"
    }
  }
}
$summary.TestCases = @($catalog.cases).Count

# Keep the performance baseline statistically meaningful and deliberately less strict than its median.
$baseline = Get-Content -Raw -LiteralPath (Join-Path $root "tests\performance-baseline.json") | ConvertFrom-Json
if (@($baseline.samples).Count -lt 3) {
  Add-ContractFailure "The performance baseline must retain at least three samples."
}
foreach ($metric in @("domContentLoadedMs", "mapCanvasMs", "systemReadyMs")) {
  $medianValue = [double]$baseline.median.$metric
  $maximumValue = [double]$baseline.guardrails.maximumMs.$metric
  if ($medianValue -le 0 -or $maximumValue -le $medianValue) {
    Add-ContractFailure "Performance guardrail $metric must be greater than its positive median."
  }
}
$summary.PerformanceSamples = @($baseline.samples).Count

# A documented browser test must exist inside the reproducible Playwright image.
$dockerfilePath = Join-Path $root "services\tools\ui-test\Dockerfile"
$dockerfile = Get-Content -Raw -LiteralPath $dockerfilePath
$browserTests = @(Get-ChildItem -LiteralPath (Join-Path $root "tests") -File -Filter "*-smoke.cjs")
foreach ($file in $browserTests) {
  if ($dockerfile -notmatch [regex]::Escape("tests/$($file.Name)")) {
    Add-ContractFailure "UI-test Dockerfile does not copy $($file.Name)."
  }
}
if ($dockerfile -notmatch [regex]::Escape("tests/performance-baseline.json")) {
  Add-ContractFailure "UI-test Dockerfile does not copy performance-baseline.json."
}
$summary.BrowserTests = $browserTests.Count

if ($failures.Count) {
  $message = "Repository contract tests failed:`n - " + ($failures -join "`n - ")
  throw $message
}

Write-Host ($summary | ConvertTo-Json -Depth 3)
Write-Host "Repository contract tests passed."
