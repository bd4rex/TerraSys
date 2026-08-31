# 项目结构

> [English](PROJECT_STRUCTURE.md) | 简体中文

TerraSys 把版本控制源文件与本机数据、可再生产品分开。这样既能让 Git 改动易于审查，又能让部署在源代码升级后继续保留大型离线资源和私人记录。

## 根目录稳定入口

| 路径 | 职责 |
| --- | --- |
| `README.md` / `README.zh-CN.md` | 产品概览和最快受支持启动方式 |
| `start-terrasys.cmd`、`health-check.cmd` 及其他根目录 `.cmd` | 稳定 Windows 兼容启动器，委托给 `scripts/*.ps1` |
| `terrasys.sh` | Linux 统一命令分发器，委托给同一组 PowerShell 脚本 |
| `CHANGELOG.md` / `CHANGELOG.zh-CN.md` | 面向使用者的未发布与历史变更 |

根目录启动器有意保留在仓库顶层，避免现有快捷方式、计划任务、离线包说明和运维习惯失效。新的实现逻辑应放入 `scripts/`，不要写进启动器。

## 版本控制中的实现

| 目录 | 职责 |
| --- | --- |
| `.github/workflows/` | PR 与跨平台仓库检查 |
| `config/` | Planetiler、OSM Carto 与地图构建配置 |
| `docs/` | 维护中的双语架构、运维、部署和恢复文档 |
| `docs/deployment/` | 统一部署索引及 Windows/Linux 宿主机指南 |
| `mcp/` | 默认只读的 MCP 适配器及测试/文档 |
| `qgis/` | QGIS 集成资源 |
| `scripts/` | 跨平台 PowerShell 生命周期与数据流水线实现 |
| `scripts/linux/` | 共享脚本使用的窄范围 Linux 兼容辅助程序 |
| `services/` | Compose 拓扑、服务镜像/配置、API、数据库迁移与 systemd 模板 |
| `tests/` | 静态契约、单元测试、浏览器测试、恢复演练与性能基线 |
| `tools/` | 小型固定版本或仓库自有构建辅助工具 |
| `web/` | 浏览器应用、本地样式、字体、图标和进入版本控制的概览元数据 |

## 本机状态与生成产品

| 目录 | 所有权与生命周期 |
| --- | --- |
| `services/.env` | 本机密钥与活动卷指针；被忽略且不得共享 |
| `raw/` | 下载的源快照、提供方状态、来源记录和构建输入 |
| `products/` | 已校验派生地图、路线图、高程、知识库和清单 |
| `data/` | 个人媒体/导出，以及可再生缓存与维护状态 |
| `backups/` | 带校验保护的个人 PostGIS/媒体恢复点 |
| `offline-kit/` | 可移植断网恢复包 |
| `runtime/` | 测试截图、审计、任务日志和运行报告 |
| `tmp/` | 候选构建和可丢弃临时空间 |

只有可重现性确有需要时，这些目录中的占位文件或少量清单才进入 Git。私人记录、密钥、数据库 dump、下载的 PBF/ZIM、PMTiles、Docker 卷数据和临时日志不得提交。

## 所有权规则

1. 个人 PostGIS 记录与内容寻址媒体是持久用户数据。
2. `backups/` 和已校验离线包是恢复材料，不能替代源代码版本控制。
3. 地图瓦片、Carto 数据库、Nominatim 索引、Valhalla 图、高程缓存和下载知识库属于可替换产品。
4. 候选产品在清单与服务探测通过前都可丢弃；重建期间活动版本继续可用。
5. `services/.env` 是部署唯一使用的 Compose 环境文件，必须留在 Git 外。
6. Windows 与 Linux 共享源代码和备份格式，但不能共享正在运行的 Docker 数据目录。

## 文档结构

- `docs/README.md` 是双语文档索引。
- `docs/deployment/README.md` 是平台选择入口。
- 架构说明组件边界，运维说明日常管理，部署指南说明宿主机准备，从零重建说明完整产品生成，恢复指南说明灾难恢复。
- 历史设计记录与当前运维说明保持明确区分。

移动维护中的文档时，必须在同一次提交中更新两种语言及全部相对链接。静态仓库测试会强制检查双语配对和本地 Markdown 链接有效性。
