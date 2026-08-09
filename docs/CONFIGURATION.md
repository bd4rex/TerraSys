# Configuration

> English | [简体中文](CONFIGURATION.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## Host ports

| Address | Use |
| --- | --- |
| `http://localhost:8080/` | Map application |
| `http://localhost:8080/api/health` | API and PostGIS health |
| `http://localhost:8080/martin/catalog` | Published vector-tile catalog |
| `http://localhost:8080/tiles/<pack>.pmtiles` | Regional PMTiles with HTTP Range support |
| `http://localhost:8080/tiles/<pack>.manifest.json` | Per-pack source and product provenance |
| `http://localhost:8080/wiki/` | Local Chinese encyclopedia |

PostGIS `5432`, Martin `3000`, FastAPI `8000`, Nominatim `8080`, Valhalla `8002`, and Kiwix `8080` are container-internal only.

## Local secret

`services/.env` contains:

```dotenv
POSTGRES_PASSWORD=<long-random-local-password>
NOMINATIM_PASSWORD=<independent-long-random-local-password>
```

The file is ignored by Git. `scripts/start-terrasys.ps1` creates a 32-byte random password if the file is missing and synchronizes it with the existing `gis` database role.

## Compose services

The Compose project lives in `services/docker-compose.yml`.

| Service | Persistent data | Host exposure |
| --- | --- | --- |
| `postgis` | Docker volume `terrasys_postgis_data` | none |
| `api` | `data/media`, `data/exports`; read-only backups, maps, resources, and recovery kits | none |
| `martin` | PostGIS views | none |
| `web` | read-only `web`, read-only PMTiles | `127.0.0.1:8080` |
| `nominatim` (`advanced`) | Docker volume `terrasys_nominatim_data` | none |
| `valhalla` (`advanced`) | `products/routing/valhalla` | none |
| `kiwix` (`advanced`) | read-only `products/encyclopedia` | none |
| `osm-carto` (`advanced`) | external Docker volume `terrasys_osm_carto_data`; `data/osm-carto-tiles` | none |

All third-party runtime images are pinned by digest. The API image is built from `services/api/Dockerfile` with exact Python dependency versions.

`VALHALLA_FORCE_REBUILD` and `VALHALLA_IGNORE_PBF` have safe normal-start defaults and are overridden only by `rebuild-shared-indexes.cmd`. They should not be persisted in `.env`.

## nginx routes

| Route | Target |
| --- | --- |
| `/` | local `web/index.html` |
| `/assets/`, `/vendor/` | local browser assets |
| `/tiles/` | read-only PMTiles directory |
| `/api/` | FastAPI |
| `/martin/` | Martin |
| `/wiki/` | Kiwix, configured with the same URL prefix |
| `/carto/` | local OSM Carto raster tiles |
| `/web/` | compatibility redirect to `/` |
| `/healthz` | nginx liveness |

PMTiles requires byte-range responses. `health-check.ps1` verifies a `206 Partial Content` response instead of only checking for HTTP 200.

## Map catalogs

`web/config/region-catalog.json` is the authoritative installable-region registry. It contains exactly 34 Chinese province-level units, grouped into six display sections, plus two source profiles:

- `china-common`: extract one province from the verified local China snapshot and cached `.poly` boundary;
- `taiwan-geofabrik`: use an independently downloaded, MD5-verified Geofabrik PBF.

Every province entry carries its administrative type, abbreviation, bounds, source-size reference, and long-term/temporary storage and build-time estimates. URL, manifest, source-PBF, and polygon paths are generated from catalog templates. `scripts/catalog-utils.ps1` and FastAPI independently expand the same JSON and tests require both to produce exactly 34 province units.

`web/config/world-region-catalog.json` is generated from Geofabrik's index and adds the browse hierarchy plus direct-source definitions for more than 550 global country/region packs. `web/config/map-catalog.json` retains rendering limits and a fallback initial pack. At runtime, every verified installed pack is added as a MapLibre vector source; the combined/per-region controls change camera bounds only. Combination packs are not catalog entries.

`GET /api/map-packs` reports independent installation, partial files, build readiness, source/boundary readiness, source provenance, estimates, and update state. A province is installed only when both PMTiles and its manifest exist. `POST /api/map-packs/{id}/verify` returns `202 Accepted` and queues SHA256 work; hashing a multi-gigabyte archive never occupies an nginx request. Browser actions submit only catalog-constrained jobs to the local maintenance worker.

## Resource catalog and inventory

`web/config/resource-catalog.json` defines the resource taxonomy independently from installed map products. `world-region-catalog.json` fills every continent with buildable Geofabrik regions, while China links to all 34 province IDs. All displayed resource types now have an installed implementation or a concrete regional acquisition command; the UI no longer presents placeholder-only entries.

`GET /api/resources?cached=true` returns the last atomically completed inventory. A plain `GET /api/resources` returns that snapshot immediately and starts one lock-protected refresh thread; `?check_upstream=true` also refreshes trusted provider state. The completed scan replaces the cache atomically. Maintenance jobs preserve the previous snapshot, so map verification or rebuilding cannot leave the resource page empty. The inventory covers maps, OSM sources, routes, elevation, knowledge archives, web assets, backups, PostGIS, media, and regenerable caches. Docker-managed Nominatim storage is labeled separately because its volume size is not part of the host-path total.

## Host storage locations

The active project is `D:\TerraSys`. `C:\Users\Administrator\Documents\TerraSys` is a compatibility junction to that directory so older shortcuts continue to work without retaining a second project copy.

Docker Desktop's WSL data root is `D:\DockerData\wsl`. The persisted Docker setting is:

```json
"CustomWslDistroDir": "D:\\DockerData\\wsl"
```

Verify the active location in `%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log` or by checking that `D:\DockerData\wsl\disk\docker_data.vhdx` advances. During a future migration, do not delete the previous VHD until containers, images, volumes, API counts, and a backup have all been checked from the destination copy.

On 2026-08-02, the migrated D-drive store passed those checks and the inactive `C:\Users\Administrator\AppData\Local\Docker\wsl\disk\docker_data.vhdx` was removed. On 2026-08-03, obsolete volumes, images, and renewable build cache were pruned after a recovery kit passed; filesystem trim and offline compaction reduced the active VHDX from 140.81 GiB to 24.51 GiB. The D-drive VHD is the only retained Docker data disk, and all eight TerraSys containers passed health and functional smoke checks after compaction.

The product and runtime identity is `TerraSys`. New paths, containers, images, environment variables, browser keys, scheduled tasks, database names, and offline-kit payloads use `TerraSys`, `terrasys`, or `TERRASYS_*` according to context. During an in-place upgrade, `services/.env` may point at previously verified physical Docker volumes; those volume pointers are data-location compatibility settings rather than product identity.

## Style and local assets

- `web/src/map-style.js`: layer definitions and standard/explore palettes;
- `web/assets/glyphs/`: local Noto Sans glyph PBF files;
- `web/assets/sprites/ofm_f384/`: local sprite PNG/JSON;
- `web/vendor/`: pinned MapLibre, PMTiles, and Lucide browser libraries.
- `config/osm-carto/`: local OSM Carto external-data configuration;
- `config/planetiler/`: project-owned rich-detail overlay configuration.

`scripts/download-web-assets.ps1` downloads into staging paths, verifies basic size, then moves assets into place. It writes a local manifest with source URLs and versions.

## Martin allow-list

`services/martin/config.yaml` declares only:

- `places_web`
- `tracks_web`

Do not enable automatic publication of every table in the database. New spatial data should be exposed through a reviewed view with only the columns needed by the map.

## API surface

| Route | Method | Purpose |
| --- | --- | --- |
| `/api/places.geojson` | GET | list or search personal places |
| `/api/places` | POST | create a point |
| `/api/places/{id}` | PUT/DELETE | edit or delete a point |
| `/api/collections` | GET/POST | list or create personal point collections |
| `/api/collections/{id}` | PUT/DELETE | edit or delete a custom collection |
| `/api/tracks.geojson` | GET | list tracks |
| `/api/tracks` | POST | create a GeoJSON track |
| `/api/tracks/{id}` | PUT/DELETE | versioned track edit or owned-record deletion |
| `/api/tracks/{id}.gpx` | GET | export one track as GPX |
| `/api/search` | GET | unified personal and offline OSM reference search |
| `/api/reference/nearby` | GET | distance-ranked local OSM reference lookup |
| `/api/map-packs` | GET | list catalog packs and installed/update state |
| `/api/map-packs/{id}/verify` | POST | verify an installed PMTiles SHA256 |
| `/api/resources` | GET | disk usage, local resource inventory, regional coverage, and update checks |
| `/api/maintenance` | GET | worker heartbeat, settings, queue, and history |
| `/api/maintenance/jobs` | POST | queue one allowlisted build/update/remove action |
| `/api/maintenance/jobs/{id}` | DELETE | request cancellation of a queued/running job |
| `/api/maintenance/jobs/{id}/retry` | POST | requeue a failed/cancelled job |
| `/api/imports/gpx` | POST | import a GPX file |
| `/api/media` | POST/GET | upload or list validated images |
| `/api/media/orphans` | DELETE | clean unowned legacy media metadata/files |
| `/api/export/geojson` | GET | export personal data |
| `/api/export/gpx` | GET | export all personal tracks as GPX |
| `/api/export/archive` | GET | export GeoJSON, GPX, collections, metadata, media, and SHA256 manifest as ZIP |
| `/api/status` | GET | counts, reference snapshot, and latest-backup readiness |
| `/api/capabilities` | GET | prepared-source and advanced-engine readiness |
| `/api/geocode` | GET | normalized Nominatim address results |
| `/api/reverse` | GET | normalized reverse-geocoded address |
| `/api/route` | POST | normalized Valhalla route, maneuvers, and elevation profile |
| `/api/elevation` | GET | local HGT point elevation |
| `/api/terrain/{z}/{x}/{y}.png` | GET | on-demand Terrarium terrain tile through zoom 12 |
| `/api/emergency.geojson` | GET | bounded medical, rescue, shelter, supply, and fuel references |
| `/api/weather` | GET | installed Open-Meteo weather snapshot |
| `/api/nautical` | GET | installed local OSM nautical reference layer |
| `/api/encyclopedia/search` | GET | validated local encyclopedia search link |

All coordinates sent to the API use WGS84 longitude/latitude (`EPSG:4326`). PostGIS indexes geometry using GiST.
