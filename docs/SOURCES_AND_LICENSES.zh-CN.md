# 来源与许可

> [English](SOURCES_AND_LICENSES.md) | 简体中文 · 快照 `2026-08-17T00:26:42+08:00`

本项目组合开放数据与开源软件。重新分发地图包或浏览器资源前，应保留署名并重新核对上游许可和服务条款。

## OpenStreetMap 数据

来源：

- `https://download.openstreetmap.fr/extracts/asia/china/`
- `https://download.openstreetmap.fr/polygons/asia/china/`
- `https://download.geofabrik.de/asia/taiwan.html`
- `https://download.geofabrik.de/index-v1.json`
- `https://tiles.osm.kr/download/`（朝鲜/韩国非军事要素提取文件）

大陆省级地图从同一份中国快照和省级边界派生。中国提供方可能省略跨越国家提取范围外边界的引用；TerraSys 会完整扫描 PBF，只接受该来源明确设置的有上限缺口，随后省级提取仍执行更严格的引用检查。台湾使用独立校验的 Geofabrik PBF 与边界。朝鲜/韩国包使用 OpenStreetMap Korea 的公开非军事要素提取文件；由于下载目录不提供旁路校验和或复制序列，TerraSys 会完整扫描 PBF 并在本地清单记录 SHA256。OpenStreetMap 数据使用 ODbL，浏览器必须显示 OpenStreetMap contributors 署名。

版权与许可：`https://www.openstreetmap.org/copyright`

### 可选 OpenStreetMap Standard 在线参考

用户可明确选择 `https://tile.openstreetmap.org/{z}/{x}/{y}.png` 临时浏览当前视口。应用显示署名、发送正常来源信息，并允许普通 HTTP 缓存；不会预取、抓取、批量下载或把公共瓦片服务转换成离线包。离线所有权通过提供方 PBF 与本地构建实现。

瓦片使用策略：`https://operations.osmfoundation.org/policies/tiles/`

## Planetiler

项目：`https://github.com/onthegomap/planetiler`

把区域 OSM PBF 转换成 OpenMapTiles 兼容 PMTiles。构建镜像在 `scripts/build-region-pack.ps1` 中固定 digest。

## OpenMapTiles schema

项目：`https://github.com/openmaptiles/openmaptiles`

本地矢量样式使用的图层结构，浏览器署名中包含 OpenMapTiles。

## MapLibre GL JS

项目：`https://github.com/maplibre/maplibre-gl-js`

本地版本：`5.6.0`。作用：浏览器矢量地图渲染。

## PMTiles

项目：`https://github.com/protomaps/PMTiles`

本地浏览器库版本：`4.3.0`。作用：单文件瓦片归档和浏览器 Range 协议。

## MapLibre Contour

项目：`https://github.com/onthegomap/maplibre-contour`

本地版本：`0.1.0`（BSD 3-Clause）。它从本地 Terrarium DEM 生成等高线和标签，不访问外部地形服务。

## OpenFreeMap 样式与在线参考

项目：`https://github.com/hyperknot/openfreemap-styles`

本地 sprite 用于 POI，Liberty JSON 作为样式参考。用户明确选择 OpenFreeMap 时，浏览器可以请求当前视口公共矢量瓦片；它们不是已安装地图，也不会批量离线缓存。重新分发或非个人部署前应核对最新署名和服务条款。

## OpenStreetMap Carto、osm2pgsql、Mapnik 与 mod_tile

- Carto：`https://github.com/gravitystorm/openstreetmap-carto`
- 瓦片服务镜像：`https://github.com/Overv/openstreetmap-tile-server`
- osm2pgsql：`https://github.com/openstreetmap/osm2pgsql`
- Mapnik：`https://github.com/mapnik/mapnik`
- mod_tile：`https://github.com/openstreetmap/mod_tile`

它们把当前江苏/安徽 OSM 导入独立数据库并渲染熟悉的本地栅格地图。运行镜像在 Compose 中固定 digest。外部数据来源记录在 `config/osm-carto` 和 `products/osm-carto`；分发输出时仍要满足 OSM 署名及相关软件/数据许可。

## Nominatim

- 项目：`https://nominatim.org/`
- 容器：`https://github.com/mediagis/nominatim-docker`

从共享 PBF 提供完整本地地址与反向地址。镜像固定 digest；其底层 OSM 数据仍适用 ODbL。

## Valhalla 与海拔

项目：`https://github.com/valhalla/valhalla`

从共享 OSM PBF 构建驾车、骑行和步行图。HGT/SRTM 兼容文件独立保存在 `products/elevation`，用于路线海拔与地形。

区域 HGT 格网来自 [AWS 开放数据 Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) 的 Mapzen Skadi 全球目录。系统按已安装地图区域下载并长期保留，避免一次性占满磁盘。向个人用途之外分发恢复包前要保留来源并核对数据条款。

## Natural Earth

来源：`https://www.naturalearthdata.com/`

用于旧版低缩放栅格以及 z0-7 多级矢量 PMTiles。矢量构建按缩放切换 110m、50m、10m 的陆地、水体、国界/省界、城市、主要道路、铁路、河流、城市建成区、冰川和保护地。Natural Earth 是公共领域，安装文件与校验记录在 `web/assets/overview/overview.manifest.json`。

## Open-Meteo

来源：`https://open-meteo.com/`

提供江苏/安徽城市集合的七天天气快照，以及按当前视口抽样的空气质量（CAMS）和河流流量（GloFAS）参考。按 CC BY 4.0/Copernicus 相关条款署名；个人非商业运行使用 Open-Meteo 免费 API。天气快照来源与校验位于 `products/weather/weather.manifest.json`。

## 无密钥附加信息图层

附加信息图层只在用户开启后按当前视口请求，并由后端做 TTL 缓存与裁剪。当前运行目录不包含任何 API 密钥：

- [USGS Earthquake GeoJSON](https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php)：近 7 日地震；美国政府公共领域数据。
- [NASA EONET](https://eonet.gsfc.nasa.gov/docs/v3)：开放山火事件；保留 EONET 与原事件源链接。它不是 FIRMS 逐像元火点。
- [GDACS API](https://www.gdacs.org/gdacsapi/)：洪水、火山、干旱、山火与热带气旋通报；保留 GDACS 署名和原报告链接，不能替代当地正式预警。
- [ADSB.lol](https://www.adsb.lol/)：众包 ADS-B 飞机位置，数据按 ODbL 署名；覆盖不完整，不用于航空安全决策。
- [Norwegian Coastal Administration open AIS](https://www.kystverket.no/en/sea-transport-and-ports/ais/access-to-ais-data/)：挪威区域 AIS TCP 流，按 NLOD 署名并受船型/尺寸与地理公开范围限制；不用于航行安全决策。
- [NOAA NDBC](https://www.ndbc.noaa.gov/)：海洋浮标与沿岸站最新观测；美国政府公共数据。

需要账号或密钥、尚未接入的候选源及官方调用限制见 [需要密钥的数据源决策目录](KEYED_DATA_SOURCES.zh-CN.md)。

## Kiwix、Wikipedia 与 Wikivoyage

- Kiwix：`https://github.com/kiwix/kiwix-tools`
- Wikipedia ZIM：`https://download.kiwix.org/zim/wikipedia/`
- Wikivoyage ZIM：`https://download.kiwix.org/zim/wikivoyage/`

安装快照：

- `wikipedia_zh_all_mini_2026-05.zim`
- `wikivoyage_zh_all_maxi_2026-06.zim`

清单记录 URL、字节、快照和 SHA256。Kiwix 软件与 ZIM 内容各自有许可；维基百科文本通常使用 CC BY-SA，媒体可能另有许可。分发时必须保留文章署名与许可通知。

## 字形与 Noto Sans

字形来源：`https://github.com/maplibre/demotiles`

本地包含 Noto Sans Regular、Bold、Italic PBF 范围。字体许可保存在 `web/assets/glyphs/SIL Open Font License FOR MapLibre Noto Sans.txt`。

## Lucide

项目：`https://github.com/lucide-icons/lucide`

本地版本：`0.468.0`。作用：界面图标。

## PostGIS、Martin、nginx、Python 与 Playwright

- PostGIS：`https://postgis.net/`
- Martin：`https://github.com/maplibre/martin`
- nginx：`https://nginx.org/`
- Python：`https://www.python.org/`
- Playwright：`https://playwright.dev/`

运行和构建镜像 digest 位于 Compose/Dockerfile，Python 精确版本位于 `services/api/requirements.txt`。

## 资源完整性记录

`scripts/download-web-assets.ps1` 把每个下载浏览器资源的相对路径、字节和 SHA256 写入 `runtime/web-assets-manifest.json`。离线发布包应保留该清单。
