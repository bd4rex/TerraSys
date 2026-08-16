$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$services = Join-Path $root "services"
$envFile = Join-Path $services ".env"
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH. Install Docker Engine or Docker Desktop, then run this script again."
}

Push-Location $services
try {
  docker compose up -d web
  if ($LASTEXITCODE -ne 0) { throw "Could not start the web service." }
}
finally {
  Pop-Location
}

$httpPortLine = if (Test-Path -LiteralPath $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^TERRASYS_HTTP_PORT=' } | Select-Object -First 1
}
$httpPort = if ($httpPortLine) { $httpPortLine.Substring("TERRASYS_HTTP_PORT=".Length).Trim() } else { "8080" }
$bindAddressLine = if (Test-Path -LiteralPath $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^TERRASYS_BIND_ADDRESS=' } | Select-Object -First 1
}
$bindAddress = if ($bindAddressLine) { $bindAddressLine.Substring("TERRASYS_BIND_ADDRESS=".Length).Trim() } else { "0.0.0.0" }
$displayHost = if ($bindAddress -in @("", "0.0.0.0", "::", "[::]")) { "localhost" } else { $bindAddress }
Write-Host ""
Write-Host "Web: http://${displayHost}:$httpPort/"
if ($isWindowsHost) {
  $lanAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike "127.*" -and
      $_.IPAddress -notlike "169.254.*" -and
      $_.IPAddress -notmatch "^(172\.(1[6-9]|2[0-9]|3[0-1])|198\.18)\." -and
      $_.PrefixOrigin -ne "WellKnown"
    } |
    Select-Object -ExpandProperty IPAddress
}
else {
  $lanAddresses = @(& ip -o -4 addr show up scope global 2>$null | ForEach-Object {
    if ($_ -match '^\d+:\s+([^\s]+)\s+inet\s+([^/]+)') {
      $interfaceName = $matches[1]
      if ($interfaceName -notmatch '^(docker|br-|veth)') { $matches[2] }
    }
  })
}

foreach ($address in $lanAddresses) {
  Write-Host "LAN: http://$address`:$httpPort/"
}
