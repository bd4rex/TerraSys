# Rebuild From Scratch

> English | [简体中文](REBUILD.zh-CN.md) · Snapshot `2026-08-04T02:45:00+08:00`

This procedure reconstructs the region-extensible system from repository files and upstream open data. Jiangsu, Anhui, and Shandong are the currently installed experimental scope.

## Prerequisites

- Windows 10/11 with PowerShell 5.1 or newer;
- Docker Desktop with Linux containers;
- at least 8GB available memory for a build and 16GB total host memory; 32GB is recommended;
- at least 100GB free disk for the current three-province system; keep 180GB free when retaining blue-green databases, rebuilding shared indexes, and creating a recovery kit in the same maintenance window;
- internet access during the download phase.

The normal runtime works offline after images, browser assets, and data are present.

## 1. Restore the repository

Place the project at `D:\TerraSys`. Do not restore `services/.env` from a public repository.

For this workstation, Docker Desktop data is also kept off C at `D:\DockerData\wsl` through the Docker Desktop setting `CustomWslDistroDir`. A source checkout does not create or move that Docker data; configure the location before restoring large images and volumes.

Expected source directories:

```text
services/
scripts/
web/
tests/
docs/
```

## 2. Start the application database and services

```powershell
D:\TerraSys\start-terrasys.cmd
```

The start script:

1. creates `services/.env` with a strong random password when absent;
2. starts PostGIS and waits for readiness;
3. synchronizes the database role password;
4. applies ordered SQL migrations;
5. builds and starts FastAPI, Martin, and nginx.

At this point personal data features work, but the base map requires the PMTiles product.

## 3. Download browser assets

```powershell
D:\TerraSys\download-web-assets.cmd
```

This installs local MapLibre, PMTiles JS, Lucide, glyphs, and sprites. Keep the generated asset manifest for provenance.

## 4. Download OSM data

```powershell
D:\TerraSys\download-osm.cmd
```

The authoritative build input is:

```text
D:\TerraSys\raw\osm\china\china-latest.osm.pbf
```

The legacy download entry maintains the shared China snapshot and replication metadata only; it does not recreate duplicate province source trees. The 34 province-level boundaries live under `raw/osm/polygons`; mainland units share the China snapshot, while Taiwan has an independent Geofabrik source profile.

## 5. Build province maps

```powershell
D:\TerraSys\region-pack.cmd Plan -PackId jiangsu
D:\TerraSys\region-pack.cmd Build -PackId jiangsu
D:\TerraSys\region-pack.cmd Build -PackId anhui
D:\TerraSys\region-pack.cmd Build -PackId shandong
```

Each command extracts and builds one independently versioned OpenMapTiles PMTiles archive through zoom 16:

```text
D:\TerraSys\products\tiles\pmtiles\jiangsu.pmtiles
D:\TerraSys\products\tiles\pmtiles\anhui.pmtiles
D:\TerraSys\products\tiles\pmtiles\shandong.pmtiles
```

On current hardware each province can take tens of minutes. A final file replaces the previous product only after size/header checks and manifest creation. Build every required province explicitly with `region-pack.cmd`.

## 6. Build the offline reference index

```powershell
D:\TerraSys\import-reference-search.cmd
```

This derives the named-place search index from `terrasys-core-latest.osm.pbf` and records the source timestamp and SHA256 in PostGIS. The current full database dump includes the index for faster recovery, but it remains safe to rebuild from the shared installed-province source.

## 7. Build advanced offline capabilities

```powershell
D:\TerraSys\prepare-advanced.cmd
```

This creates the shared capability PBF, downloads the configured Chinese Wikipedia and Wikivoyage ZIMs, prepares the overview, weather, and nautical products, builds Valhalla graph/elevation products, and imports Nominatim. On a 16 GiB Windows host, finish Valhalla before Nominatim indexing so Docker's memory limit is not shared by both heavy builds.

Build the familiar local OSM Carto renderer as a separate resumable operation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\build-osm-carto.ps1
```

Its blue-green candidate automatically discovers installed and enabled regions, renders a non-empty validation tile in every region, and reuses verified local Carto external-data archives. Its database and tile cache are included in complete recovery kits.

## 8. Verify

```powershell
D:\TerraSys\health-check.cmd
D:\TerraSys\smoke-test.cmd
```

Then open:

```text
http://localhost:8080/
```

For visual regression testing, build and run the Playwright container documented in `docs/OPERATIONS.md`.

## 9. Establish a recovery point

```powershell
D:\TerraSys\backup-terrasys.cmd
```

Copy these items to a second physical disk for disaster recovery:

- the Git repository;
- `backups/`;
- every installed `products/tiles/pmtiles/*.pmtiles` and matching manifest;
- `raw/osm/china/china-latest.osm.pbf` and province polygons;
- `raw/osm/china/terrasys-core-latest.osm.pbf`, `products/routing/valhalla`, `products/encyclopedia`, and `products/osm-carto`;
- Docker image archives if rebuilding must work without an image registry.

## Fully disconnected rebuild preparation

A Git checkout and database backup are not enough for a no-network rebuild. Create and exercise the complete recovery package instead:

```powershell
D:\TerraSys\create-offline-kit.cmd
D:\TerraSys\test-offline-recovery.cmd
```

The package includes pinned runtime images, locally built API/Osmium/UI-test images, Planetiler and its cached inputs, the current PMTiles/PBF products, and a fresh personal backup. Follow `docs/OFFLINE_RECOVERY.md` for checksum verification and replacement-computer restoration. Keep a tested Docker Desktop installer separately because it cannot be reproduced from the project.
