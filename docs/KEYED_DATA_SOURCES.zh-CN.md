# 需要密钥或账号的数据源决策目录

> [English](KEYED_DATA_SOURCES.md) | 简体中文 · 更新于 2026-08-10

更新日期：2026-08-10

本目录只记录已经评估、但按当前“先不接入任何需要密钥的来源”决定而未进入 TerraSys 运行代码的数据源。额度和条款可能变化；正式启用前应再次检查官方页面。

## 候选清单与调用限制

| 候选源 | 可补充的图层 | 认证与费用 | 官方公开的调用限制 | 数据/许可约束 | 当前建议 |
| --- | --- | --- | --- | --- | --- |
| [NASA FIRMS](https://firms.modaps.eosdis.nasa.gov/api/map_key/) | 卫星活跃火点、火灾热异常 | 邮箱申请免费的 `MAP_KEY` | 每个 MAP_KEY **5,000 transactions / 10 分钟**；大范围或多日请求可能按多次交易计算，官方示例说明 7 日请求会增加计数 | NASA/卫星产品总体开放，但展示时应保留 FIRMS、卫星与产品归属；它是热异常，不等同于已确认山火 | **优先考虑**。比当前无密钥的 EONET 事件点更细、更及时 |
| [OpenAQ v3](https://docs.openaq.org/using-the-api/api-key) | 地面空气质量监测站实测值 | 注册账号取得免费 API key，以 `X-API-Key` 请求 | 免费层 **60 次/分钟、2,000 次/小时**；默认每页 100，最大 1,000 条；响应含 rate-limit headers | 必须署名 OpenAQ，并遵守每个原始数据提供方的许可；官方托管 API 不得用于实质复制/竞争其核心服务 | **可选增强**。可与当前 Open-Meteo/CAMS 模型层并列，明确区分“站点实测”和“模型值” |
| [AISStream.io](https://aisstream.io/documentation) | 全球实时 AIS 船舶 | 登录后生成 API key；当前为免费 Beta，官方不提供 SLA | 未公布固定日/月额度；按用户和 key 节流；订阅更新最多 **1 次/秒**；MMSI 过滤最多 **50 个**；连接后 **3 秒内**必须提交订阅；全球订阅需能处理约 **300 条消息/秒** | 不支持浏览器直接跨域连接，密钥必须由后端持有；Beta API/对象模型不稳定 | **若要全球 AIS，最值得先试**。当前无密钥 AIS 仅覆盖挪威区域 |
| [Global Fishing Watch API v3](https://globalfishingwatch.org/our-apis/documentation) | 捕鱼活动、船舶身份、靠港/相遇/徘徊/AIS 关闭事件 | 注册账号并创建 Bearer token；API 只允许非商业用途 | 官方未给统一 QPS 数字；4Wings 报告通常每个用户只允许 **1 个并发报告**，超出返回 429；地图瓦片最大 zoom 12；应使用短时间范围 | 必须署名 Global Fishing Watch；捕鱼努力数据约有 **96 小时延迟**，属于算法推断的“表观活动”，不是实时船位或执法结论 | **专题分析时再加**。价值高，但不应当作普通实时 AIS 图层 |
| [BarentsWatch AIS API](https://developer.barentswatch.no/docs/AIS/live-ais-api/) | 挪威 AIS 的丰富静态字段、最近位置与 14 日历史轨迹 | 注册 BarentsWatch 账号并创建 AIS client，使用 Client ID/Secret 换取 OAuth token；数据按 NLOD 开放 | [官方性能规则](https://developer.barentswatch.no/docs/intro/)无固定数字额度；批量下载要求单线程顺序执行，不要并行；流式接口保持长连接 | 仅挪威经济区、斯瓦尔巴与扬马延覆盖；不公开 15 米以下渔船、45 米以下休闲/帆船；历史不超过 14 天 | **暂缓**。当前已用同源无密钥 TCP 流实现基础船位；需要轨迹/船舶详情时再升级 |

## 如决定启用，建议的密钥目录

所有密钥只放在 API 服务端环境变量或本机 `services/.env`，不写入网页、Git、截图、日志或 GeoJSON 响应。

| 环境变量 | 用途 | 是否属于敏感凭据 | 建议刷新/失效策略 |
| --- | --- | --- | --- |
| `FIRMS_MAP_KEY` | NASA FIRMS 火点 API/WMS | 是 | 泄露后立即在 FIRMS 页面更换 |
| `OPENAQ_API_KEY` | OpenAQ v3 | 是 | 泄露或被限流时轮换；禁止多账号规避额度 |
| `AISSTREAM_API_KEY` | AISStream WebSocket | 是 | 只在后端长连接进程使用；撤销旧 key 后再生成 |
| `GFW_ACCESS_TOKEN` | Global Fishing Watch API | 是 | 按账号门户权限和有效期轮换 |
| `BARENTSWATCH_CLIENT_ID` | BarentsWatch OAuth client | 标识符 | 与 secret 成对管理 |
| `BARENTSWATCH_CLIENT_SECRET` | BarentsWatch OAuth client secret | 是 | 只用于服务端换取短期 access token；泄露后吊销 |

## 推荐决策顺序

1. 需要更细的山火效果：先申请 FIRMS MAP_KEY。
2. 需要全球实时船舶：再试 AISStream.io，先限定视口并限制消息类型，不做全球常驻订阅。
3. 需要地面实测空气质量：启用 OpenAQ，与模型层同时显示来源类型。
4. 需要渔业行为分析：启用 Global Fishing Watch，但作为延迟专题分析层。
5. 需要挪威船舶历史轨迹和完整静态字段：再启用 BarentsWatch OAuth API。

## TerraSys 接入约束

- 密钥源将继续使用独立“附加信息图层”模块的统一 GeoJSON 适配器，不让前端直接接触凭据。
- 每个适配器必须声明 `source`、`license`、`refreshSeconds`、`coverage`、`dataLatency` 和 `decisionUse`。
- 后端必须做 TTL 缓存、视口裁剪、超时、429 退避和熔断；前端不得把地图平移直接放大成上游请求风暴。
- 弹窗必须展示原始信源、观测时间和许可；灾害、航空、航海信息必须保留“非安全决策系统”提示。
