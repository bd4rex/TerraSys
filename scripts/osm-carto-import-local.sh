#!/usr/bin/env bash
# This file is mounted directly into Linux containers and must remain LF-only.
set -euo pipefail

mkdir -p /data/style
if [ -z "$(ls -A /data/style)" ]; then
  cp -a /home/renderer/src/openstreetmap-carto-backup/. /data/style/
fi
sed 's#terrasys-osm-carto-assets#127.0.0.1#' /repair/external-data.yml > /data/style/external-data.yml

python3 -m http.server 8090 --bind 127.0.0.1 --directory /external >/tmp/terrasys-carto-assets.log 2>&1 &
asset_server_pid=$!
cleanup() {
  kill "$asset_server_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8090/ne_110m_admin_0_boundary_lines_land.zip >/dev/null; then
    /run.sh import
    exit $?
  fi
  sleep 1
done

echo "Local OSM Carto external-data server did not become ready." >&2
exit 1
