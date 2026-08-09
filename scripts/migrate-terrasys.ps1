$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$migrationDir = Join-Path $root "services\postgis\migrations"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker was not found on PATH."
}

function Assert-NativeSuccess([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

docker exec terrasys-postgis psql -v ON_ERROR_STOP=1 -U gis -d terrasys -c @"
CREATE TABLE IF NOT EXISTS public.app_schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
"@ | Out-Host
Assert-NativeSuccess "Creating the migration ledger"

$legacyInitialMigration = docker exec terrasys-postgis psql -U gis -d terrasys -tAc `
  "SELECT 1 FROM public.app_schema_migrations WHERE version='001_personal_gis'"
Assert-NativeSuccess "Checking the legacy initial migration"
$currentInitialMigration = docker exec terrasys-postgis psql -U gis -d terrasys -tAc `
  "SELECT 1 FROM public.app_schema_migrations WHERE version='001_terrasys'"
Assert-NativeSuccess "Checking the TerraSys initial migration"
if ("$legacyInitialMigration".Trim() -eq "1" -and "$currentInitialMigration".Trim() -ne "1") {
  docker exec terrasys-postgis psql -v ON_ERROR_STOP=1 -U gis -d terrasys -c `
    "INSERT INTO public.app_schema_migrations(version) VALUES ('001_terrasys')" | Out-Host
  Assert-NativeSuccess "Recording the TerraSys migration alias"
}

Get-ChildItem $migrationDir -Filter "*.sql" -File | Sort-Object Name | ForEach-Object {
  $version = $_.BaseName.Replace("'", "''")
  $alreadyApplied = docker exec terrasys-postgis psql -U gis -d terrasys -tAc `
    "SELECT 1 FROM public.app_schema_migrations WHERE version='$version'"
  Assert-NativeSuccess "Checking migration $version"

  if ("$alreadyApplied".Trim() -eq "1") {
    Write-Host "Migration $version already applied."
    return
  }

  Write-Host "Applying migration $version..."
  docker exec terrasys-postgis psql -v ON_ERROR_STOP=1 -U gis -d terrasys `
    -f "/migrations/$($_.Name)" | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Migration $version failed."
  }
  docker exec terrasys-postgis psql -v ON_ERROR_STOP=1 -U gis -d terrasys -c `
    "INSERT INTO public.app_schema_migrations(version) VALUES ('$version')" | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Could not record migration $version."
  }
}
