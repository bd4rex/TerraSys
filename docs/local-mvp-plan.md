# Local TerraSys MVP Plan

> English | [简体中文](local-mvp-plan.zh-CN.md) · Historical document

This is an archived planning record. It explains the alternatives considered before the current system existed; it is not a deployment guide. See the [project README](../README.md) and [architecture](ARCHITECTURE.md) for the current implementation.

## Original objective

Validate an evolvable personal GIS loop before building a complete custom mobile application:

```text
Desktop management -> mobile viewing/collection -> marker synchronization -> web map -> durable local archive
```

## Principles evaluated

- Keep replaceable reference maps separate from irreplaceable personal records.
- Prefer open formats: GeoPackage, GPX, GeoJSON, and PostGIS.
- Reuse a mature mobile application before investing in a custom client.
- Prove a small regional workflow before hosting global data.
- Preserve a migration path from files to PostGIS and a local API.

## Alternatives

| Route | Strength | Limitation | Intended stage |
| --- | --- | --- | --- |
| OsmAnd + Syncthing + QGIS | Fast start and mature offline navigation | Weak structured merge/conflict model | Habit validation |
| QGIS + QField + GeoPackage | Professional forms, photos, points, lines, and polygons | Requires QGIS/QField project setup | Recommended early MVP |
| QGIS + self-hosted QFieldCloud + PostGIS | Long-term database and synchronization | Heavier initial deployment | Later MVP / v1 |
| Mergin Maps CE + QGIS | Mature field workflow and open server edition | Tied to its server model | Alternative sync route |
| Custom web/mobile + PostGIS | Complete product control | Highest offline and synchronization cost | v2 or later |

## Original recommended path

```text
Short term: OsmAnd or QField + GeoPackage
Long term: PostGIS + Martin + MapLibre
```

The file-first plan proposed a `places` dataset with stable ID, name, category, WGS84 geometry, notes, tags, rating, source, photo path, timestamps, and synchronization state. Future tables would add visits, collections, tracks, attachments, and version history.

## Planned phases

### Phase 0 — File proof

- Create `places.gpkg` or GeoJSON.
- Import OsmAnd favorites/GPX into QGIS.
- Confirm at least ten classified personal points and refine fields.

### Phase 1 — QField collection

- Build a QGIS/QField project with mobile forms.
- Capture points, notes, and photos on the phone.
- Verify that records and relative media paths return locally.

### Phase 2 — Local web view

- Render exported GeoJSON with MapLibre or Leaflet.
- Display categories and detail popups.
- Start with an online or small offline base map.

### Phase 3 — PostGIS core

- Start PostgreSQL/PostGIS in Docker.
- Import the stabilized personal schema.
- Publish reviewed views through Martin or an API.

### Phase 4 — Synchronization choice

- Compare QFieldCloud, Mergin Maps CE, Syncthing, and a small custom API.
- Choose only after the data model and actual mobile workflow are stable.

## What changed in the implemented system

The current project advanced beyond this plan: PostGIS is already the personal source of truth; FastAPI owns writes; Martin publishes approved views; PMTiles and OSM Carto provide local maps; Nominatim, Valhalla, terrain, Kiwix, resource lifecycle management, backups, and disconnected recovery are operational. A dedicated mobile synchronization client remains future work.

## Historical references

- [QFieldCloud self-hosting](https://docs.qfield.org/fi/reference/qfieldcloud/self_hosted/)
- [Mergin Maps server](https://merginmaps.com/docs/server/)
- [OsmAnd import/export](https://osmand.net/docs/user/personal/import-export/)
- [Martin](https://martin.maplibre.org/)
