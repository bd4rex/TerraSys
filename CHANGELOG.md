# Changelog

> English | [简体中文](CHANGELOG.zh-CN.md)
>
> History updated: `2026-08-07T13:09:44+08:00`

This changelog documents user-visible development milestones. It follows the human-readable grouping used by mature open-source projects and records ISO 8601 timestamps.

The repository had no tags or GitHub Releases before this file was introduced. The `M0.x` labels below are retrospective documentation labels. Commit hashes and timestamps are the source of truth; no historical releases are implied.

## Unreleased — resilient global browsing and regional expansion

- **Development snapshot:** `2026-08-07T13:09:44+08:00`

### Added

- A complete Ubuntu server deployment path with a unified `terrasys.sh` command surface, Docker Engine/PowerShell 7 compatibility, systemd boot service, daily backup timer, configurable trusted-interface binding, and Linux CI coverage.
- An independent additional-information-layer module with normalized GeoJSON adapters, TTL caching, viewport cropping, and graceful degradation for USGS, NASA EONET, GDACS, Open-Meteo, ADSB.lol, NOAA NDBC, and the Norwegian open AIS stream.
- The former contour shortcut is now the P0/P1 information-layer entry; contours remain in the ordinary layer panel, with ADS-B/AIS refresh, provenance popups, and a quick jump to the AIS coverage area.
- A decision catalog records keyed-source application paths and published call limits while the runtime remains `no-key-only`.
- A standalone additional-information-source console now manages no-key enablement, refresh cadence, bounded connection tests, runtime health, coverage, and licenses, with settings persisted in the maintenance directory.
- A Natural Earth 110m/50m/10m vector PMTiles overview with land, water, boundaries, places, roads, railways, and rivers through zoom 7.
- Region-aware elevation synchronization backed by AWS Open Data Terrain Tiles, with retained HGT manifests and maintenance progress.
- ETag-backed map-pack and boundary responses, deferred catalog loading, cache warming, and a browser performance smoke test.
- A machine-readable test-case catalog and unified `static`, `browser`, `full`, and `recovery` profiles, with static contracts running automatically on GitHub pull requests.

### Fixed

- Kept the verified existing geocoder and routing scope usable while newly installed regions are still being indexed.
- Kept a regional PMTiles vector fallback visible until OSM Carto has caught up, preventing blank maps after installing a region.
- Deduplicated overlapping regional OSM objects before Carto, search, and routing builds.
- Prevented map panning from rebuilding the complete MapLibre style or hiding installed layers still inside the viewport.
- Replaced rectangular country guesses with precise country polygons, including antimeridian handling, and suppressed low-zoom false download prompts.
- Normalized map-package prompts, resource names, feature details, and world-overview labels to display `台湾省` consistently.
- Normalized the weather JQ program to LF before mounting it into Linux containers, preventing repeated first-run failures for newly installed country packages on a Windows checkout.
- Normalized container-mounted shell scripts, waited for local Carto assets to become ready, and constrained heavy builds for a 16 GiB host.

### Improved

- Accelerated terrain tile generation by loading each required HGT grid once per row group instead of once per pixel.
- Minified the generated global catalog without changing its 547 browse regions or 554 buildable datasets, and enabled nginx compression and explicit config revalidation.
- Expanded world-map regression coverage for Carto lag, vector fallback, global movement, country selection, and persistent overview rendering.
- Added static JSON/PowerShell, bilingual-document parity, relative-link, browser-image completeness, and performance-baseline checks.

## M0.9 — Local OSM Carto rendering and cache reliability

- **Commit:** [`d360249`](https://github.com/bd4rex/TerraSys/commit/d360249de86110511eb7ae5f49e8237d810f5d96)
- **Timestamp:** `2026-08-04T16:22:49+08:00`
- **Git status at the time:** direct `main` commit; no tag or Release

### Fixed

- Prewarmed candidate OSM Carto tiles, copied validated cache entries during activation, and cleared them during rollback.
- Added dedicated Apache tile-render timeouts and nginx proxy timeouts for slow first renders.
- Synchronized local/online map-source controls and allowed deterministic URL coordinates for regression testing.

## M0.8 — Automatic regional strategy propagation

- **Commit:** [`6daeff6`](https://github.com/bd4rex/TerraSys/commit/6daeff6458177b6aa6b4f2ad1fe0dc4640027653)
- **Timestamp:** `2026-08-04T07:39:54+08:00`
- **Merged by:** [PR #7](https://github.com/bd4rex/TerraSys/pull/7)

### Added

- Blue-green OSM Carto candidate volumes with non-empty tile validation for every enabled region.
- Dynamic weather-location extraction, regional weather/nautical provenance, and elevation-coverage manifests.
- Automatic lightweight weather and nautical follow-up jobs after regional build, update, removal, enable, or disable changes the active scope.

### Fixed

- Included Shandong in OSM Carto, shared search/routing, weather, nautical, and elevation coverage after its base package was installed.
- Prevented whole-service health from hiding missing derivative coverage for newly installed regions.
- Compared per-region source SHA256 values, not only region IDs, before declaring search, routing, Carto, weather, or nautical coverage current.
- Resolved installed source paths from package manifests so later country and regional packages inherit the same pipelines.
- Removed the obsolete Jiangsu/Anhui Carto merge and pruned 97 unrelated historical HGT grids from the new routing candidate.

### Improved

- Reused verified local Carto water, ice-sheet, and low-zoom boundary archives instead of downloading them for every regional expansion.
- Added real Valhalla route checks for every enabled region and smoke-test assertions that derivative scopes match enabled packages.

## Documentation snapshot — 2026-08-03T23:12:23+08:00

### Added

- English and Simplified Chinese entry points for the project and every maintained document.
- A bilingual documentation index and cross-language navigation.
- This commit-based historical version record.

### Changed

- Rewrote the main README in English and added a feature-equivalent Chinese README.
- Updated architecture and operations descriptions for the eight-service stack, OSM Carto renderer, resource lifecycle, and disconnected recovery model.

## M0.7 — Storage ownership and offline-map lifecycle

- **Commit:** [`b2a6503`](https://github.com/bd4rex/TerraSys/commit/b2a6503304fbea851a968d7cdabeddb1b7e1a81c)
- **Timestamp:** `2026-08-03T18:13:25+08:00`
- **Git status at the time:** direct `main` commit; no tag or Release

### Added

- Local OSM Carto build and repair pipeline with resumable external-data preparation.
- Rich-detail Planetiler overlay builds and schema-v3 package manifests.
- Shared-index candidate activation, pruning, and active-version retention.
- OSM Carto data in recovery-kit schema v4 and isolated recovery validation.

### Improved

- Rebuilt Nominatim and Valhalla around the installed Jiangsu and Anhui scope.
- Removed obsolete Germany, Monaco, Shanghai, Zhejiang, and duplicate regional sources after recovery validation.
- Compacted Docker storage after pruning unused volumes, images, and renewable cache.
- Expanded resource-console status, task actions, tests, and honest progress reporting.

## M0.6 — TerraSys identity and default workspace

- **Commit:** [`c1de372`](https://github.com/bd4rex/TerraSys/commit/c1de372c6d69cc5ddf77d409438c4a06bf012d2e)
- **Timestamp:** `2026-08-02T14:38:57+08:00`
- **Merged by:** [PR #5](https://github.com/bd4rex/TerraSys/pull/5)

### Changed

- Renamed the user-facing product from TerraSys to TerraSys while retaining compatibility identifiers.
- Made the map open with the side panel collapsed and synchronized focus, ARIA, animation, and coverage state.
- Separated shared-index coverage completeness from exact scope freshness.

## M0.5 — Product requirements baseline

- **Commit:** [`a6309f8`](https://github.com/bd4rex/TerraSys/commit/a6309f84085b0f8bc6295c444bfd26370b933844)
- **Timestamp:** `2026-08-02T08:07:31+08:00`
- **Merged by:** [PR #4](https://github.com/bd4rex/TerraSys/pull/4)

### Added

- Explicit product principles for data ownership, offline behavior, truthful state, reliability, and delivery.
- Requirements for regional maps, personal data, resource/version management, rollback, and recovery.

## M0.4 — D-drive Docker storage cleanup record

- **Commit:** [`cd28db5`](https://github.com/bd4rex/TerraSys/commit/cd28db5cde78b6dcdb78a962c3b8923de8e61491)
- **Timestamp:** `2026-08-02T07:53:13+08:00`
- **Merged by:** [PR #3](https://github.com/bd4rex/TerraSys/pull/3)

### Improved

- Recorded verification of the Docker Desktop WSL migration to `D:\DockerData\wsl`.
- Documented removal of the inactive C-drive VHD only after service, volume, backup, and API checks passed.

## M0.3 — Map-source controls and live coverage

- **Commit:** [`725ae42`](https://github.com/bd4rex/TerraSys/commit/725ae424c7cb00b86733ebdf2b025ace30d8cf0a)
- **Timestamp:** `2026-08-02T03:20:56+08:00`
- **Merged by:** [PR #2](https://github.com/bd4rex/TerraSys/pull/2)

### Added

- Explicit Offline, OpenStreetMap Standard, and OpenFreeMap source selection.
- Preferred-source, actual-source, fallback, connectivity, and local-coverage status.
- Viewport-aware region detection and localized package prompts.

### Improved

- Expanded browser tests for manual source selection, fallback, offline degradation, and region ownership prompts.

## M0.2 — Offline GIS platform expansion

- **Commit:** [`9d2ea5d`](https://github.com/bd4rex/TerraSys/commit/9d2ea5d29a1e3b7bd4cf0717e6ebe2606c11d3d6)
- **Timestamp:** `2026-08-02T02:42:50+08:00`
- **Merged by:** [PR #1](https://github.com/bd4rex/TerraSys/pull/1)

### Added

- FastAPI, ordered PostGIS migrations, Martin, nginx, Nominatim, Valhalla, Kiwix, terrain, and a maintenance worker.
- Independent Chinese province packages and a synchronized global Geofabrik catalog.
- Resource manager, local world overview, weather and nautical layers, personal media, collections, and portable exports.
- SHA256 backups, complete disconnected recovery kits, and isolated recovery drills.
- Health, functional API, UI, resource-console, and world-map test suites.

### Improved

- Replaced the bootstrap file-based map with a manifest-driven local-first platform.
- Added atomic builds, candidate validation, rollback, cache-first inventory, real maintenance progress, and version-aware updates.

## M0.1 — Initial personal GIS publication

- **Commit:** [`aa76756`](https://github.com/bd4rex/TerraSys/commit/aa76756ad887590574cdd622b4a2133f4dafc7ba)
- **Timestamp:** `2026-08-01T18:44:56+08:00`
- **Git status at the time:** initial repository commit; no tag or Release

### Added

- Initial MapLibre browser interface and sample GeoJSON personal places.
- PostGIS and Martin Compose services.
- Local architecture, resource configuration, operations, and MVP planning documents.
- PowerShell launch helpers for the local stack and web server.

## Pre-Git development record

The repository was first published on 2026-08-01, but [docs/PROCESS_LOG.md](docs/PROCESS_LOG.md) records local implementation work from 2026-07-03 onward. Those dates describe work events and validation evidence, not Git release timestamps.
