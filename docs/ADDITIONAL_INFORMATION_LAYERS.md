# Additional Information Layer Module

> English | [简体中文](ADDITIONAL_INFORMATION_LAYERS.zh-CN.md) · Updated 2026-08-10

Additional information layers are a plug-in boundary separate from base maps, personal data, and offline resource packs. The module owns short-lived provider differences, caching, refresh policy, attribution, and map styling so changing third-party APIs do not spread through the main map application.

## Boundaries

- `services/api/app/live_layers.py`: fixed upstream adapters, common GeoJSON normalization, TTL cache, viewport cropping, graceful degradation, and the open AIS TCP receiver/NMEA decoder.
- `services/api/app/main.py`: `/live/*` routes only validate bounded parameters and invoke the module.
- `web/src/live-layers.js`: catalog, MapLibre sources/layers, visibility, refresh scheduling, popups, and legend entries.
- `web/src/app.js`: creates one module instance, controls the popover, remounts after style reload, and reports map movement.
- `web/information-layers.html`: a standalone console, parallel to map-resource management, for enablement, refresh cadence, connection tests, runtime health, coverage, and license review. Keyed candidates remain a read-only comparison catalog.
- The former contour shortcut now opens this module; contours remain available in the ordinary layer panel.

## Adapter contract

Every adapter returns a GeoJSON `FeatureCollection`. Collection metadata includes `source`, `status`, `fetchedAt`, and `count`. Every feature includes `kind`, `title`, `subtitle`, `observedAt`, `sourceLabel`, `sourceUrl`, `license`, and `detail`. A provider failure returns an empty collection with `status: unavailable` rather than failing the main map.

## Current no-key catalog

| Endpoint | Layer | Cache/refresh baseline |
| --- | --- | --- |
| `/live/earthquakes` | USGS seven-day earthquakes | 60 seconds |
| `/live/wildfires` | NASA EONET wildfire events | 10 minutes |
| `/live/disasters` | GDACS flood/volcano/drought/wildfire notices | 5 minutes |
| `/live/air-quality` | Open-Meteo/CAMS viewport samples | 15 minutes |
| `/live/floods` | Open-Meteo/GloFAS discharge samples | 6 hours |
| `/live/aircraft` | ADSB.lol aircraft | 5–8 seconds |
| `/live/vessels` | Norwegian Coastal Administration open AIS | continuous receiver; 8-second browser refresh |
| `/live/ocean-buoys` | NOAA NDBC latest observations | 10 minutes |
| `/live/cyclones` | GDACS tropical cyclones | 5 minutes |

`/live/catalog` exposes the machine-readable directory with `keyPolicy: no-key-only`. `/live/status` reports recent in-process checks, while `PUT /live/settings/{layer_id}` persists only `enabled` and `refreshSeconds`. Settings default to `/data/maintenance/live-layer-settings.json` and can be relocated with `LIVE_LAYER_SETTINGS_PATH`.

## Standalone management console

- The map popover remains the quick-toggle surface and links to `/information-layers.html` for management.
- Enablement and refresh cadence are loaded when the map starts. Disabling a source does not remove its adapter or metadata.
- Per-source tests use bounded representative viewports and report object count, latency, and recent failure without changing the map viewport.
- Test-all runs at most three providers concurrently.
- Keyed candidates show authentication and published call limits but are never invoked and no credentials are collected.

## AIS configuration

The default no-registration stream is `153.44.253.27:5631`. The same receiver can point at user-owned AIS hardware with `AIS_TCP_ENABLED`, `AIS_TCP_HOST`, and `AIS_TCP_PORT`. `LIVE_LAYER_SETTINGS_PATH` controls the management-setting file. Positions expire after 15 minutes. Coverage and public-disclosure limits are those of the Norwegian open AIS service.

## Adding an adapter

1. Add a fixed-URL, cached adapter in `live_layers.py` and normalize the common fields.
2. Declare provenance, time, license, coverage, latency, and safety limits.
3. Add a bounded API route and catalog entry.
4. Add one `LIVE_LAYER_DEFINITIONS` entry and its style in `pointLayer()`; keep provider details out of `app.js`.
5. Add unit tests, a stable UI fixture, and source/license documentation.
6. For credentials, read server-side environment variables only and implement 429 backoff. Update the [keyed-source decision catalog](KEYED_DATA_SOURCES.md) and obtain a decision before enabling it.

All layers default off. Air quality and discharge use a 3×3 model sample, ADS-B is limited to a 250-nautical-mile query radius, and disaster/aviation/maritime overlays are situational references rather than safety systems.
