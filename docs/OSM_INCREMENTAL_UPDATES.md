# OSM Incremental Updates and Full-Snapshot Baseline

> English | [简体中文](OSM_INCREMENTAL_UPDATES.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## Current policy

Production updates continue to rebuild from complete snapshots. Incremental replication is restricted to an isolated experiment and must not overwrite production PBF, PMTiles, Nominatim, Valhalla, or OSM Carto data.

Every recoverable publication retains:

- the last verified full OSM PBF and SHA256;
- replication sequence, source timestamp, provider, and package manifests;
- PMTiles and shared-index rollback points built from that snapshot;
- every experimental OSC diff, sequence, and SHA256.

Run the read-only readiness plan:

```powershell
D:\TerraSys\plan-osm-incremental-updates.cmd
D:\TerraSys\plan-osm-incremental-updates.cmd -Json
```

## Experimental pipeline

1. Copy a verified full snapshot to a staging PBF; never update the active file in place.
2. Lock the starting sequence from source state and download continuously through a published target sequence.
3. Retain each OSC file and SHA256. Never guess unpublished future sequence numbers.
4. Apply diffs oldest-to-newest with `osmium apply-changes`.
5. Run `osmium fileinfo`, `osmium check-refs`, boundary, and object-count checks.
6. Rebuild one province PMTiles package first and compare manifests, sampled tiles, and landmarks.
7. Only then rebuild shared search, routing, and any renderer candidate; publish atomically and retain the previous generation.

References: [Osmium apply-changes](https://docs.osmcode.org/osmium/latest/osmium-apply-changes.html), [Pyosmium replication tools](https://docs.osmcode.org/pyosmium/v4.3.0/user_manual/10-Replication-Tools/), and [OpenStreetMap planet diffs](https://wiki.openstreetmap.org/wiki/Planet.osm/diffs).

## Disaster-recovery rules

- Abandon a run when any sequence is missing, a hash differs, references fail, or sampled map output regresses.
- Do not make incremental replication the only path until it has run for one month and has matched at least one contemporary full snapshot.
- Even after stabilization, verify a complete snapshot at least quarterly.
- Search and routing indexes are derived products; the full OSM snapshot, replication state, and personal backup are the recovery roots.

## Planned stages

1. Jiangsu-only offline staging that produces reports but no activation.
2. Continuous Jiangsu/Anhui diffs compared with full-snapshot objects and sampled tiles.
3. Separate evaluation of native Nominatim/Valhalla updates versus full candidate rebuilds.
4. Scheduled execution only after rollback, audit, and periodic full-baseline requirements are met.
