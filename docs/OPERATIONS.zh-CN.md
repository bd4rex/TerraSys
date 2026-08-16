# 运维

> [English](OPERATIONS.md) | 简体中文 · 快照 `2026-08-03T23:12:23+08:00`

## 启动、停止与检查

```powershell
D:\TerraSys\start-terrasys.cmd
D:\TerraSys\health-check.cmd
D:\TerraSys\stop-terrasys.cmd
```

Linux 使用统一命令入口：

```bash
./terrasys.sh start
./terrasys.sh health
./terrasys.sh stop
```

主机准备、服务器公网直下、systemd 和备份配置见 [Linux 服务器部署](LINUX_DEPLOYMENT.zh-CN.md)。

健康检查通过后打开 `http://localhost:8080/`。

查看详细服务状态：

```powershell
Set-Location D:\TerraSys\services
docker compose ps
docker compose logs --tail 100 api web martin postgis
```

核心容器是 `terrasys-web`、`terrasys-api`、`terrasys-martin`、`terrasys-postgis`。完整准备后还应运行 `terrasys-nominatim`、`terrasys-valhalla`、`terrasys-kiwix` 和 `terrasys-osm-carto`。

## 高级离线能力

```powershell
D:\TerraSys\prepare-advanced.cmd
```

命令围绕已校验产品保持幂等：合并已安装区域为共享能力 PBF，准备百科、旅行指南、全球概览、天气与航海，构建路线和海拔，并启动高级 Compose 配置。OSM Carto 通过 `scripts\build-osm-carto.ps1` 独立构建。

独立重建 z0-7 全球矢量底图：

```powershell
D:\TerraSys\build-world-overview-vector.cmd
```

首次运行会缓存 Natural Earth 官方 GeoPackage。构建先写入 staged 文件，校验 PMTiles 文件头和最小体积后才替换 `web/assets/overview/world-overview.pmtiles`，并把 SHA256 写入 `overview.manifest.json`。浏览器将该内容哈希附加到 Range 请求，防止更新后的归档继续复用旧 PMTiles 字节缓存。

16 GiB 主机不得并发重建 Valhalla 和 Nominatim。正常启动复用活动路线归档、Nominatim 卷和 OSM Carto 数据库。

## 健康与功能测试

```powershell
D:\TerraSys\health-check.cmd
D:\TerraSys\smoke-test.cmd
```

健康检查验证服务、nginx、FastAPI/PostGIS、Martin 白名单、所有 PMTiles Range 206、全球目录、备份、高级引擎、知识库、全球概览、天气、航海以及已准备的 OSM Carto。

功能测试会创建、更新、搜索并删除临时个人记录，还检查区域包、地址、反向地址、路线、海拔、地形、应急、Kiwix、统一搜索、GPX、媒体、导出和清理。

统一测试入口按成本分为四层：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile static
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile browser
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile full
powershell -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\tests\run-suite.ps1 -Profile recovery
```

`static` 不依赖运行服务，并在 GitHub PR 上自动执行；`browser` 增加健康与四类 Playwright 回归；`full` 再增加 API、资源和个人数据生命周期；`recovery` 最后执行隔离断网恢复演练。完整用例、前置条件、副作用和证据位置见[测试用例集](../tests/README.zh-CN.md)。截图写入 `runtime/ui-smoke` 和 `runtime/resource-console-smoke`。性能测试自动读取 `tests/performance-baseline.json`，输出当前值相对 2026-08-07 三次测试中位数的差异，并使用保存的宽松上限拦截显著退化。

## 地图与资源管理

在“系统 → 管理资源”中使用：

- **可获取**：浏览全球层级并查看每个真实区域包；
- **本地**：统计地图、来源、搜索/路线、地形、知识、个人数据、备份和缓存；
- **可更新**：检查地图、共享索引、目录、概览、天气、航海与知识产品。

主地图在 z0-7 始终有 Natural Earth 110m/50m/10m 多级矢量概览。区域 OSM 在其上补充细节，但不会移除未安装区域的全球道路、边界、河流和地名骨架。z8 以下隐藏自动下载建议，100km 全球浏览不会再弹出日本、美国等区域提示；“在全球地图定位”仍可强制保留精确目录选择。来源菜单提供“仅离线、OSM Standard、OpenFreeMap”，并显示实际来源和当前覆盖；在线来源失败时依次回退到备用在线源和本地概览，且不会批量缓存。

资源页面先读取 `data\maintenance\resource-inventory-cache.json`，再由单个后台线程刷新。可获取目录和维护队列独立显示，慢速磁盘扫描不会遮住任务。

任务行显示真实队列、阶段、耗时、取消、重试和可测量速率。批量更新排除地图构建、共享索引和大型知识下载。天气默认每 6 小时、全球目录每 7 天自动刷新。

地图包支持校验、更新、受保护删除、清单导出、启用/停用、重建和浏览。停用保留文件但立即停止渲染，并使共享索引范围变旧。若索引覆盖全部启用包但包含多余旧范围，搜索/路线仍可服务但提示清理重建；缺少任一启用包时会阻止共享能力，直到重建完成。

区域包构建、更新、重建、删除、启用或停用改变活动范围后，系统自动排入天气与航海两个轻量派生任务。OSM Carto 与共享搜索/路线属于重型蓝绿重建，保持显式操作；资源页按区域显示待同步状态，不能用服务整体健康掩盖范围变化。

维护状态位于 `D:\TerraSys\data\maintenance`：

| 路径 | 用途 |
| --- | --- |
| `settings.json` | 自动更新策略 |
| `worker.json` | 工作器 PID、心跳和当前任务 |
| `jobs\*.json` | 队列与历史任务 |
| `logs\*.log` | 每项脚本输出 |
| `backup-policy.json` | 每日备份与镜像目标 |

浏览器不能提交任意命令，只能提交目录 ID 和固定资源白名单动作。

### Nominatim 未完成导入恢复

状态健康但搜索提示超时时，先执行：

```powershell
docker exec -u nominatim terrasys-nominatim nominatim admin --check-database --project-dir /nominatim
```

缺少数据库版本或两个搜索向量 GIN 索引时，只续建后处理：

```powershell
docker exec -u nominatim terrasys-nominatim nominatim import --project-dir /nominatim --continue db-postprocess -j 4 --no-updates --offline
```

期间不要重启 Docker。完成后重新运行数据库自检，并检查 `/api/geocode` 与 `/api/reverse`。

### 区域包命令

```powershell
D:\TerraSys\region-pack.cmd List
D:\TerraSys\region-pack.cmd Verify
D:\TerraSys\region-pack.cmd Plan -PackId jiangsu
D:\TerraSys\region-pack.cmd Build -PackId jiangsu
D:\TerraSys\region-pack.cmd Update -PackId jiangsu
D:\TerraSys\region-pack.cmd Remove -PackId jiangsu -ConfirmRemove
```

`Plan` 不改数据；`Verify` 比较 SHA256；`Build` 使用缓存源；`Update` 先刷新可信上游状态；`Remove` 只删除派生 PMTiles/manifest，保留源和边界。已达到当前源序列时再次更新会返回 `409`，需要重新生成时使用“重建”。

### 重建共享搜索与路线索引

```powershell
D:\TerraSys\rebuild-shared-indexes.cmd -Plan
D:\TerraSys\rebuild-shared-indexes.cmd -ConfirmRebuild
```

操作分别构建资源受限的 Valhalla 候选和 Nominatim 候选卷。活动地图、搜索和路线继续服务；候选通过健康、数据库、地址、反查和路线检查后才切换。成功后保留一个上一版本，失败或取消不改变活动指针。

恢复已验证但后续配置失败的候选：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\rebuild-shared-indexes.ps1 -ResumeCandidateId YYYYMMDD-HHMMSS
```

已有验证恢复包后，先计划再明确清理旧索引：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\prune-shared-index-versions.ps1 -KeepPrevious 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys\scripts\prune-shared-index-versions.ps1 -KeepPrevious 0 -ConfirmPrune
```

脚本拒绝删除当前容器挂载的 Nominatim 卷或 Valhalla 路径。

## 备份与恢复

```powershell
D:\TerraSys\backup-terrasys.cmd
D:\TerraSys\install-backup-task.cmd
```

每份备份包含 `terrasys.dump`、媒体和 SHA256 `manifest.json`，默认保留 14 份。第二物理磁盘可使用 `-MirrorRoot E:\TerraSys-BACKUPS`，同盘镜像会被拒绝。

恢复会替换数据库内容：

```powershell
D:\TerraSys\restore-terrasys.cmd -BackupDirectory D:\TerraSys\backups\YYYYMMDD-HHMMSS
```

脚本限制目录必须在备份根内，校验 dump，停止 API/Martin，清理恢复，应用新迁移，复制媒体并重启。随后必须运行健康与功能测试。

## 断网恢复包

```powershell
D:\TerraSys\create-offline-kit.cmd
D:\TerraSys\verify-offline-kit.cmd -KitDirectory D:\TerraSys\offline-kit\YYYYMMDD-HHMMSS
D:\TerraSys\test-offline-recovery.cmd -KitDirectory D:\TerraSys\offline-kit\YYYYMMDD-HHMMSS
```

恢复包包含应用、地图与来源、共享 PBF、路线、海拔、知识、概览、天气、航海、OSM Carto、Nominatim/OSM Carto 快照和 Docker 镜像，并写入 SHA256 清单。默认只保留最新有效完整包。隔离演练使用 Docker `--internal` 网络，完成后删除临时资源，审计 JSON 保留在 `runtime/recovery-audit`。

## Docker 空间回收

删除镜像或卷不会自动缩小 VHDX。只有在创建并验证恢复包、确认资源未挂载后，才能在维护窗口：

1. `wsl -d docker-desktop -u root -- fstrim -av`；
2. 停止 TerraSys、Docker Desktop 和 WSL；
3. 用 DiskPart 选择 `D:\DockerData\wsl\disk\docker_data.vhdx` 并执行 `compact vdisk`；
4. 重启并运行启动、健康和功能测试。

Docker 或其 WSL 仍运行时绝不能压缩 VHDX。

## 刷新地图数据

```powershell
D:\TerraSys\backup-terrasys.cmd
D:\TerraSys\download-osm.cmd
D:\TerraSys\region-pack.cmd Update -PackId jiangsu
D:\TerraSys\region-pack.cmd Update -PackId anhui
D:\TerraSys\build-capability-source.cmd
D:\TerraSys\sync-world-catalog.cmd
D:\TerraSys\sync-weather.cmd
D:\TerraSys\build-nautical.cmd
D:\TerraSys\import-reference-search.cmd
D:\TerraSys\health-check.cmd
```

新地图通过浏览器测试前不要删除 `.previous`。构建可能使用约 6GB Java 堆，并产生显著 CPU 与磁盘负载。

## 直接探针

```powershell
Invoke-RestMethod http://localhost:8080/api/status
Invoke-RestMethod 'http://localhost:8080/api/search?q=南京'
Invoke-RestMethod http://localhost:8080/martin/catalog
Invoke-RestMethod http://localhost:8080/api/map-packs
Invoke-RestMethod http://localhost:8080/api/resources
Invoke-RestMethod http://localhost:8080/api/capabilities
Invoke-RestMethod 'http://localhost:8080/api/geocode?q=南京大学'
curl.exe -I -H "Range: bytes=0-1023" http://localhost:8080/tiles/jiangsu.pmtiles
curl.exe -I -H "Range: bytes=0-1023" http://localhost:8080/tiles/anhui.pmtiles
```

Range 命令应返回 `206 Partial Content`。

## 故障处理原则

- 空白地图：运行健康检查，确认 PMTiles/manifest 完整、Range 206，检查 web 日志和 UI 截图。
- 个人数据缺失：检查 `/api/status` 和 API/PostGIS 日志，取 dump 前不要重建卷。
- 密码变化：运行 `start-terrasys.cmd` 同步角色并应用迁移。
- 区域构建中断：只清理暂存文件和对应临时目录，不删除已安装 PMTiles。
- 共享索引中断：确认没有活动任务后才能清理候选缓存，不删除 `.env` 指向的活动卷/路径。
- 路线或地形不可用：检查活动 Valhalla 归档、`products/elevation` 和容器日志；可运行 `powershell -ExecutionPolicy Bypass -File scripts/sync-elevation.ps1` 补齐所有已启用区域的全球来源 HGT，高程生成的地形 PNG 可再生。
