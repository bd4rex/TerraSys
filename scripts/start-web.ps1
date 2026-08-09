$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$services = Join-Path $root "services"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH. Install Docker Desktop, then run this script again."
}

Push-Location $services
try {
  docker compose up -d web
  if ($LASTEXITCODE -ne 0) { throw "Could not start the web service." }
}
finally {
  Pop-Location
}

Write-Host ""
Write-Host "Web: http://localhost:8080/"
$lanAddresses = Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object {
    $_.IPAddress -notlike "127.*" -and
    $_.IPAddress -notlike "169.254.*" -and
    $_.IPAddress -notmatch "^(172\.(1[6-9]|2[0-9]|3[0-1])|198\.18)\." -and
    $_.PrefixOrigin -ne "WellKnown"
  } |
  Select-Object -ExpandProperty IPAddress

foreach ($address in $lanAddresses) {
  Write-Host "LAN: http://$address`:8080/"
}
