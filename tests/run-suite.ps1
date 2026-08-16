[CmdletBinding()]
param(
  [ValidateSet("static", "browser", "full", "recovery")]
  [string]$Profile = "static",
  [string]$UiImage = "terrasys-ui-test:suite",
  [string]$BrowserBaseUrl = "http://127.0.0.1",
  [string]$KitDirectory = "",
  [switch]$SkipImageBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$root = Split-Path -Parent $PSScriptRoot
$startedAt = Get-Date
$results = New-Object System.Collections.Generic.List[object]

function Invoke-SuiteStep {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Description,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )
  Write-Host "`n[$Id] $Description"
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  try {
    & $Action
    $stopwatch.Stop()
    $results.Add([pscustomobject]@{ id = $Id; status = "passed"; seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) })
    Write-Host "[$Id] passed in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) s"
  }
  catch {
    $stopwatch.Stop()
    $results.Add([pscustomobject]@{ id = $Id; status = "failed"; seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) })
    Write-Host ($results | ConvertTo-Json -Depth 3)
    throw "[$Id] $Description failed: $($_.Exception.Message)"
  }
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Operation
  )
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

function Invoke-BrowserTest {
  param([Parameter(Mandatory = $true)][string]$ScriptName)
  $runtimePath = Join-Path $root "runtime"
  New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null
  $arguments = @(
    "run", "--rm",
    "--network", "container:terrasys-web",
    "-e", "TERRASYS_UI_URL=$BrowserBaseUrl",
    "-v", "${runtimePath}:/work/runtime",
    "--entrypoint", "node",
    $UiImage,
    "/work/tests/$ScriptName"
  )
  Invoke-NativeCommand -Executable "docker" -Arguments $arguments -Operation "Browser test $ScriptName"
}

Invoke-SuiteStep -Id "static" -Description "repository configuration, scripts, bilingual docs, links, and test catalog" -Action {
  & (Join-Path $PSScriptRoot "repository-contracts.ps1")
}

Invoke-SuiteStep -Id "live-layer-unit" -Description "keyless live-layer adapters, cache, bounds, and AIS NMEA decoding" -Action {
  Invoke-NativeCommand -Executable "python" -Arguments @("-m", "unittest", "tests.test_live_layers", "-v") -Operation "Live-layer unit tests"
}

if ($Profile -in @("browser", "full", "recovery")) {
  Invoke-SuiteStep -Id "health" -Description "running service and installed-product health" -Action {
    $script = Join-Path $root "scripts\health-check.ps1"
    Invoke-NativeCommand -Executable "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script) -Operation "Health check"
  }
}

if ($Profile -in @("full", "recovery")) {
  Invoke-SuiteStep -Id "api-lifecycle" -Description "regional resources and personal-data lifecycle" -Action {
    $script = Join-Path $root "scripts\smoke-test.ps1"
    Invoke-NativeCommand -Executable "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script) -Operation "API lifecycle smoke test"
  }
}

if ($Profile -in @("browser", "full", "recovery")) {
  if (-not $SkipImageBuild) {
    Invoke-SuiteStep -Id "browser-image" -Description "reproducible Playwright test image" -Action {
      $dockerfile = Join-Path $root "services\tools\ui-test\Dockerfile"
      Invoke-NativeCommand -Executable "docker" -Arguments @("build", "--file", $dockerfile, "--tag", $UiImage, $root) -Operation "Building the UI-test image"
    }
  }
  foreach ($browserTest in @("ui-smoke.cjs", "resource-console-smoke.cjs", "information-layer-console-smoke.cjs", "world-map-smoke.cjs", "performance-smoke.cjs")) {
    $stepId = [IO.Path]::GetFileNameWithoutExtension($browserTest)
    Invoke-SuiteStep -Id $stepId -Description "Playwright $browserTest" -Action {
      Invoke-BrowserTest -ScriptName $browserTest
    }.GetNewClosure()
  }
}

if ($Profile -eq "recovery") {
  Invoke-SuiteStep -Id "offline-recovery" -Description "isolated offline-kit recovery drill" -Action {
    $script = Join-Path $root "scripts\test-offline-recovery.ps1"
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script)
    if ($KitDirectory) { $arguments += @("-KitDirectory", $KitDirectory) }
    Invoke-NativeCommand -Executable "powershell" -Arguments $arguments -Operation "Offline recovery drill"
  }
}

$duration = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
Write-Host "`nTest profile '$Profile' passed in $duration s."
Write-Host ($results | ConvertTo-Json -Depth 3)
