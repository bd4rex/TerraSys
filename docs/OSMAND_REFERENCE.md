# OsmAnd resource-management reference

> English | [简体中文](OSMAND_REFERENCE.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## License boundary

OsmAnd is open source and its primary repositories are covered by GPLv3. Its repository license separately states that UI design and UX work, including layouts and icons, are covered by CC BY-NC-ND 4.0 and that publishing applications using OsmAnd UI/UX code in major app stores requires written permission.

References:

- https://github.com/osmandapp/OsmAnd
- https://github.com/osmandapp/OsmAnd/blob/master/LICENSE
- https://www.osmand.net/docs/user/personal/maps-resources/

TerraSys may study OsmAnd's information architecture, workflows, and operational lessons. It must not copy OsmAnd layouts, UI code, or protected visual assets. TerraSys uses its own desktop layout, Lucide icons, terminology, and implementation.

## Patterns adopted in TerraSys

- Separate Available, Local, and Updates responsibilities.
- Organize downloadable maps by world, continent, country, and independent region.
- Keep an always-available low-zoom world overview, then offer online viewing or a concrete offline region package when the user explores beyond installed coverage.
- Show device storage and application-managed storage separately.
- Keep task cancellation and retry attached to the affected resource.
- Show current stage, queue position, elapsed time, and trustworthy throughput.
- Display cached inventory immediately and refresh it in the background.
- Acquire maintenance state and resource inventory independently so one slow scan cannot hide active jobs.
- Sort installed resources by size within their categories.
- Distinguish complete maps, terrain, weather, nautical data, knowledge, styles, fonts, voice, cache, personal data, and settings.
- Keep installed files when a map is deactivated, while excluding that pack from rendering and the next shared-index rebuild.
- Provide multi-select verification, update, activation, and protected removal.
- Provide per-map information, verification, manifest export, activate/deactivate, rebuild, locate, and remove actions.
- Account for terrain tiles, build temporary data, and inventory cache separately and clear only allowlisted regenerable caches.
- Recommend independent replacement packs when a legacy combined package is found.
- Show source timestamp, local build timestamp, last check, and next check through one lifecycle model.
- Keep full-snapshot rebuilding as the disaster-recovery baseline while incremental OSM updates remain a separately documented research path.

## Implemented behavior and limits

The low-zoom Natural Earth overview is local and remains available without a network. Selecting or locating an uninstalled catalog region on the world map opens a coverage prompt with two explicit choices: temporarily view the current viewport through the configured online source, or open that exact region package for offline construction. Online browsing never changes ownership state and never pretends that an area is installed.

Every visible resource family now declares a delivery type and, where applicable, an installable maintenance resource ID. A missing weather, nautical, overview, encyclopedia, or travel resource exposes an actual install action. Layer controls are enabled only after the corresponding product is installed. Libraries, styles, caches, and map layers are labelled as different things instead of sharing a misleading download action.

Map-package updates refresh the provider state and source snapshot before rebuilding. Province packages sharing the China snapshot first compare the remote replication sequence; one newly downloaded and validated snapshot is reused by following province jobs. After a successful build the manifest sequence matches the trusted state, so the update leaves the update list. The API rejects a repeated update when the installed manifest is already current; **Rebuild** remains available as a separate action.

TerraSys deliberately does not duplicate OsmAnd's mobile navigation client, proprietary service entitlements, or worldwide contour/terrain distribution. Search and routing are shared derived indexes and must be rebuilt after coverage changes. Terrain is offered only where owned HGT files actually cover the package. The online OpenStreetMap Standard source is an opt-in current-viewport reference, not an offline tile-download service.

## Patterns not copied directly

- Mobile bottom sheets, long-press-only actions, and app-store purchase states do not fit this desktop-first local system.
- OsmAnd's proprietary service entitlements and server download limits are not part of TerraSys.
- UI assets and layouts covered by OsmAnd's separate CC BY-NC-ND terms are not reused.
- TerraSys keeps desktop-specific operational evidence: source checksums, build logs, PostGIS readiness, container health, and offline recovery-kit verification.
