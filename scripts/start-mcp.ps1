$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $root "mcp\terrasys_mcp.py"

if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
  throw "TerraSys MCP server was not found: $server"
}

if (-not $env:TERRASYS_API_URL) {
  $env:TERRASYS_API_URL = "http://localhost:8080/api"
}

python $server
