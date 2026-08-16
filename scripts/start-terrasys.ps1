param(
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$services = Join-Path $root "services"
$envFile = Join-Path $services ".env"
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

function New-LocalSecret {
  $bytes = New-Object byte[] 32
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes).Replace("+", "_").Replace("/", "-").TrimEnd("=")
}

function Test-DockerEngine {
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & docker info *> $null
    return $LASTEXITCODE -eq 0
  }
  catch {
    return $false
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH. Install Docker Engine or Docker Desktop, then run this script again."
}

if (-not (Test-DockerEngine)) {
  if (-not $isWindowsHost) {
    throw "Docker Engine is not running or the current user cannot access it. Start docker.service and verify Docker-group membership."
  }
  $dockerDesktop = @(
    "C:\Program Files\Docker\Docker\Docker Desktop.exe",
    (Join-Path $env:LOCALAPPDATA "Docker\Docker Desktop.exe")
  ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $dockerDesktop) {
    throw "Docker Desktop is installed but its engine is not running. Start it, then run this script again."
  }
  Write-Host "Starting Docker Desktop..."
  Start-Process -FilePath $dockerDesktop -WindowStyle Hidden
  $dockerReady = $false
  for ($attempt = 0; $attempt -lt 90; $attempt++) {
    if (Test-DockerEngine) { $dockerReady = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $dockerReady) { throw "Docker Desktop did not become ready within 180 seconds." }
}

if (-not (Test-Path $envFile)) {
  "POSTGRES_PASSWORD=$(New-LocalSecret)" | Set-Content -Encoding ASCII $envFile
}
if (-not (Get-Content $envFile | Where-Object { $_ -match '^NOMINATIM_PASSWORD=' } | Select-Object -First 1)) {
  Add-Content -Encoding ASCII -LiteralPath $envFile -Value "NOMINATIM_PASSWORD=$(New-LocalSecret)"
}

$passwordLine = Get-Content $envFile | Where-Object { $_ -match '^POSTGRES_PASSWORD=' } | Select-Object -First 1
if (-not $passwordLine) { throw "POSTGRES_PASSWORD is missing from services/.env" }
$password = $passwordLine.Substring("POSTGRES_PASSWORD=".Length)
if ($password.Length -lt 20) { throw "POSTGRES_PASSWORD must contain at least 20 characters." }
$sqlPassword = $password.Replace("'", "''")
$nominatimPasswordLine = Get-Content $envFile | Where-Object { $_ -match '^NOMINATIM_PASSWORD=' } | Select-Object -First 1
if (-not $nominatimPasswordLine -or $nominatimPasswordLine.Substring("NOMINATIM_PASSWORD=".Length).Length -lt 20) {
  throw "NOMINATIM_PASSWORD must contain at least 20 characters."
}

$valhallaPathLine = Get-Content $envFile | Where-Object { $_ -match '^VALHALLA_DATA_PATH=' } | Select-Object -First 1
$valhallaDataPath = if ($valhallaPathLine) {
  $configuredPath = $valhallaPathLine.Substring("VALHALLA_DATA_PATH=".Length).Trim()
  if ([IO.Path]::IsPathRooted($configuredPath)) {
    [IO.Path]::GetFullPath($configuredPath)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $services $configuredPath))
  }
}
else {
  Join-Path $root "products\routing\valhalla"
}
$advancedReady = (Test-Path -LiteralPath (Join-Path $root "raw\osm\china\terrasys-core-latest.osm.pbf") -PathType Leaf) -and
  (Test-Path -LiteralPath (Join-Path $valhallaDataPath "terrasys-core-latest.osm.pbf") -PathType Leaf) -and
  (Test-Path -LiteralPath (Join-Path $root "products\encyclopedia\wikipedia_zh_all_mini_2026-05.zim") -PathType Leaf)
$profileArguments = if ($advancedReady) { @("--profile", "advanced") } else { @() }

Push-Location $services
try {
  docker compose up -d postgis | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Could not start PostGIS." }
  $ready = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    docker exec terrasys-postgis pg_isready -U gis -d terrasys *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $ready) { throw "PostGIS did not become ready." }

  docker exec terrasys-postgis psql -v ON_ERROR_STOP=1 -U gis -d terrasys -c `
    "ALTER ROLE gis PASSWORD '$sqlPassword'" | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Could not synchronize the PostGIS password." }
  & (Join-Path $PSScriptRoot "migrate-terrasys.ps1")
  if ($NoBuild) {
    docker compose @profileArguments up -d | Out-Host
  }
  else {
    docker compose @profileArguments up -d --build | Out-Host
  }
  if ($LASTEXITCODE -ne 0) { throw "One or more TerraSys services failed to start." }
}
finally {
  Pop-Location
}

$maintenanceRoot = Join-Path $root "data\maintenance"
$workerScript = Join-Path $PSScriptRoot "maintenance-worker.ps1"
$workerStatePath = Join-Path $maintenanceRoot "worker.json"
$stopRequestPath = Join-Path $maintenanceRoot "stop.request"
New-Item -ItemType Directory -Force -Path $maintenanceRoot | Out-Null
if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) { Remove-Item -LiteralPath $stopRequestPath -Force }
$workerRunning = $false
if (Test-Path -LiteralPath $workerStatePath -PathType Leaf) {
  try {
    $workerState = Get-Content -Raw -LiteralPath $workerStatePath | ConvertFrom-Json
    $workerPid = [int]$workerState.pid
    $workerCommandLine = $null
    if ($workerPid -gt 0) {
      if ($isWindowsHost) {
        $workerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $workerPid" -ErrorAction SilentlyContinue
        if ($workerProcess) { $workerCommandLine = [string]$workerProcess.CommandLine }
      }
      else {
        $commandLinePath = "/proc/$workerPid/cmdline"
        if (Test-Path -LiteralPath $commandLinePath -PathType Leaf) {
          $workerCommandLine = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($commandLinePath)).Replace([char]0, " ")
        }
      }
    }
    $workerRunning = $workerState.status -eq "running" -and
      $workerCommandLine -match [regex]::Escape($workerScript)
  }
  catch { $workerRunning = $false }
}
if (-not $workerRunning) {
  $workerExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }
  $workerArguments = @("-NoLogo", "-NoProfile")
  if ($isWindowsHost) { $workerArguments += @("-ExecutionPolicy", "Bypass") }
  $workerArguments += @("-File", $workerScript)
  $workerStart = @{
    FilePath = $workerExecutable
    ArgumentList = $workerArguments
  }
  if ($isWindowsHost) {
    $workerStart.WindowStyle = "Hidden"
  }
  else {
    $workerStart.RedirectStandardOutput = (Join-Path $maintenanceRoot "worker-console.log")
    $workerStart.RedirectStandardError = (Join-Path $maintenanceRoot "worker-error.log")
  }
  Start-Process @workerStart | Out-Null
}

$httpPortLine = Get-Content $envFile | Where-Object { $_ -match '^TERRASYS_HTTP_PORT=' } | Select-Object -First 1
$httpPort = if ($httpPortLine) { $httpPortLine.Substring("TERRASYS_HTTP_PORT=".Length).Trim() } else { "8080" }

Write-Host ""
Write-Host "TerraSys is starting."
Write-Host "Advanced offline engines: $(if ($advancedReady) { 'enabled' } else { 'not prepared' })"
Write-Host "Maintenance worker: enabled"
Write-Host "Map: http://localhost:$httpPort/"
Write-Host "Health: run ./terrasys.sh health (Linux) or health-check.cmd (Windows)"
