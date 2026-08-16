# Operations

> English | [简体中文](OPERATIONS.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## Start, stop, and inspect

```powershell
D:\TerraSys\start-terrasys.cmd
D:\TerraSys\health-check.cmd
D:\TerraSys\stop-terrasys.cmd
```

Linux uses the unified command surface:

```bash
./terrasys.sh start
./terrasys.sh health
./terrasys.sh stop
```

See [Linux server deployment](LINUX_DEPLOYMENT.md) for host preparation, direct public downloads, systemd, and backups.

Open `http://localhost:8080/` after health checks pass.

Detailed service state:

```powershell
Set-Location D:\TerraSys\services
docker compose ps
docker compose logs --tail 100 api web martin postgis
```

Expected core containers are `terrasys-web`, `terrasys-api`, `terrasys-martin`, and `terrasys-postgis`. A prepared installation also runs healthy `terrasys-nominatim`, `terrasys-valhalla`, `terrasys-kiwix`, and `terrasys-osm-carto` containers.

## Advanced offline capabilities

```powershell
D:\TerraSys\prepare-advanced.cmd
```

The command is idempotent around verified products. It builds `terrasys-core-latest.osm.pbf` from every installed catalog pack; prepares the pinned Wikipedia and Wikivoyage ZIMs, Natural Earth overview, Open-Meteo snapshot, and OSM nautical layer; copies routing input into Valhalla; and starts the advanced Compose profile.

Rebuild the independent zoom 0-7 world vector basemap with:

```powershell
D:\TerraSys\build-world-overview-vector.cmd
```

The first run caches the official Natural Earth GeoPackage. The staged build validates the PMTiles header and minimum size before replacing `web/assets/overview/world-overview.pmtiles`, then records its SHA256 in `overview.manifest.json`. The browser appends that content hash to range requests so an updated archive cannot reuse stale PMTiles byte ranges.

On this 16 GiB host, do not rebuild Valhalla and Nominatim concurrently. A first setup should let Valhalla finish, then let Nominatim import and index. Normal starts reuse `valhalla_tiles.tar` and the persistent Nominatim volume.

## Health checks

```powershell
D:\TerraSys\health-check.cmd
```

The script verifies:

- all prepared Compose services exist;
- nginx responds;
- FastAPI and PostGIS respond;
- Martin publishes exactly the configured sources;
- every installed regional PMTiles byte-range request returns 206;
- the map-pack API sees the synchronized global catalog and every installed archive;
- the latest backup directory can be identified.
- Nominatim, Valhalla, elevation grids, both Kiwix archives, global overview, weather, and nautical endpoints are ready.
- the OSM Carto manifest, database service, and proxied raster tile endpoint are ready when that renderer is prepared.

Resource lifecycle assertions use the last complete persistent inventory so a health check does not start a full disk scan while a large map is being built. On a first start with no inventory cache, the check performs one fresh inventory with an extended timeout.

Functional CRUD test:

```powershell
D:\TerraSys\smoke-test.cmd
```

This creates, updates, searches, and deletes temporary personal records; verifies regional packs, geocoding, reverse geocoding, route geometry/instructions/profile, point elevation, terrain PNGs, emergency references, Kiwix, unified search, GPX, media, export, and cleanup.

The unified test entry point has four cost levels:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile static
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile browser
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile full
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile recovery
```

`static` needs no running services and runs automatically on GitHub pull requests. `browser` adds health and all four Playwright regressions; `full` also exercises API, resource, and personal-data lifecycles; `recovery` finishes with the isolated disconnected recovery drill. See the [test suite](../tests/README.md) for the complete cases, prerequisites, side effects, and evidence locations. Screenshots are written to `runtime/ui-smoke` and `runtime/resource-console-smoke`. The performance test reads `tests/performance-baseline.json`, reports each run against the median of three measurements recorded on 2026-08-07, and applies intentionally wide guardrails for material regressions. The main test checks real map rendering, clickable base-feature details, nearby lookup and clustering, collection management and assignment, personal details/media state, regional pack verification/switching, offline reference search, readiness metadata, OpenStreetMap attribution, editing, theme switching, and non-overlapping narrow layout controls. The targeted world-map test checks an uninstalled region's catalog search, world location, persistent Chinese coverage prompt, three-way source switching, online fallback, visual-center offline coverage, and return to the exact offline build target.

## Map and resource manager

Open **System -> Manage resources** for the OsmAnd-style management surface:

- **Available** browses the world hierarchy, searches regions/resources, and opens per-region capability details;
- **Local** accounts for maps, source data, search/routing, terrain, encyclopedia, personal records, media, backups, and cache;
- **Updates** checks installed maps, shared indexes, the global catalog, overview, weather, nautical data, encyclopedia, and travel guide, then runs allowed updates through the local maintenance queue.

Available uses a persistent split view: the left side retains the world and current hierarchy while the right side shows the selected region or map pack. Selecting a region must not replace the rest of the catalog.

The main map always has a local Natural Earth 110m/50m/10m vector overview at zoom 0-7. Regional OSM layers add detail above it without removing the global road, boundary, river, and place skeleton outside installed packages. Automatic download suggestions remain hidden below zoom 8 so 100 km world browsing is uninterrupted; **Locate on world map** can still force the exact selected package into a coverage prompt. The WiFi shortcut opens **Map source**, where **Offline only**, **OSM Standard**, and **OpenFreeMap** can be selected without opening the side panel. The menu reports the source that is actually rendering and whether the current visible map center has an enabled local package. OSM automatically falls back to OpenFreeMap and then to the local overview when providers fail. Online sources are optional, clearly marked, limited to current-viewport browsing, and never bulk-cached. **Download offline map** returns to the selected package's real build action.

Opening the manager is cache-first. The last complete inventory is read from `data\maintenance\resource-inventory-cache.json`, while a single lock-protected refresh thread collects a new local/update inventory. The worker never deletes the last complete snapshot when a job finishes. Available renders from the map catalog and Updates renders from the independent maintenance snapshot, so active progress remains visible during a slow disk scan. The refresh icon starts a fresh inventory and trusted upstream check; the page polls the cached generation and replaces the view when the atomic refresh completes.

The Updates view shows the host worker heartbeat and job state. **Update** queues one resource; each active row shows its queue position or elapsed time, current stage, progress track, attached cancel action, and any throughput the underlying tool can report. Direct downloads show bytes per second plus received/total size. Planetiler builds show tiles per second, generated tile count, and staged output size. Stages without a reliable counter remain labelled as processing and never display an invented speed. Failed jobs expose retry on the same row. The summary strip contains counts only. **Update all** queues only non-heavy items. The automatic-update switch schedules weather every 6 hours and the global region catalog every 7 days; the overview map is present in settings but disabled by default. Shared search/route indexes, map builds, and large knowledge downloads always require an explicit action. A forced refresh asks the trusted source provider for its current replication state and distinguishes upstream updates, local refreshes, missing products, and shared-index rebuilds.

Local map-pack management supports multi-select verification, update, and protected removal. Each pack also has its own information, verification, manifest export, enable/disable, rebuild, browse, and remove menu. Disable keeps the PMTiles and source files but excludes the pack from MapLibre rendering immediately. It also makes the shared search/route index stale. If the existing index still covers every enabled pack and only contains extra disabled/removed coverage, search and routing remain available while the resource page requires a cleanup rebuild. If any enabled pack is missing from the index, those services are held unavailable until **Search and route shared index** is rebuilt. State is stored in `data\maintenance\map-pack-state.json` and is included in new offline recovery kits.

After a regional build, update, rebuild, removal, enable, or disable changes the active scope, the system automatically queues lightweight weather and nautical derivatives. OSM Carto and shared search/routing remain explicit blue-green heavy rebuilds. The inventory reports coverage per region, so service-level health cannot hide a newly installed package that still needs synchronization.

Regenerable storage is accounted separately as terrain tiles, build temporary files, and the resource-inventory cache. Clear actions use a fixed server-side allowlist. Build temporary files cannot be cleared while maintenance work is queued or running. Legacy `suwan` and `huzhe` combination files, when present, are reported with their independent province replacements.

Every update row uses the same lifecycle fields: source-data time, local-build time, last-check time, and next-check time. For the incremental-update research path and full-snapshot disaster-recovery rules, see `docs/OSM_INCREMENTAL_UPDATES.md` and run `D:\TerraSys\plan-osm-incremental-updates.cmd`.

Maintenance state is stored in `D:\TerraSys\data\maintenance`:

| Path | Purpose |
| --- | --- |
| `settings.json` | Automatic-update policy |
| `worker.json` | Worker PID, heartbeat, and current job |
| `jobs\*.json` | Queue and completed job records |
| `logs\*.log` | Script output for each job |
| `backup-policy.json` | Installed daily-backup schedule and optional mirror target |

The API accepts only catalog pack IDs and a fixed resource allowlist. It never accepts a command string from the browser. The Windows or Linux start command launches `scripts/maintenance-worker.ps1` in the background; the matching stop command requests a clean worker stop before Docker shuts down.

The storage total is intentionally conservative. Host directories and PostGIS are counted; Docker-managed Nominatim bytes are shown as volume-managed and are not guessed.

### Nominatim incomplete-import recovery

If `/status` is healthy but ordinary searches return `Query took too long to process`, run the database self-check before rebuilding the volume:

```powershell
docker exec -u nominatim terrasys-nominatim nominatim admin --check-database --project-dir /nominatim
```

An absent database version or missing `idx_search_name_name_vector` / `idx_search_name_nameaddress_vector` means the import reached place indexing but not final database post-processing. Resume only that stage:

```powershell
docker exec -u nominatim terrasys-nominatim nominatim import --project-dir /nominatim --continue db-postprocess -j 4 --no-updates --offline
```

This can take tens of minutes on a large existing volume while map rendering remains available. Monitor `pg_stat_progress_create_index`; do not restart Docker during the transaction. On completion, rerun `admin --check-database`, then verify `/api/geocode` and `/api/reverse`. A completed self-check must report matching database/software versions, complete valid indexes, working tokenizer, and finished indexing status.

### Regional pack commands

Use the System tab for everyday pack inspection, checksum verification, switching, named regional views, building, and updating. The UI queues the same guarded scripts listed below; direct commands remain useful for recovery and diagnostics:

```powershell
D:\TerraSys\region-pack.cmd List
D:\TerraSys\region-pack.cmd Verify
D:\TerraSys\region-pack.cmd Plan -PackId jiangsu
D:\TerraSys\region-pack.cmd Build -PackId jiangsu
D:\TerraSys\region-pack.cmd Update -PackId jiangsu
D:\TerraSys\region-pack.cmd Remove -PackId jiangsu -ConfirmRemove
```

`List` reports every physical pack. `Plan` resolves a province without changing data and prints its source profile, paths, boundaries, estimates, and command. `Verify` reads installed archives and compares SHA256. `Build` uses cached sources/boundaries. `Update` refreshes trusted provider state and source data before rebuilding, including shared-snapshot mainland packs; same-sequence queued province updates reuse the already validated China snapshot. `Remove` requires the explicit confirmation switch, deletes only derived PMTiles/manifest files, and retains source/boundary caches.

An update is complete only when the installed manifest records the trusted upstream sequence. A fresh inventory then removes that item from **Updates**. The maintenance API returns `409` for another update request at the same sequence; use **Rebuild** when the source is current but the derived PMTiles must be regenerated.

The China catalog contains 34 province-level units, and the global catalog contains more than 550 Geofabrik country/region units. Continents and Chinese geographic headings are navigation sections, not bundle IDs. Combination packs are not supported installation units.

To add a province, open it under Available and choose **Build**. Mainland builds reuse the local China snapshot and one cached boundary. Taiwan downloads and verifies its direct source when first built. To define a future country/state unit, extend `region-catalog.json` with a source profile and dataset rather than adding another combination pack. Uninstalled units are skipped by capability-source and offline-kit builds; partially installed units remain visible as repair work and never count as installed.

### Rebuild shared search and route indexes

Adding a new region or changing an installed source hash marks the shared index as updateable:

```powershell
D:\TerraSys\rebuild-shared-indexes.cmd -Plan
D:\TerraSys\rebuild-shared-indexes.cmd -ConfirmRebuild
```

The confirmed operation may take many hours, but it no longer rebuilds either production index in place. It creates a resource-limited Valhalla candidate and a separate Nominatim candidate volume while the active map, search, and routing services stay online. The candidates are switched into service only after health and database checks pass. A successful activation keeps one previous version by default and prunes older unmounted candidates. A failed or cancelled build leaves the current version selected. Personal PostGIS data is never replaced.

If a candidate reached validation but a later configuration step failed, resume that exact candidate instead of rebuilding it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\rebuild-shared-indexes.ps1 -ResumeCandidateId YYYYMMDD-HHMMSS
```

After a verified disconnected recovery kit exists, obsolete rollback indexes can be listed and then removed explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\prune-shared-index-versions.ps1 -KeepPrevious 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\prune-shared-index-versions.ps1 -KeepPrevious 0 -ConfirmPrune
```

The pruning script refuses to remove the Nominatim volume or Valhalla directory currently mounted by a container.

The resource task page reports five phases: source snapshot, route candidate, search candidate, validation, and activation. A heavy shared-index task is never automatically retried after failure or a worker restart. Review its log and start a new task explicitly.

## Backup

```powershell
D:\TerraSys\backup-terrasys.cmd
```

Each backup contains:

- `terrasys.dump`: PostgreSQL custom-format dump;
- `media/`: personal image files, when present;
- `manifest.json`: file sizes and SHA256 hashes.

The default retention is 14. To choose another count:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\backup-terrasys.ps1 -Keep 30
```

Install or refresh the daily 03:00 Windows task:

```powershell
D:\TerraSys\install-backup-task.cmd
```

For a second physical disk, run the script with `-MirrorRoot E:\TerraSys-BACKUPS`; verification completes locally before the backup is copied. A same-drive mirror is rejected because it does not protect against disk loss.

Base maps and advanced indexes are not part of the small everyday backup because they are reproducible and much larger than personal data. The disconnected recovery kit below captures them.

## Restore

Restoration replaces database contents. Stop editing the map first and use a directory inside `D:\TerraSys\backups`:

```powershell
D:\TerraSys\restore-terrasys.cmd -BackupDirectory D:\TerraSys\backups\YYYYMMDD-HHMMSS
```

The script rejects paths outside the backup root, validates the database dump checksum, stops API/Martin, restores with `pg_restore --clean --if-exists`, applies any migrations newer than the dump, copies media, and starts the services again. Run health and smoke tests afterward.

## Disconnected recovery kit

Create a complete kit after the normal health and smoke tests pass:

```powershell
D:\TerraSys\create-offline-kit.cmd
```

The command first checks free space, creates a fresh personal backup; copies the application, every installed map pack and source, shared capability PBF, route graph, elevation grids, both Kiwix archives, global overview sources, weather, nautical data, and the OSM Carto source; snapshots both Nominatim and the OSM Carto database; exports runtime/build/test Docker images; then writes and verifies a SHA256 manifest. Kits are written to `D:\TerraSys\offline-kit\<timestamp>`. After verification, the default policy retains the latest valid kit and deletes failed or older kit directories through path-guarded cleanup.

Verify an existing kit without restoring it:

```powershell
D:\TerraSys\verify-offline-kit.cmd -KitDirectory D:\TerraSys\offline-kit\YYYYMMDD-HHMMSS
```

Run a non-destructive isolated recovery drill:

```powershell
D:\TerraSys\test-offline-recovery.cmd -KitDirectory D:\TerraSys\offline-kit\YYYYMMDD-HHMMSS
```

The drill creates temporary containers on a Docker `--internal` network, restores PostGIS, media, and the Nominatim snapshot, starts the packaged Valhalla and Kiwix products, then verifies API health/status/search/export, address search, routing/elevation, encyclopedia access, Martin sources, nginx proxying, PMTiles headers, restored row counts, and blocked external routing. A full replacement-machine restore also restores the packaged OSM Carto volume before startup. The drill removes temporary resources afterward; the JSON result remains under `runtime/recovery-audit`.

## Docker storage reclamation

Deleting images or volumes frees space inside Docker but may not shrink `D:\DockerData\wsl\disk\docker_data.vhdx`. After creating and verifying a recovery kit, remove only confirmed unmounted resources, run `docker builder prune --all --force`, then reclaim host space during a maintenance window:

1. Run `wsl -d docker-desktop -u root -- fstrim -av`.
2. Stop the TerraSys Compose services and shut down Docker Desktop and WSL.
3. Use DiskPart `select vdisk file="D:\DockerData\wsl\disk\docker_data.vhdx"` followed by `compact vdisk`.
4. Start Docker Desktop, run `D:\TerraSys\start-terrasys.cmd`, then run health and smoke tests.

Never compact a VHDX while Docker Desktop or its WSL distribution is running.

The printable replacement-computer procedure is in `docs/OFFLINE_RECOVERY.md`.

## Refresh map data

```powershell
D:\TerraSys\backup-terrasys.cmd
D:\TerraSys\download-osm.cmd
D:\TerraSys\region-pack.cmd Update -PackId jiangsu
D:\TerraSys\region-pack.cmd Update -PackId anhui
D:\TerraSys\build-capability-source.cmd
D:\TerraSys\sync-world-catalog.cmd
D:\TerraSys\sync-weather.cmd
D:\TerraSys\build-nautical.cmd
D:\TerraSys\import-reference-search.cmd
D:\TerraSys\health-check.cmd
```

Do not delete `.previous` files until the new map has passed browser testing. Builds use significant CPU, disk I/O, and up to roughly 6GB Java heap.

## Useful direct probes

```powershell
Invoke-RestMethod http://localhost:8080/api/status
Invoke-RestMethod 'http://localhost:8080/api/search?q=南京'
Invoke-RestMethod http://localhost:8080/martin/catalog
Invoke-RestMethod http://localhost:8080/api/map-packs
Invoke-RestMethod http://localhost:8080/api/resources
Invoke-RestMethod http://localhost:8080/api/capabilities
Invoke-RestMethod 'http://localhost:8080/api/geocode?q=南京大学'
Invoke-RestMethod 'http://localhost:8080/api/elevation?longitude=118.7969&latitude=32.0603'
curl.exe -I -H "Range: bytes=0-1023" http://localhost:8080/tiles/jiangsu.pmtiles
curl.exe -I -H "Range: bytes=0-1023" http://localhost:8080/tiles/anhui.pmtiles
```

The last command should return `206 Partial Content`.

## Troubleshooting

### The port shows JSON or text

Use only `http://localhost:8080/` for the application. `/api/health`, `/martin/catalog`, and `/healthz` are machine-readable service endpoints by design.

### Blank or incomplete map

1. Run `health-check.cmd`.
2. Check that every installed pack's `.pmtiles` and manifest exist and are not staging files; use a per-region shortcut to isolate the affected area.
3. Verify the Range probe returns 206.
4. Inspect `docker compose logs web`.
5. Run the UI smoke test and inspect its screenshots.

### Personal data missing

Check `/api/status`, then inspect API/PostGIS logs. Do not recreate the Docker volume before taking a dump. Use the most recent checksum-valid backup if recovery is necessary.

### Database password changed

Run `start-terrasys.cmd`. It reads `services/.env`, starts PostGIS, synchronizes the role password, applies migrations, then starts dependent services.

### Rebuild interrupted

The installed PMTiles remains untouched until the staged file passes checks. Remove only `<pack>.staged.pmtiles` and files under `tmp/osmium-<pack>`, then rerun `region-pack.cmd Build -PackId <pack>`. Do not remove the installed `<pack>.pmtiles`.

For a shared search/route rebuild, the active services also remain untouched. The worker removes task-labelled candidate containers and volumes on cancellation. Candidate Valhalla files left under `runtime/index-rebuild/<timestamp>` are build cache and may be removed after confirming there is no active maintenance task. Do not delete the Nominatim volume or routing path named by `services/.env`.

### Address search is still building

Normal updates import in a `terrasys-nominatim-candidate-*` container while `terrasys-nominatim` continues serving the active database. Inspect the candidate log from the task page or with `docker logs`. Do not run `nominatim import --continue` or full-table maintenance checks in the production container. Cancel the task and start a fresh candidate build after diagnosing the failure.

### Route or terrain is unavailable

Check `products/routing/valhalla/valhalla_tiles.tar`, `products/elevation`, and `docker logs terrasys-valhalla`. Run `powershell -ExecutionPolicy Bypass -File scripts/sync-elevation.ps1` to synchronize global-source HGT grids for every enabled installed region. A normal restart should load the existing tile archive rather than rebuild. Terrain PNGs under `data/terrain-cache` are disposable and regenerate from the HGT files; cached flat PNGs are intentional neighbor tiles used to keep contour generation fast at coverage edges.
