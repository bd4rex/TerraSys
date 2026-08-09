# TerraSys Jiangsu / Anhui Local Map MVP

> English | [简体中文](mvp-d-terrasys.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## Objective

This MVP is a user-owned offline geographic system rather than a map demo:

- locally rendered and independently versioned OSM reference maps;
- personal places, tracks, photos, collections, tags, ratings, and notes;
- GPX import/export and portable GeoJSON/ZIP exports;
- PostGIS spatial indexes, optimistic versions, and change history;
- checksum-protected backup, restore, and disconnected recovery;
- local address search, reverse geocoding, routing, elevation, terrain, emergency references, and Chinese knowledge.

## Entry point

```text
http://localhost:8080/
```

JSON at `/api/health` or `/martin/catalog` is expected; those are machine APIs.

## Data layers

| Layer | Current implementation | Ownership |
| --- | --- | --- |
| Familiar reference map | OSM → osm2pgsql/PostGIS → OSM Carto/Mapnik | Derived and rebuildable |
| Interactive vector map | OSM → Planetiler → independent Jiangsu/Anhui PMTiles | Derived, portable, clickable |
| Personal data | FastAPI → PostGIS; SHA256 media | Durable source of truth |
| Browser | MapLibre, local styles, fonts, and sprites | Replaceable client |
| Advanced reference | Nominatim, Valhalla, HGT, Kiwix | Replaceable behind local APIs |

## Current scope

- Jiangsu and Anhui independently verified PMTiles through z16, rendered together.
- Local OSM Carto as the default familiar map and PMTiles as the interactive vector alternative.
- Roads, buildings, water, land use, boundaries, labels, POIs, terrain, weather, nautical, and emergency layers.
- Personal point/track/media lifecycle, collections, search, statistics, backup, and exports.
- Full address search, reverse lookup, driving/cycling/walking routes, route elevation, contours, and local knowledge.
- Health, API lifecycle, resource-console, main UI, and world-map browser tests.

## Run and maintain

```powershell
D:\TerraSys\start-terrasys.cmd
D:\TerraSys\health-check.cmd
D:\TerraSys\smoke-test.cmd
D:\TerraSys\backup-terrasys.cmd
```

Only `127.0.0.1:8080` is host-facing. Refer to the [README](../README.md), [architecture](ARCHITECTURE.md), [operations](OPERATIONS.md), and [rebuild guide](REBUILD.md) for authoritative details.
