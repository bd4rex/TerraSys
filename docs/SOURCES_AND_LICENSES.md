# Sources and Licenses

> English | [简体中文](SOURCES_AND_LICENSES.zh-CN.md) · Snapshot `2026-08-17T00:26:42+08:00`

This project combines open data and open-source software. Keep attribution visible and review upstream licenses before redistributing a data pack or bundled browser assets.

## OpenStreetMap data

Source mirror:

- `https://download.openstreetmap.fr/extracts/asia/china/`
- `https://download.openstreetmap.fr/polygons/asia/china/`
- `https://download.geofabrik.de/asia/taiwan.html`
- `https://download.geofabrik.de/index-v1.json` (global region catalog)
- `https://tiles.osm.kr/download/` (North/South Korea non-military extracts)

The mainland province maps are derived from one China snapshot and 33 province-level polygon boundaries. The China provider can omit references crossing its outer country-extract boundary; TerraSys performs a complete PBF scan and accepts only a source-specific bounded count before the stricter province extraction checks run. Taiwan uses a separately checksummed Geofabrik OSM PBF and polygon. The North/South Korea packs use OpenStreetMap Korea's public non-military extracts; TerraSys performs a complete PBF validation and records a local SHA256 because that download directory does not publish a sidecar checksum or replication state. OpenStreetMap data is available under the Open Database License (ODbL). The browser visibly credits OpenStreetMap contributors.

Project and license information: `https://www.openstreetmap.org/copyright`

### Optional OpenStreetMap Standard online view

The browser can opt into `https://tile.openstreetmap.org/{z}/{x}/{y}.png` for temporary current-viewport reference browsing. It displays OpenStreetMap attribution, sends a normal origin referrer, and allows ordinary HTTP caching. The application does not prefetch, scrape, bulk-download, or turn this public service into offline packages. Offline ownership is implemented through provider PBF downloads and locally built PMTiles instead.

Tile usage policy: `https://operations.osmfoundation.org/policies/tiles/`

## Planetiler

Project: `https://github.com/onthegomap/planetiler`

Role: converts the merged regional OSM PBF into an OpenMapTiles-compatible PMTiles archive.

The build image is pinned in `scripts/build-region-pack.ps1` by SHA256 digest.

## OpenMapTiles schema

Project: `https://github.com/openmaptiles/openmaptiles`

Role: vector-layer schema consumed by the local map style. The browser attribution includes OpenMapTiles.

## MapLibre GL JS

Project: `https://github.com/maplibre/maplibre-gl-js`

Local version: `5.6.0`.

Role: browser vector-map renderer.

## PMTiles

Project: `https://github.com/protomaps/PMTiles`

Local browser library version: `4.3.0`.

Role: single-file vector-tile archive and browser range protocol.

## MapLibre Contour

Project: `https://github.com/onthegomap/maplibre-contour`

Local version: `0.1.0` (BSD 3-Clause).

Role: reads the locally served Terrarium DEM, smooths neighboring elevation tiles, and generates crisp vector contour lines and labels in a browser worker. The runtime makes no external terrain request.

## OpenFreeMap style assets

Project: `https://github.com/hyperknot/openfreemap-styles`

Role: the local sprite sheet is used for POI symbols and the downloaded Liberty JSON is retained as a style reference. When the user explicitly selects OpenFreeMap, the browser may request its public vector tiles for the current viewport; those requests are temporary online references and are never treated as installed packages or bulk-cached offline data. Review the service's current attribution and usage terms before redistribution or non-personal deployment.

## OpenStreetMap Carto, osm2pgsql, Mapnik, and mod_tile

- Cartography: `https://github.com/gravitystorm/openstreetmap-carto`
- Tile-server image: `https://github.com/Overv/openstreetmap-tile-server`
- osm2pgsql: `https://github.com/openstreetmap/osm2pgsql`
- Mapnik: `https://github.com/mapnik/mapnik`
- mod_tile: `https://github.com/openstreetmap/mod_tile`

Role: imports the current Jiangsu/Anhui OSM source into a dedicated database and renders the familiar local raster map. The runtime image is pinned by digest in `services/docker-compose.yml`. External-data provenance is recorded under `config/osm-carto` and `products/osm-carto`; OSM attribution and the applicable software/data licenses remain required when redistributing output.

## Nominatim

Project: `https://nominatim.org/`

Container project: `https://github.com/mediagis/nominatim-docker`

Role: imports `terrasys-core-latest.osm.pbf` for full local address search and reverse geocoding. The runtime image is pinned by digest. Nominatim is an index over OSM data; ODbL attribution and redistribution obligations still apply to the underlying database.

## Valhalla and elevation

Project: `https://github.com/valhalla/valhalla`

Role: builds and serves local driving, cycling, and walking graph tiles from the shared OSM PBF. The scripted image is pinned by digest. HGT/SRTM-compatible tiles are retained independently under `products/elevation` and used for route elevation and terrain rendering.

Regional HGT grids are synchronized from the [AWS Open Data Terrain Tiles registry](https://registry.opendata.aws/terrain-tiles/) using the Mapzen Skadi layout. The source is global, while this installation downloads and retains the bounds of installed map regions so storage grows deliberately. Preserve source provenance and review the dataset terms before redistributing a kit outside personal use.

## Natural Earth

Source: `https://www.naturalearthdata.com/`

Role: the legacy low-zoom raster plus the zoom 0-7 multiscale vector PMTiles. The vector build switches between 110m, 50m, and 10m land, water, country/state boundaries, populated places, major roads, railways, rivers, urban areas, ice, and protected areas. Natural Earth data is public domain; the installed files and checksums are recorded in `web/assets/overview/overview.manifest.json`.

## Open-Meteo

Source: `https://open-meteo.com/`

Role: refreshable seven-day snapshots for the current Jiangsu/Anhui city set, plus viewport-sampled CAMS air-quality and GloFAS river-discharge references. Open-Meteo/Copernicus attribution and the applicable CC BY terms are retained; the free API is used for this personal non-commercial installation. Weather snapshots are stored with source URLs and checksums in `products/weather/weather.manifest.json`.

## Keyless additional information layers

Additional overlays are requested only after the user enables them, cropped to the current viewport, and cached by the API. No API key is present in the runtime catalog:

- [USGS Earthquake GeoJSON](https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php): seven-day earthquake catalog; US public-domain data.
- [NASA EONET](https://eonet.gsfc.nasa.gov/docs/v3): curated open wildfire events with EONET and upstream event links. This is not a pixel-level FIRMS hotspot feed.
- [GDACS API](https://www.gdacs.org/gdacsapi/): flood, volcano, drought, wildfire, and tropical-cyclone notices with GDACS attribution and report links; not a replacement for local official alerts.
- [ADSB.lol](https://www.adsb.lol/): crowdsourced ADS-B aircraft positions under ODbL; incomplete coverage and not for aviation safety decisions.
- [Norwegian Coastal Administration open AIS](https://www.kystverket.no/en/sea-transport-and-ports/ais/access-to-ais-data/): Norway-region TCP AIS under NLOD and subject to geographic/vessel disclosure limits; not for navigation decisions.
- [NOAA NDBC](https://www.ndbc.noaa.gov/): latest ocean buoy and coastal-station observations; US public data.

## Kiwix, Wikipedia, and Wikivoyage ZIM

Kiwix tools: `https://github.com/kiwix/kiwix-tools`

Official ZIM catalog: `https://download.kiwix.org/zim/wikipedia/`
Travel ZIM catalog: `https://download.kiwix.org/zim/wikivoyage/`

Installed snapshot: `wikipedia_zh_all_mini_2026-05.zim`.
Installed travel snapshot: `wikivoyage_zh_all_maxi_2026-06.zim`.

Role: serves the local Chinese Wikipedia encyclopedia. `products/encyclopedia/encyclopedia.manifest.json` records the exact download URL, bytes, snapshot, and SHA256. Kiwix software and the ZIM's included content have their own licenses; Wikipedia article text is generally available under Creative Commons Attribution-ShareAlike and may also include separately licensed media. Preserve article attribution and license notices when redistributing content.

## Glyphs and Noto Sans

Glyph source: `https://github.com/maplibre/demotiles`

The local cache contains Noto Sans Regular, Bold, and Italic glyph PBF ranges. `web/assets/glyphs/SIL Open Font License FOR MapLibre Noto Sans.txt` records the font license.

## Lucide

Project: `https://github.com/lucide-icons/lucide`

Local version: `0.468.0`.

Role: interface icons.

## PostGIS, Martin, nginx, Python, and Playwright

- PostGIS: `https://postgis.net/`
- Martin: `https://github.com/maplibre/martin`
- nginx: `https://nginx.org/`
- Python: `https://www.python.org/`
- Playwright: `https://playwright.dev/`

Runtime/build image digests are recorded in `services/docker-compose.yml` and Dockerfiles. Python package versions are exact in `services/api/requirements.txt`.

## Asset integrity record

`scripts/download-web-assets.ps1` writes `runtime/web-assets-manifest.json` containing the relative path, byte count, and SHA256 for each locally downloaded browser asset. Preserve that manifest with an offline release bundle.
