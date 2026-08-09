# TerraSys 江苏 / 安徽本地地图 MVP

> [English](mvp-d-terrasys.md) | 简体中文 · 快照 `2026-08-03T23:12:23+08:00`

## 目标

这套 MVP 不是地图演示，而是个人拥有的离线地理系统：

- 本地渲染并独立版本管理的 OSM 参考地图；
- 个人点位、轨迹、照片、集合、标签、评分和备注；
- GPX 导入导出与可移植 GeoJSON/ZIP；
- PostGIS 空间索引、乐观版本和变更历史；
- 带校验的备份、恢复与完全断网恢复；
- 本地地址、反向地址、路线、海拔、地形、应急和中文知识。

## 入口

```text
http://localhost:8080/
```

`/api/health` 或 `/martin/catalog` 返回 JSON 是正常现象，它们是机器 API。

## 数据层

| 层 | 当前实现 | 所有权 |
| --- | --- | --- |
| 熟悉参考地图 | OSM → osm2pgsql/PostGIS → OSM Carto/Mapnik | 派生、可重建 |
| 交互矢量地图 | OSM → Planetiler → 江苏/安徽独立 PMTiles | 派生、可移植、可点击 |
| 个人数据 | FastAPI → PostGIS；SHA256 媒体 | 持久权威数据 |
| 浏览器 | MapLibre、本地样式、字体与 sprites | 可替换客户端 |
| 高级参考 | Nominatim、Valhalla、HGT、Kiwix | 稳定 API 后可替换 |

## 当前范围

- 江苏、安徽独立校验 PMTiles，构建至 z16 并同时渲染。
- 默认使用本地 OSM Carto，PMTiles 作为交互矢量备选。
- 道路、建筑、水系、用地、边界、地名、POI、地形、天气、航海和应急图层。
- 个人点位/轨迹/媒体生命周期、集合、搜索、统计、备份和导出。
- 完整地址、反查、驾车/骑行/步行路线、路线海拔、等高线和本地知识。
- 健康、API 生命周期、资源页面、主界面和全球地图浏览器测试。

## 运行维护

```powershell
D:\TerraSys\start-terrasys.cmd
D:\TerraSys\health-check.cmd
D:\TerraSys\smoke-test.cmd
D:\TerraSys\backup-terrasys.cmd
```

宿主机只开放 `127.0.0.1:8080`。权威说明见 [README](../README.zh-CN.md)、[架构](ARCHITECTURE.zh-CN.md)、[运维](OPERATIONS.zh-CN.md)和[重建](REBUILD.zh-CN.md)。
