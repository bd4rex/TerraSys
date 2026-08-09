$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$services = Join-Path $root "services"
$maintenanceRoot = Join-Path $root "data\maintenance"
$stopRequestPath = Join-Path $maintenanceRoot "stop.request"
$workerStatePath = Join-Path $maintenanceRoot "worker.json"

New-Item -ItemType Directory -Force -Path $maintenanceRoot | Out-Null
Set-Content -LiteralPath $stopRequestPath -Value ([DateTimeOffset]::Now.ToString("o")) -Encoding ASCII
for ($attempt = 0; $attempt -lt 10; $attempt++) {
  $workerStopped = $true
  if (Test-Path -LiteralPath $workerStatePath -PathType Leaf) {
    try { $workerStopped = (Get-Content -Raw -LiteralPath $workerStatePath | ConvertFrom-Json).status -ne "running" }
    catch { $workerStopped = $true }
  }
  if ($workerStopped) { break }
  Start-Sleep -Seconds 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH. Install Docker Desktop, then run this script again."
}

Push-Location $services
try {
  docker compose down
  if ($LASTEXITCODE -ne 0) { throw "Could not stop TerraSys services." }
}
finally {
  Pop-Location
}
