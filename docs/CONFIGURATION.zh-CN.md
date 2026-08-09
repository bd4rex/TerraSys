# 配置

> [English](CONFIGURATION.md) | 简体中文 · 快照 `2026-08-03T23:12:23+08:00`

## 宿主机入口

| 地址 | 用途 |
| --- | --- |
| `http://localhost:8080/` | 地图应用 |
| `http://localhost:8080/resources.html` | 资源与版本管理 |
| `http://localhost:8080/api/health` | API 与个人 PostGIS 健康状态 |
| `http://localhost:8080/martin/catalog` | Martin 发布目录 |
| `http://localhost:8080/tiles/<pack>.pmtiles` | 支持 HTTP Range 的区域地图 |
| `http://localhost:8080/wiki/` | 本地中文知识库 |

PostGIS `5432`、Martin `3000`、FastAPI `8000`、Nominatim `8080`、Valhalla `8002`、Kiwix `8080` 和 OSM Carto `80` 都只在容器网络内部使用。

## 本地密钥

`services/.env` 至少包含：

```dotenv
POSTGRES_PASSWORD=<long-random-local-password>
NOMINATIM_PASSWORD=<independent-long-random-local-password>
NOMINATIM_VOLUME_NAME=services_terrasys_nominatim_data
VALHALLA_DATA_PATH=../products/routing/valhalla
```

该文件被 Git 忽略。缺失时，`scripts/start-terrasys.ps1` 会创建 32 字节随机密码，并同步已有 `gis` 数据库角色密码。

## Compose 服务

| 服务 | 持久数据 | 宿主机暴露 |
| --- | --- | --- |
| `postgis` | `terrasys_postgis_data` | 无 |
| `api` | 个人媒体、导出、缓存与维护状态 | 无 |
| `martin` | 只读批准的 PostGIS 视图 | 无 |
| `nominatim` | 活动命名卷及候选版本 | 无 |
| `valhalla` | 活动路线版本目录 | 无 |
| `kiwix` | 只读百科与旅行 ZIM | 无 |
| `osm-carto` | 外部数据库卷与宿主机瓦片缓存 | 无 |
| `web` | 只读网页与 PMTiles | `127.0.0.1:8080` |

所有第三方运行镜像固定 digest；API 镜像从固定版本的 `requirements.txt` 构建。正常启动不应持久设置 `VALHALLA_FORCE_REBUILD` 或 `VALHALLA_IGNORE_PBF` 的重建覆盖值。

## nginx 路由

| 路由 | 目标 |
| --- | --- |
| `/`、`/assets/`、`/vendor/`、`/src/` | 本地网页资源 |
| `/tiles/` | PMTiles，支持字节范围 |
| `/api/` | FastAPI |
| `/martin/` | Martin |
| `/wiki/` | Kiwix |
| `/carto/` | OSM Carto 本地瓦片代理 |
| `/healthz` | nginx 存活检查 |

PMTiles 必须返回 `206 Partial Content`。健康脚本会验证 Range 响应，而不只检查 HTTP 200。

## 地图目录

- `region-catalog.json`：中国 34 个省级单元、六个展示分组、来源配置、边界和构建估算。
- `world-region-catalog.json`：从 Geofabrik 索引生成的全球层级和 550 多个真实下载单元。
- `map-catalog.json`：渲染限制和初始回退区域。
- `resource-catalog.json`：地图、来源、路线、地形、知识、样式、备份和缓存分类。

一个区域只有在 PMTiles 和清单同时存在并通过约束时才算独立安装。`POST /api/map-packs/{id}/verify` 返回 `202 Accepted` 并把大型 SHA256 检查排入后台任务。

## 资源盘点

`GET /api/resources?cached=true` 返回上次完整快照。普通 `GET /api/resources` 立即返回该快照并启动单个后台刷新；`?check_upstream=true` 同时检查可信上游状态。新结果原子替换旧缓存，维护任务不会删除最后一份可读盘点。

盘点覆盖地图、OSM 来源、路线、海拔、知识库、网页资源、OSM Carto、备份、PostGIS、媒体和可再生缓存。Docker 命名卷容量与宿主机路径容量分开显示。

## 宿主机存储

- 活动项目：`D:\TerraSys`
- 兼容 Junction：`C:\Users\Administrator\Documents\TerraSys`
- Docker Desktop WSL：`D:\DockerData\wsl`

Docker 设置使用：

```json
"CustomWslDistroDir": "D:\\DockerData\\wsl"
```

迁移 Docker 数据时，必须在目标位置验证容器、镜像、卷、API 计数和备份，并确认目标 VHD 持续写入后，才能删除旧 VHD。产品与运行时标识统一为 `TerraSys`；原位升级时，`services/.env` 可以继续指向已经校验的旧物理 Docker 卷，这些卷指针只是数据位置兼容设置。

## 样式与本地资源

- `web/src/map-style.js`：PMTiles 图层及样式；
- `web/assets/glyphs/`：本地 Noto Sans 字形；
- `web/assets/sprites/`：本地图标图集；
- `web/vendor/`：固定版本的 MapLibre、PMTiles 与 Lucide；
- `config/osm-carto/`：OSM Carto 外部数据配置；
- `config/planetiler/`：区域高细节叠加构建配置。

下载脚本先写暂存文件，检查基本大小或哈希后再安装，并写入本地来源清单。

## Martin 白名单

`services/martin/config.yaml` 只发布：

- `app.places_web`
- `app.tracks_web`

新增空间数据必须通过经过审查的视图暴露，不应启用所有数据库表的自动发布。

## API 范围

API 提供个人点位、集合、轨迹、GPX、媒体、导出、搜索、附近参考、地图包、资源盘点、维护任务、状态、能力、地址、反向地址、路线、海拔、地形、应急、天气、航海和百科适配器。

所有坐标使用 WGS84 经度/纬度（`EPSG:4326`）；空间索引使用 PostGIS GiST。
