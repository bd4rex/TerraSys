# Process Log

> English | [简体中文](PROCESS_LOG.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

> Historical implementation narrative. Commands and ports in earlier sections describe the system at that point in time. Use `README.md` and the current operations/rebuild documents for active instructions.

This is the implementation log for the Jiangsu/Anhui TerraSys MVP.

## 2026-07-03

### Goal Clarified

The target was not just a small MapLibre demo. The intended system is a personal, controllable, open-data map stack that can keep working offline and later grow toward global coverage.

The first MVP scope was limited to Jiangsu and Anhui because those regions match existing personal data and are small enough to validate the pipeline.

### Workspace Migration

Migrated the working project from:

```text
C:\Users\Administrator\Documents\TerraSys
```

to:

```text
D:\TerraSys
```

The D drive had enough available capacity for the 100 GB working budget.

### Directory Layout Created

Important directories:

```text
raw/osm/china/jiangsu
raw/osm/china/anhui
raw/planetiler-sources
products/tiles/pmtiles
products/search
products/routing
products/terrain
runtime/logs
services
scripts
web
docs
```

### OSM Data Download

Downloaded from OSM France:

- Jiangsu PBF
- Jiangsu state file
- Anhui PBF
- Anhui state file

Jiangsu initially downloaded as a truncated file. It was re-downloaded and verified against the expected size.

### Planetiler Setup

Pulled and used:

```text
ghcr.io/onthegomap/planetiler:latest
```

Planetiler downloaded shared support assets:

- Natural Earth vector SQLite zip
- water polygons
- lake centerlines

The first PMTiles build failed due to the truncated Jiangsu PBF and Windows/Docker file access behavior. The stable command used:

```text
--bounds=<explicit bounds>
--osm_lazy_reads=false
```

### PMTiles Generated

Generated:

- `products/tiles/pmtiles/jiangsu.pmtiles`
- `products/tiles/pmtiles/anhui.pmtiles`

Observed sizes:

- Jiangsu: about 136.9 MB
- Anhui: about 110.7 MB

### Initial Web UI

The first working UI used a hand-written MapLibre style. It proved the pipeline but looked too far from OpenStreetMap/OpenFreeMap quality.

### Static Server Change

The first Python static server was replaced by nginx because PMTiles needs HTTP range request support.

Verification:

```text
206 Partial Content
```

for:

```text
Range: bytes=0-1023
```

### PostGIS and Martin

Docker Compose was changed from old `TerraSys-*` containers to:

- `terrasys-postgis`
- `terrasys-martin`
- `terrasys-web`

PostGIS table:

- `app.places`

Martin view:

- `app.places_web`

Seed points:

- Nanjing
- Hefei

### Liberty Style Upgrade

The hand-written style was replaced with OpenFreeMap Liberty:

- downloaded Liberty style JSON;
- downloaded Liberty sprites;
- downloaded Noto Sans Regular/Bold/Italic glyphs;
- removed the online shaded relief layer;
- rewrote the vector source to local Jiangsu/Anhui PMTiles;
- added a real basic legend in the UI.

### Fast OSM-like Default

After testing, the full Liberty style felt slower than the earlier simpler renderer. It duplicated a large number of symbol, bridge, tunnel, POI, and 3D building layers across both Jiangsu and Anhui PMTiles sources.

The default style was changed again to a fast OSM-like standard map:

- OSM Carto-inspired colors;
- fewer total layers;
- no default 3D building extrusion;
- POI labels delayed to high zoom;
- local glyphs retained;
- personal PostGIS points retained.

Liberty assets remain useful as a reference, but they are no longer the default render path.

## 2026-07-11

### Reliability and Security Review

The working demo was upgraded into a maintainable local application:

- exposed only nginx on `127.0.0.1:8080`;
- removed direct host access to PostGIS, Martin, and FastAPI;
- pinned production, build, and browser-test container images by digest;
- moved the database password into an ignored local `.env` file;
- limited nginx mounts to web assets and PMTiles instead of the project root;
- explicitly allowed only `places_web` and `tracks_web` in Martin;
- added security headers, dotfile denial, and upload size limits.

### Versioned Personal Data

The one-time initialization SQL was replaced with ordered migrations. The schema now includes places, MultiLineString tracks, media metadata, optimistic row versions, update timestamps, a row-level change log, GiST indexes, JSONB tags, and trigram search indexes.

A FastAPI write boundary was added for point/track CRUD, GPX import, validated image upload, status, and GeoJSON export. Personal edits no longer depend on modifying a static GeoJSON file or sending database credentials to the browser.

### Atomic Data Builds

Downloads now use staging files and Osmium checks. The production regional PBF is built by extracting both province polygons from the same China snapshot, avoiding duplicate object-version conflicts seen when independently published provincial extracts were merged.

Planetiler now produces one combined `suwan.pmtiles` archive. One source means one style layer stack, which improved rendering speed compared with duplicating every Liberty layer for two overlapping PMTiles files. Builds retain the previous usable product until header, size, and SHA256 checks pass.

The maximum generated zoom was raised from 14 to 16 for better street, building, and POI detail at neighborhood scale.

### Usable Map Interface

The browser was rebuilt as an actual map workspace rather than a proof-of-concept panel. It now has personal-data and layer tabs, a legend, standard/explore styles, named regional views, add/edit point dialogs, GPX import, measurement mode, media actions, export, health status, responsive controls, and visible OSM/OpenMapTiles attribution.

The OSM-like style now includes landcover, land use, parks, waterways, road hierarchy, rail, buildings, boundaries, place/road/water/POI labels, local glyphs, and local POI sprites.

### Recovery and Verification

Backup and restore scripts were added with PostgreSQL custom dumps, media copies, SHA256 manifests, path validation, and retention. Health checks verify API/PostGIS/Martin plus PMTiles byte-range behavior. The API smoke test covers CRUD, search, geometry, GPX, and media cleanup. A containerized Playwright test verifies real canvas rendering, attribution, dialogs, theme switching, and narrow-screen layout with screenshots.

### Browser Validation

Chrome headless verification confirmed:

- page status `200`;
- MapLibre canvas `1440x900`;
- PMTiles sizes shown in UI;
- PostGIS/Martin online;
- 2 personal points loaded;
- browser console had no errors.

Screenshot:

```text
runtime/logs/web-check-liberty.png
```

This screenshot is a local runtime artifact and is not intended for Git by default.

## 2026-07-16

### Offline Reference Search and Readiness

The regional map evolved from browse-only reference data into a searchable local reference system. A versioned migration added `reference_places` and `dataset_state`; an Osmium/FastAPI import pipeline now derives 126,340 named OSM nodes from the same Suwan PBF used by PMTiles.

The search box now combines personal places, personal tracks, and offline OSM reference matches while keeping their ownership visually distinct. A reference result can be inspected on the map and copied into the personal database without mutating the source index.

The system panel now exposes the OSM source date, reference-index count, and latest-backup age. PMTiles builds write a provenance manifest with source and product hashes. Startup can launch Docker Desktop when needed, and the API receives a read-only backup mount solely for readiness reporting.

API and browser smoke tests were expanded to cover unified search, reference copying, metadata readiness, high-zoom rendering, and narrow-layout overlap. Final screenshots are under `runtime/ui-smoke`.

### Exploration and Collections

The map became directly explorable rather than search-only. Rendered OpenMapTiles POIs, places, roads, water, peaks, parks, and buildings can open a right-side detail panel. The click location is enriched with a distance-ranked lookup against the local OSM reference index, and nearby results remain clustered until high zoom.

Versioned collection tables now support Favorites, Travel Plans, Field Research, and user-created collections. Collection membership is saved transactionally with personal places and is included in normal backups. Base-map collection defaults to Favorites without changing the derived OSM index.

Personal point cards now open the same detail surface, showing collections, tags, notes, nearby track suggestions, and a local photo gallery with add/delete actions. Browser tests cover the base-detail, nearby, cluster, collection-manager, default assignment, personal-detail, editor, and narrow-layout flows.

### Disconnected Recovery Kit

The recovery model was expanded from database backups into a complete, portable kit. A kit contains the current application and documentation, a fresh personal database/media backup, the Suwan PMTiles and regional/China PBF inputs, province polygons, cached Planetiler support data, and Docker archives for runtime, map building, data extraction, and browser verification.

Every included file is covered by size and SHA256 metadata. The restore command requires an empty target, loads images locally, starts services without rebuilding, restores data, reapplies newer migrations, and performs the normal health check.

A separate recovery drill starts PostGIS, API, Martin, and nginx on a temporary Docker `--internal` network. It restores the real backup and verifies record counts, search, GeoJSON export, media access, Martin sources, nginx proxies, PMTiles identity, and lack of an external route. The live installation is not stopped, and each drill leaves a JSON audit report after its temporary containers and volume are removed.

### Regional Pack Center and Second Region

The single-map catalog became a versioned region-pack registry. A generic build command now downloads member polygons, extracts every member from one China PBF snapshot, merges and deduplicates OSM objects, runs reference checks, builds a staged Planetiler product, and writes per-pack provenance before atomic replacement.

Shanghai/Zhejiang was selected as the second pack because it is adjacent to Suwan and exercises overlapping coverage. The resulting Huzhe product contains 1,132,075 addressed tiles and 16,437,548 rendered features in a roughly 551 MiB PMTiles archive. Both Suwan and Huzhe pass size, header, and SHA256 checks against the same source sequence.

The System tab now lists pack size, source date, installed/update state, and checksum state. It can verify and activate a pack; activation rebuilds the same OSM-like style around only that source and updates the named view switcher. API, range, and browser tests cover both archives and switching in desktop/narrow layouts. Recovery-kit collection was generalized to include every installed catalog pack instead of a hard-coded Suwan list.

### Advanced Offline Search, Routing, Terrain, and Knowledge

The installed Suwan and Huzhe regional PBFs are now verified against their manifests and merged into `terrasys-core-latest.osm.pbf`. The shared product contains 32,457,952 nodes, 3,264,446 ways, and 91,488 relations in 253,592,396 bytes; both input packs carry China source sequence `7191012`.

Nominatim 5.3 was added as an advanced Compose service with a private PostgreSQL volume, complete address/reverse endpoints, and normalized results appended behind the existing search API. The lightweight 126,340-row index remains in PostGIS for fast nearby and emergency queries.

Valhalla built 847 graph tiles and a 649,687,040-byte tile archive. It downloaded 58 one-degree HGT files totaling roughly 1.4 GiB. The TerraSys adapter decodes polyline6 to GeoJSON, exposes a stable route contract, samples a real elevation profile, and lets planned car/bicycle/walking routes be saved as personal tracks.

MapLibre gained optional locally generated hillshade. The initial implementation performed a filesystem lookup per pixel and took about 60 seconds for a first tile; caching HGT resolution at the one-degree grid level reduced an uncached test tile to about 2.1 seconds and a cached tile to about 0.23 seconds.

Kiwix now serves the verified `wikipedia_zh_all_mini_2026-05.zim` under the same localhost origin at `/wiki/`. The 3,501,641,311-byte file has SHA256 `bde558d74cdfaab5d5fe43b4d400e94b33b146d256892b3f497c8f409d196da0`. The interface links search results and emergency places to the local encyclopedia rather than the public web.

The Layers tab now includes terrain and clustered emergency facilities; the System tab reports address, route, elevation, and encyclopedia readiness. A dedicated route panel supports mode selection, map-picked endpoints, Chinese maneuver labels, distance/time, a real canvas elevation profile, clear, and save.

Recovery packaging was extended to include the capability PBF, route archive/configuration, elevation grids, encyclopedia, pinned advanced images, and a stopped-volume Nominatim snapshot. Health and smoke tests now treat prepared advanced data as a contract and verify every advanced endpoint.

## 2026-07-17: Province-level resource catalog

The original seven China packages were useful for bootstrapping coverage but were too coarse for long-term ownership. They are now retained only as deprecated compatibility bundles. A schema-v3 region catalog defines 34 independent province-level units, six display groups, administrative metadata, exact boundaries, source provenance, storage/time estimates, and build/update/verify/remove commands.

Mainland units are reproducibly extracted from the versioned local China snapshot with cached `.poly` boundaries. Taiwan uses a separate verified Geofabrik source profile. The API distinguishes physical installation, independent installation, compatibility coverage, partial installation, source readiness, and boundary readiness. The resource manager presents every province as one acquisition unit; north/east/etc. are navigation sections only.

`migrate-region-packs.cmd` provides a guarded plan/build/remove lifecycle for replacing an installed compatibility bundle with its member provinces. Shared capability freshness is based on province coverage, preventing a package-layout migration from forcing a redundant search/route rebuild.

The first live migration calibrated the local estimates. Jiangsu extracted to an 83.2 MiB PBF and a 412.7 MiB PMTiles archive; Anhui extracted to a 43.1 MiB PBF and a 329.5 MiB PMTiles archive. Each end-to-end build completed in about 17 minutes on this machine, including extraction, OpenMapTiles generation through z16, atomic replacement, manifest creation, and SHA256 verification. Both previous map files were retained as rollback products, and the `suwan` compatibility bundle remained installed pending visual acceptance.

The migration was then completed instead of retaining permanent compatibility packages. Shanghai built as a 93.7 MiB PMTiles archive and Zhejiang as a 460.6 MiB archive. All four province packages passed SHA256 verification. The static map catalog now has no combination datasets and defaults to Jiangsu; shared capability inputs are rebuilt from the four province PBFs before the old Suwan/Huzhe products, sources, and rollback files are deleted.

The final cleanup removed both combination PMTiles/manifests, both combination PBFs, all old map rollback archives, the previous shared PBF, and the related build directories. About 2.16 GiB of old files were released. `terrasys-core` now lists only `jiangsu`, `anhui`, `shanghai`, and `zhejiang`; the lightweight reference index was regenerated from that source with 340,333 named OSM places. Health, API smoke, and Playwright UI tests run only against province IDs.

### Final Advanced Recovery Validation

The final checksum-verified kit is `D:\TerraSys\offline-kit\20260716-230426`. It contains 960 files and 15,720,219,689 verified bytes (14.64 GiB), including the completed Nominatim volume snapshot and the rebuilt API image. The successful isolated audit is `runtime/recovery-audit/20260716-232131-a6309f11.json`.

The final drill restored fresh personal and Nominatim volumes on a Docker `--internal` network. It verified 126,340 reference places, three collections, six migrations, two PMTiles headers, two Martin sources, three Nominatim results, a 204-point Valhalla route, a 15-metre elevation sample, local Kiwix access, nginx proxies, GeoJSON export, and blocked external routing. All temporary containers, volumes, networks, and work directories were removed afterward.

Four recovery defects were found and fixed during the proof:

- Docker volume discovery now parses `docker inspect` JSON instead of relying on a Go-template expression that was fragile under Windows PowerShell quoting.
- Kiwix verification now checks the OPDS catalog for the packaged `wikipedia_zh_all` archive instead of relying on English homepage text.
- Isolated Valhalla mounts the packaged HGT directory read-only under its writable work directory, preventing an unnecessary graph rebuild.
- Nominatim search/reverse adapters allow a 30-second cold-query window, and the drill retries the first restored query with a bounded policy.

## Key Lessons

- MapLibre is a renderer, not a complete map product.
- Good map UX comes from style, legend, controls, and data richness.
- A full professional style can be too heavy when duplicated across multiple local sources.
- The default browsing style should prefer speed and the familiar OpenStreetMap feel.
- PMTiles plus nginx is a lightweight and robust local basemap path.
- PostGIS plus Martin is a good local personal-data path.
- For GitHub, store the reproducible system, not large generated map artifacts.
## 2026-07-17 global resource implementation

- Replaced placeholder global regions with a generated Geofabrik hierarchy: 547 browse regions and 554 buildable direct-source packs.
- Installed a Natural Earth world overview, 29-city Open-Meteo seven-day snapshot, 5,718 OSM nautical features, and the Chinese Wikivoyage all-maxi ZIM.
- Added weather and nautical map layers, resource actions, local route TTS, and version checks for every displayed resource family.
- Extended `prepare-advanced`, health/smoke tests, and disconnected recovery-kit scripts so the new products are rebuildable, verifiable, and recoverable rather than UI-only entries.
- Built `gf-monaco` through the generic direct-source pipeline (3,286 tiles, roughly 1.1 MiB PMTiles), then verified it in the API and browser.
- Generated the 12.70 GiB schema-v3 recovery kit at `offline-kit/20260717-123630`, synchronized the final shared-index tooling into its 1,026-file manifest, and passed an isolated no-internet recovery drill; current audit evidence is `runtime/recovery-audit/20260717-130445-fb341b80.json`.

## 2026-07-17 resource-management execution model

- Replaced the single-pane drill-down catalog with a persistent desktop split view. The world-level regions remain visible while the active branch expands below them and the selected region or pack renders on the right.
- Replaced copy-command placeholders with `POST /api/maintenance/jobs`. The API validates catalog pack IDs and a fixed resource allowlist; arbitrary commands and unsupported actions are rejected.
- Added `scripts/maintenance-worker.ps1`, a single-instance Windows worker with heartbeat, atomic JSON state, queued/running/succeeded/failed jobs, per-job logs, and clean start/stop integration.
- Added manual item updates, regular update-all, explicit heavy-operation treatment, and automatic weather/global-catalog schedules. Heavy shared-index rebuilds and large downloads are excluded from automatic and regular batches.
- Verified a real manual weather update plus automatic weather and global-catalog updates. All three jobs completed with exit code 0 and refreshed their local products; a Windows child-process exit-code reporting defect found during the first run was fixed and re-tested.

## 2026-07-22 reliability and ownership pass

- Replaced date-guess update labels with cached checks against trusted Geofabrik/OpenStreetMap replication state; map, refresh, missing-product, and shared-index rebuild states are now distinct.
- Added priority, cancellation, retry/backoff, success-based scheduling, and bounded history to the allowlisted maintenance queue; region-pack removal is now a real guarded job.
- Added versioned track editing, track photo ownership, cascade cleanup, orphan cleanup, per-track/all-track GPX exports, and a SHA256-manifested personal ZIP archive containing records and media.
- Installed the daily 03:00 checksum-verified personal-backup task, added optional different-drive mirroring, counted offline kits in storage, and retained only the latest two verified complete kits.
- Repaired global-catalog UTF-8/HTML normalization, removed the Monaco test product, modularized API resource/export helpers and browser formatting helpers, and expanded smoke coverage across version conflicts, routing, media ownership, GPX, and ZIP recovery exports.
- Browser review corrected route search ranking (personal records, full geocoder entities, then nearby references), preserved selected endpoint names, removed overlapping loading/result states, and disabled misleading style actions for uninstalled regions.
- Created and verified `offline-kit/20260722-163908` with 1,033 files (14.88 GiB). The isolated no-internet drill passed after adding a writable maintenance-queue mount; current evidence is `runtime/recovery-audit/20260722-165750-7a07d3e0.json`.
- Removed the single-active-pack rendering restriction. All installed province PMTiles now load together by default, while the combined and per-province shortcuts change only the camera focus.
- Reworked maintenance progress around individual resources. Detached summary-bar cancel buttons were removed; every active row now owns its stage, queue position or elapsed time, progress track, and cancel action. Normal update rows no longer show a fake percentage-like meter. FastAPI derives honest five-stage map progress from live job logs, and the browser no longer launches a costly full resource scan on every three-second status poll.
- Added live throughput to those task rows without inventing unavailable measurements. Curl progress is parsed as bytes/second and received/total bytes; Planetiler archive progress is parsed as tiles/second, generated tiles, feature throughput, and staged output bytes. Historical Zhejiang output verified 1,500 tiles/second, 962,000 generated tiles, and a 482 MiB staged archive; browser fixtures cover the same rendering contract.
- Removed the resource manager's all-or-nothing loading gate. Available regions now render from the loaded catalog, maintenance state and speed render independently, and the last complete local/update inventory is returned from a persistent cache before a background refresh. Thirteen independent storage roots are scanned with a bounded thread pool. On this machine a fresh inventory measured about 15.9 seconds and the cached response about 13 milliseconds, down from a roughly 57-second first display under active map generation.
- Audited OsmAnd as a reference rather than a code donor. Its main code is GPLv3, while its UI/UX layouts and icons are separately CC BY-NC-ND 4.0. TerraSys adopts the resource taxonomy, workflow principles, cache-first behavior, and size-oriented local management with its own desktop UI and implementation; `docs/OSMAND_REFERENCE.md` records the boundary and follow-up backlog.

## 2026-07-31: Update closure and world ownership transition

- Fixed shared-snapshot update semantics. `Update` now refreshes provider state and source data for both direct and extracted packs. The mainland pipeline validates a staged China PBF with Osmium, activates it atomically, and reuses it across queued province updates when the replication sequence is unchanged.
- Added an API current-sequence guard. A successful PMTiles manifest leaves the update list after the next inventory refresh, while a repeated update is rejected; rebuilding from current source is a distinct action.
- Made resource actions truthful. Weather, nautical data, overview, encyclopedia, and travel guide expose real install jobs when absent; map layers open only when installed; libraries, styles, components, and caches no longer masquerade as downloadable layers. Terrain coverage is derived from local HGT files instead of shared search/route coverage.
- Added a local low-zoom world experience and an ownership transition inspired by OsmAnd. A catalog package can be located on the world map, where the user chooses temporary online viewing or the exact offline region build. OpenStreetMap Standard is opt-in, attributed, restricted to current-viewport browsing, and never used for bulk caching.
- Reduced forced resource inventory time by accounting for verified recovery-kit manifests instead of recursively rescanning every large kit payload. Maintenance progress remains independently available while the inventory refreshes.
- Changed health checks to consume the last complete inventory and fall back to a longer first-run scan, preventing false failures when Planetiler is saturating the host.
- Added a targeted Playwright world-map test covering catalog search, package location, selection persistence, online toggle, and return to the same download/build target. Static checks, API guards, container health, and the complete functional smoke suite were rerun.

## 2026-08-02: D-drive migration and maintenance continuity

- Moved the active Docker Desktop WSL store from the C-drive default to `D:\DockerData\wsl` using `CustomWslDistroDir`. Containers, images, named volumes, personal-data counts, the latest backup, seven service health checks, and active VHD writes were verified before treating the D-drive copy as authoritative.
- Removed the inactive 140.81 GiB logical-size C-drive Docker VHD after the D-drive store continued advancing and all seven containers passed another health check. `D:\DockerData\wsl\disk\docker_data.vhdx` remains the sole Docker data disk; the C-drive project path remains only a junction to `D:\TerraSys`.
- Consolidated the evolved project at `D:\TerraSys` and replaced the old C-drive project path with a junction to the active directory. The previous clean published checkout was retained temporarily as a D-drive legacy archive for migration rollback.
- Replaced the remaining synchronous PMTiles verification endpoint with `202 Accepted` maintenance jobs. Large SHA256 checks now remain visible and cancellable without timing out nginx or interrupting map browsing.
- Made resource inventory delivery stale-while-refresh. The API returns the last complete snapshot immediately, starts at most one background scan, and replaces the cache atomically. Maintenance completion no longer deletes the only readable snapshot.
- Corrected the smoke test's regional assumption: shared search/route coverage is compared with every enabled installed map pack, including global country packs, rather than only Chinese provinces.
- Diagnosed an incomplete Nominatim import: 33.7 million `placex` rows existed, but database version metadata and the two search-vector GIN indexes were missing. PostgreSQL statistics were refreshed and Nominatim `db-postprocess` was resumed in place. The final self-check passed database version, content, tokenizer, indexing status, index completeness, and index validity.
- Re-ran health, full API/data lifecycle smoke, world-map Playwright, main UI Playwright, and standalone resource-console Playwright tests. All passed after updating browser assertions for asynchronous verification and realistic cold-start rendering time.

## 2026-08-02: Map-source control and live coverage state

- Replaced the WiFi shortcut's binary toggle with an adjacent source menu for offline-only, OSM Standard, and OpenFreeMap. The control shows the preferred choice, actual fallback source, connection state, and current offline coverage without colliding with transient notifications.
- Changed browsing-region detection from MapLibre's padding-shifted camera center to the center of the unobstructed map area between active panels. Focusing Jiangsu now reports Jiangsu instead of the adjacent Anhui package, while ordinary pan/zoom updates remain live.
- Added package-bounds prefiltering before polygon checks, preventing unrelated boundary data from matching distant viewports. Coverage URL targets are also applied before the first generic prompt can appear.
- Localized country prompts through ISO region names with explicit Chinese fallbacks for Japan, Taiwan, Hong Kong, and Macao. User-facing copy now consistently says **download offline map** instead of exposing build-pipeline terminology.
- Expanded the world-map Playwright suite across Japan, Jiangsu, and Taiwan, plus toast/shortcut overlap, all three manual sources, OSM-to-OpenFreeMap fallback, and full offline degradation. Health, API lifecycle, resource-console, main UI, and targeted world-map tests all passed.

## 2026-08-02: TerraSys product identity and default map workspace

- Standardized the provisional user-facing identity across the map, resource console, API metadata, exported GPX files, command output, tests, and primary documentation.
- Deferred runtime identifier migration until the database, Docker volumes, browser settings, scheduled tasks, and recovery paths could be migrated together and tested.
- Changed the map's first frame to start with the left side panel collapsed and inert. The shared side-panel state function now keeps animation, keyboard focus, ARIA state, toggle icon, coverage detection, and programmatic panel opening synchronized.
- Rebuilt the API image and corrected the resource-console browser fixtures to expect the four truly installed independent province packs instead of a stale five-row assumption.
- Split shared-index readiness into coverage completeness and exact scope freshness. The active four provinces remain searchable/routable when an older index contains harmless extra Germany coverage, while the resource manager still requires a rebuild; an index missing any enabled pack remains blocked.

## 2026-08-03: storage ownership and shared-index retention

- Rebuilt Nominatim and Valhalla from the two installed Jiangsu/Anhui packs, validated the candidates, atomically activated them, and removed the former Germany-inclusive search and routing indexes only after a new disconnected recovery kit passed every SHA256 check.
- Added resumable late-stage shared-index activation, active-mount-aware version pruning, dynamic validation points, compact Valhalla tar-only retention, and startup detection that follows the active `VALHALLA_DATA_PATH` pointer.
- Expanded recovery schema v4 to snapshot Nominatim and OSM Carto, include OSM Carto source provenance, restore its external volume before startup, and retain one verified complete kit by default.
- Removed obsolete Germany, Monaco, Shanghai, Zhejiang, and legacy duplicate province sources. The legacy OSM download entry now maintains only the shared China snapshot so it cannot recreate a second Jiangsu/Anhui source tree.
- Removed unmounted historical PostGIS volumes, obsolete images, and renewable build cache. After filesystem trim, compacted the Docker VHDX from 140.81 GiB to 24.51 GiB, then restarted all eight containers and passed health plus the complete functional smoke suite.
- Corrected the functional smoke test to compare temporary record counts against the database baseline instead of assuming a fixed amount of pre-existing personal data.

## 2026-08-09: complete TerraSys identity migration

- Unified product text, source identifiers, scripts, container and image names, environment variables, browser storage, database names, capability manifests, tests, recovery payloads, paths, and documentation under `TerraSys`.
- Preserved user data with a pre-migration PostgreSQL snapshot, an in-place database rename, one-time browser-setting migration, and explicit pointers to the already verified large Docker index volumes.
- Established `D:\TerraSys` and the Documents TerraSys junction as the canonical project paths without duplicating data, rebuilt the eight-service stack, and exercised static, API, browser, world-map, resource-console, and performance checks before publication.
