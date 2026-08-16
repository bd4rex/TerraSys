#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_USER="${SUDO_USER:-$(id -un)}"
START_SERVICE=0
BACKUP_ONLY=0

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install-linux-service.sh [options]

Options:
  --user USER       Run TerraSys as USER (default: invoking sudo user)
  --root PATH       Project root (default: detected repository root)
  --start           Enable and start terrasys.service now
  --backup-only     Install only the daily backup service and timer
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || { printf '%s\n' '--user requires a value.' >&2; exit 2; }
      SERVICE_USER="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || { printf '%s\n' '--root requires a value.' >&2; exit 2; }
      PROJECT_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --start) START_SERVICE=1; shift ;;
    --backup-only) BACKUP_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  printf 'Run this installer with sudo.\n' >&2
  exit 1
fi
if [[ ! "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  printf 'Invalid Linux service user: %s\n' "$SERVICE_USER" >&2
  exit 1
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  printf 'Linux service user does not exist: %s\n' "$SERVICE_USER" >&2
  exit 1
fi
if [[ "$PROJECT_ROOT" =~ [[:space:]&|\;] ]]; then
  printf 'The project path cannot contain whitespace or shell metacharacters: %s\n' "$PROJECT_ROOT" >&2
  exit 1
fi
for required in docker pwsh systemctl sed install; do
  command -v "$required" >/dev/null 2>&1 || { printf 'Required command is missing: %s\n' "$required" >&2; exit 1; }
done
if [[ ! -x "$PROJECT_ROOT/terrasys.sh" ]]; then
  printf 'TerraSys Linux entry point is missing or not executable: %s/terrasys.sh\n' "$PROJECT_ROOT" >&2
  exit 1
fi

SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "$SERVICE_USER"
fi

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render_unit() {
  local source_path="$1"
  local destination_path="$2"
  local root_escaped user_escaped group_escaped
  root_escaped="$(escape_sed "$PROJECT_ROOT")"
  user_escaped="$(escape_sed "$SERVICE_USER")"
  group_escaped="$(escape_sed "$SERVICE_GROUP")"
  sed \
    -e "s|@PROJECT_ROOT@|$root_escaped|g" \
    -e "s|@SERVICE_USER@|$user_escaped|g" \
    -e "s|@SERVICE_GROUP@|$group_escaped|g" \
    "$source_path" > "$destination_path.tmp"
  chmod 0644 "$destination_path.tmp"
  mv -f "$destination_path.tmp" "$destination_path"
}

unit_root="$PROJECT_ROOT/services/systemd"
render_unit "$unit_root/terrasys-backup.service.in" /etc/systemd/system/terrasys-backup.service
install -m 0644 "$unit_root/terrasys-backup.timer" /etc/systemd/system/terrasys-backup.timer

if [[ $BACKUP_ONLY -eq 0 ]]; then
  render_unit "$unit_root/terrasys.service.in" /etc/systemd/system/terrasys.service
fi

systemctl daemon-reload
systemctl enable --now terrasys-backup.timer
if [[ $BACKUP_ONLY -eq 0 ]]; then
  systemctl enable terrasys.service
  if [[ $START_SERVICE -eq 1 ]]; then
    systemctl restart terrasys.service
  fi
fi

printf 'Installed TerraSys systemd units for %s at %s.\n' "$SERVICE_USER" "$PROJECT_ROOT"
printf 'Daily backup timer: enabled\n'
if [[ $BACKUP_ONLY -eq 0 ]]; then
  printf 'Application service: enabled%s\n' "$(if [[ $START_SERVICE -eq 1 ]]; then printf ' and started'; fi)"
fi
