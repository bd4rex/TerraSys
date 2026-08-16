# 附加信息图层模块

> [English](ADDITIONAL_INFORMATION_LAYERS.md) | 简体中文 · 更新于 2026-08-10

附加信息图层是独立于底图、个人数据和离线资源包的可插拔模块。它负责短时效公网数据的信源差异、缓存、刷新、许可和地图样式，避免把频繁变化的第三方接口散落在主地图代码中。

## 模块边界

- 后端适配器：`services/api/app/live_layers.py`
  - 每个上游源转换为统一 GeoJSON。
  - 固定上游地址，执行超时、TTL 缓存、视口裁剪和安全降级。
  - 管理无需注册的挪威 AIS TCP 长连接及最小 NMEA 解码器。
- API 挂载：`services/api/app/main.py` 的 `/live/*` 只做参数校验和调用独立服务。
- 前端挂载器：`web/src/live-layers.js`
  - 保存图层目录、MapLibre source/layer 样式、可见状态、刷新周期、弹窗和图例条目。
  - 主应用 `web/src/app.js` 只创建模块实例、控制弹出面板、在样式重载后重新挂载，并在地图移动后通知刷新。
- 独立管理页：`web/information-layers.html`
  - 仿照地图资源控制台，集中管理免密信源启停、刷新频率、连接测试、运行状态、覆盖范围与许可。
  - 需要密钥的候选源只显示认证方式和公开调用限制；页面不会收集、保存或调用密钥。
- 入口：原“等高线”快捷按钮已改为“附加信息图层”；等高线仍保留在普通图层面板。

## 统一 GeoJSON 契约

每个适配器必须返回 `FeatureCollection`，集合属性至少包含：

```json
{
  "type": "FeatureCollection",
  "features": [],
  "properties": {
    "source": "provider-id",
    "status": "ok",
    "fetchedAt": "2026-08-10T04:00:00Z",
    "count": 0
  }
}
```

每个地图对象至少包含 `kind`、`title`、`subtitle`、`observedAt`、`sourceLabel`、`sourceUrl`、`license` 和 `detail`。上游不可用时接口仍返回空集合，并把状态设为 `unavailable`，避免第三方故障拖垮主地图。

## 当前无密钥目录

| API | 图层 | 缓存/刷新基线 |
| --- | --- | --- |
| `/live/earthquakes` | USGS 近 7 日地震 | 60 秒 |
| `/live/wildfires` | NASA EONET 山火事件 | 10 分钟 |
| `/live/disasters` | GDACS 洪水/火山/干旱/山火 | 5 分钟 |
| `/live/air-quality` | Open-Meteo/CAMS 空气质量视口采样 | 15 分钟 |
| `/live/floods` | Open-Meteo/GloFAS 河流流量视口采样 | 6 小时 |
| `/live/aircraft` | ADSB.lol 当前飞机 | 5–8 秒 |
| `/live/vessels` | 挪威沿岸开放 AIS 船舶 | 接收流持续更新，前端 8 秒刷新 |
| `/live/ocean-buoys` | NOAA NDBC 最新浮标观测 | 10 分钟 |
| `/live/cyclones` | GDACS 热带气旋 | 5 分钟 |

`/live/catalog` 提供机器可读目录和 `keyPolicy: no-key-only`；`/live/status` 提供进程内最近检测状态；`PUT /live/settings/{layer_id}` 只持久化 `enabled` 与 `refreshSeconds`。设置默认写入 `/data/maintenance/live-layer-settings.json`，可用 `LIVE_LAYER_SETTINGS_PATH` 调整位置。

## 独立管理页

- 地图弹窗保留快速开关，并通过“管理附加信息源”进入 `/information-layers.html`。
- 管理页中的停用状态和刷新频率会在下次进入地图时加载；停用不会删除适配器或历史配置。
- “连接测试”使用各信源的代表性有限视口，并把对象数、耗时和最近错误写入进程内运行状态；测试不会改变地图视口。
- “测试全部免密源”最多并行测试 3 个源，避免瞬间向公共服务发送过多请求。
- 需密钥候选目录为只读决策清单，接入前仍需单独决定凭据保管、退避与配额策略。

## AIS 配置

默认使用挪威沿岸管理局公开、无需注册的 `153.44.253.27:5631` TCP 流。可以用同一接口换成本机 AIS 接收机：

- `AIS_TCP_ENABLED=true`
- `AIS_TCP_HOST=153.44.253.27`
- `AIS_TCP_PORT=5631`
- `LIVE_LAYER_SETTINGS_PATH=/data/maintenance/live-layer-settings.json`

接收器只保留最近 15 分钟船位；静态船名可能晚于位置消息到达，因此初次显示会使用 MMSI。公开流仅覆盖挪威经济区、斯瓦尔巴和扬马延附近，并排除部分小型船只。

## 新增适配器步骤

1. 在 `live_layers.py` 新增只访问固定 URL 的适配方法，并通过 `TtlCache` 获取上游数据。
2. 转换为统一属性，保留原始来源、观测时间、许可、覆盖和安全限制。
3. 在 `/live/catalog` 声明优先级、刷新周期和许可，在 `main.py` 增加只接收有限 bbox/limit 参数的端点。
4. 在 `LIVE_LAYER_DEFINITIONS` 增加一个目录项，并在 `pointLayer()` 中配置独立样式；不要把提供方特例写入 `app.js`。
5. 添加适配器单元测试、固定 UI 夹具、来源与许可文档。
6. 如果需要密钥，只从 API 服务端环境变量读取并实现 429 退避；先更新 [需要密钥的数据源决策目录](KEYED_DATA_SOURCES.zh-CN.md)，得到决定后再启用。

## 运行限制

- 所有层默认关闭，只有用户主动开启才访问公网。
- 空气质量和河流流量是 3×3 视口模型采样，不渲染成虚假的连续监测站网络。
- ADS-B 单次查询半径上限 250 海里；大视口会标记为部分覆盖，放大地图后再刷新。
- 灾害、航空、航海数据只供态势参考，不能用于应急、空管或航行安全决策。
