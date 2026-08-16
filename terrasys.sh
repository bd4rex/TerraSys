#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$PROJECT_ROOT/scripts/linux:$PATH"

usage() {
  cat <<'EOF'
TerraSys Linux command line

Usage:
  ./terrasys.sh <command> [PowerShell arguments]

Common commands:
  start [--no-build]       Start the service stack
  start-offline            Start without rebuilding images
  stop                     Stop the service stack
  health                   Run installed-product health checks
  smoke                    Run API lifecycle smoke tests
  backup                   Create a checksum-verified personal-data backup
  region-pack              Build, update, verify, roll back, or remove a map pack
  prepare-advanced         Prepare the advanced offline services
  test-suite               Run the layered test suite
  install-backup-task      Install the daily systemd backup timer

All commands replacing the Windows .cmd entry points:
  backup, build-capability-source, build-nautical,
  build-world-overview-vector, create-offline-kit, download-encyclopedia,
  download-osm, download-osm-carto-sources, download-travel-guide, download-web-assets, health,
  import-reference-search, install-backup-task, migrate,
  plan-osm-incremental-updates, prepare-advanced, prune-offline-kits,
  rebuild-shared-indexes, refresh-offline-kit, region-pack,
  restore-offline-kit, restore, smoke, start, start-offline, stop,
  sync-overview-resources, sync-weather, sync-world-catalog,
  test-offline-recovery, test-suite, verify-offline-kit.

Examples:
  ./terrasys.sh start --no-build
  ./terrasys.sh region-pack Build -PackId jiangsu
  ./terrasys.sh test-suite -Profile static
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

command_name="$1"
shift

case "$command_name" in
  help|-h|--help)
    usage
    exit 0
    ;;
  install-backup-task)
    exec sudo "$PROJECT_ROOT/scripts/install-linux-service.sh" --backup-only "$@"
    ;;
  start)
    translated=()
    for argument in "$@"; do
      if [[ "$argument" == "--no-build" ]]; then
        translated+=("-NoBuild")
      else
        translated+=("$argument")
      fi
    done
    exec pwsh -NoLogo -NoProfile -File "$PROJECT_ROOT/scripts/start-terrasys.ps1" "${translated[@]}"
    ;;
  start-offline)
    exec pwsh -NoLogo -NoProfile -File "$PROJECT_ROOT/scripts/start-terrasys.ps1" -NoBuild "$@"
    ;;
  backup) script="backup-terrasys.ps1" ;;
  build-capability-source) script="build-capability-source.ps1" ;;
  build-nautical) script="build-nautical.ps1" ;;
  build-osm-carto) script="build-osm-carto.ps1" ;;
  build-world-overview-vector) script="build-world-overview-vector.ps1" ;;
  create-offline-kit) script="create-offline-kit.ps1" ;;
  download-encyclopedia) script="download-encyclopedia.ps1" ;;
  download-osm) script="download-osm.ps1" ;;
  download-osm-carto-sources) script="download-osm-carto-sources.ps1" ;;
  download-travel-guide) script="download-travel-guide.ps1" ;;
  download-web-assets) script="download-web-assets.ps1" ;;
  health) script="health-check.ps1" ;;
  import-reference-search) script="import-reference-search.ps1" ;;
  migrate) script="migrate-terrasys.ps1" ;;
  plan-osm-incremental-updates) script="plan-osm-incremental-updates.ps1" ;;
  prepare-advanced) script="prepare-advanced.ps1" ;;
  prune-offline-kits) script="prune-offline-kits.ps1" ;;
  rebuild-shared-indexes) script="rebuild-shared-indexes.ps1" ;;
  refresh-offline-kit) script="refresh-offline-kit.ps1" ;;
  region-pack) script="region-pack.ps1" ;;
  restore-offline-kit) script="restore-offline-kit.ps1" ;;
  restore) script="restore-terrasys.ps1" ;;
  smoke) script="smoke-test.ps1" ;;
  stop) script="stop-terrasys.ps1" ;;
  sync-overview-resources) script="sync-overview-resources.ps1" ;;
  sync-weather) script="sync-weather.ps1" ;;
  sync-world-catalog) script="sync-world-catalog.ps1" ;;
  test-offline-recovery) script="test-offline-recovery.ps1" ;;
  test-suite) script="../tests/run-suite.ps1" ;;
  verify-offline-kit) script="verify-offline-kit.ps1" ;;
  *)
    printf 'Unknown TerraSys command: %s\n\n' "$command_name" >&2
    usage >&2
    exit 2
    ;;
esac

if ! command -v pwsh >/dev/null 2>&1; then
  printf 'PowerShell (pwsh) is required. See docs/LINUX_DEPLOYMENT.md.\n' >&2
  exit 127
fi

exec pwsh -NoLogo -NoProfile -File "$PROJECT_ROOT/scripts/$script" "$@"
