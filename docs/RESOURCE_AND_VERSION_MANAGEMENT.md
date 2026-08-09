# Resource and Map Version Management

> English | [简体中文](RESOURCE_AND_VERSION_MANAGEMENT.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## Entry points

- Map: `http://localhost:8080/`
- Resources and versions: `http://localhost:8080/resources.html`

The map handles browsing, search, personal places, tracks, and routes. The resource console handles acquisition, installed products, version history, disk accounting, maintenance jobs, and update checks.

## Map-package state

Every region is managed by a stable `resourceId`. A complete installed package contains at least:

- `products/tiles/pmtiles/<id>.pmtiles`
- `products/tiles/pmtiles/<id>.manifest.json`

The manifest records source path, source sequence and timestamp, build time, product bytes, SHA256, boundaries, tool provenance, and optional rich-detail overlay metadata. The API considers a map installed only when the product and manifest form a valid pair.

Version views distinguish:

- **current:** the enabled PMTiles and manifest;
- **upstream:** the last trusted replication state;
- **rollback:** the most recent complete product/manifest pair distinct from current;
- **history:** small provenance records without duplicate large map files;
- **staging:** incomplete build products that never count as installed.

## Update invariants

Mainland province maps share one verified China OSM snapshot. A new snapshot is downloaded only when the trusted upstream sequence changes; queued province updates at the same sequence reuse the validated local file.

The activation order is:

1. download to a PBF staging path;
2. scan the full file with Osmium and compare the replication sequence;
3. atomically activate the shared source and retain the previous source;
4. extract one region and generate staged base/detail PMTiles products;
5. verify headers, metadata, byte counts, and hashes;
6. atomically activate the current map and manifest;
7. persist an explicit success or failure result.

An already-current update returns `409`. Regeneration from an unchanged source uses **Rebuild**, so a repeated build is not presented as a new upstream version.

## Task and map coordination

The resource page polls the lightweight maintenance snapshot rather than starting a disk scan. Each row owns its queue position or elapsed time, stage, measured throughput, cancellation action, and retry state. Unknown progress remains labelled as processing instead of displaying a fabricated percentage.

Map changes notify other open tabs through the local `terrasys-resource-revision` value. Tabs refresh package state without forcibly reloading a PMTiles source while the user is editing a place or route.

Shared Nominatim and Valhalla indexes use a blue-green lifecycle. Candidate versions are resource-limited and built sequentially. Validation points are derived from the enabled coverage instead of hard-coded countries. Candidates must pass route health, Nominatim database integrity, search/reverse checks, and API readiness before activity pointers are changed. A failed or cancelled job leaves the active version intact; one previous version is retained by default.

Heavy shared-index jobs are never automatically retried after failure or worker restart.

## Enable, rollback, and remove

- **Disable** retains the map and source but removes the package from rendering and target shared-index scope.
- **Enable** adds a verified package back to rendering and may mark shared indexes stale.
- **Rollback** atomically swaps current and previous complete products, making the former current version the new rollback target.
- **Protected remove** requires the resource ID as a confirmation token, deletes current/rollback derived maps, and retains regional PBF and boundary inputs for offline rebuilding.

## Storage classification

Inventory separates current maps, rollback maps, staging output, version manifests, shared OSM input, source rollback, routing/search indexes, OSM Carto, knowledge archives, backups, complete recovery kits, and renewable caches.

Each local resource has four stable fields:

- `resourceType`: what it is, such as `standard-map`, `osm-source`, or `routing-index`;
- `storageClass`: its role, such as `primary`, `rollback`, `staging`, or `cache`;
- `scope`: `regional`, `global`, `system`, or `personal`;
- `validationPolicy`: the conditions required before it is considered valid.

These definitions live in `RESOURCE_CLASSIFICATIONS` in `services/api/app/main.py`; UI label changes do not alter storage or validation semantics.

## Validity rules

File presence alone is insufficient:

- **Ready:** manifests, bytes, required hashes, and runtime services satisfy the policy.
- **Needs attention:** files exist, but dependencies are stale, a service is unavailable, or verification is incomplete.
- **External volume/system capability:** data lives in Docker or browser runtime and is not counted as an owned host-path file.
- **Not installed:** minimum completeness is absent.
- **Cache:** safe to remove and regenerate; not part of the disaster-recovery baseline.

Specific rules include:

- current and rollback maps require matching product/manifest pairs and byte counts; full SHA256 is asynchronous;
- OSM sources activate only after full Osmium structure and replication-state validation;
- HGT files require valid names and grid byte sizes;
- overview, weather, and nautical products require synchronized manifests, bytes, and hashes;
- Wikipedia and Wikivoyage are accounted separately and also require a healthy Kiwix service;
- Nominatim and Valhalla must be online and cover every enabled package; harmless extra coverage is usable but marked for cleanup;
- an offline kit is verified only after every manifest entry passes SHA256 and `verification.json` is bound to the current manifest hash;
- OSM Carto readiness requires provenance, a healthy database service, and a working local tile endpoint.

`verification.json` is intentionally outside its own manifest. Reverification removes the old credential first, so any interrupted verification returns the kit to an unverified state.
