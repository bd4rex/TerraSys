# TerraSys 测试用例集

> [English](README.md) | 简体中文

这套测试把项目迭代中反复出现的回归点固化为统一入口。机器可读目录在 [`test-cases.json`](test-cases.json)，自动化入口是 [`run-suite.ps1`](run-suite.ps1)。

## 执行层级

| Profile | 适用时机 | 内容 | 典型耗时与依赖 |
| --- | --- | --- | --- |
| `static` | 每次提交、GitHub PR | JSON、PowerShell 语法、双语文档、相对链接、用例目录、浏览器镜像完整性 | 数秒；不需要 Docker 或运行服务 |
| `browser` | 界面、地图或资源页改动 | `static`、健康检查、主界面、资源页、全球地图、性能回归 | 需要正在运行的八服务栈和 Docker |
| `full` | API、资源生命周期、数据模型或发布前 | `browser` 加 API/个人数据完整生命周期 | 会创建临时个人记录和媒体，脚本在 `finally` 中清理 |
| `recovery` | 备份、恢复、镜像或迁移改动 | `full` 加最新恢复包的隔离断网恢复演练 | 成本最高；需要已生成的完整离线包 |

从项目目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-suite.ps1 -Profile static
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-suite.ps1 -Profile browser
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-suite.ps1 -Profile full
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-suite.ps1 -Profile recovery
```

所有 profile 都会运行 `tests/test_live_layers.py` 的确定性单元测试；它使用固定夹具验证缓存、跨日期变更线 bbox、USGS 规范化和 AIS NMEA 解码，不访问公网。

浏览器层会构建 `terrasys-ui-test:suite`，并与 `terrasys-web` 共享网络命名空间。重复测试时可用 `-SkipImageBuild` 复用已构建镜像；测试脚本或基线有变化时不要跳过构建。

## 回归覆盖

用例目录把历史改进归纳为以下契约：

- 仓库与文档：配置可解析、脚本无语法错误、双语文件成对、相对链接有效。
- 地图包与派生资源：中国 34 个省级单元和全球目录完整，所有已启用区域进入 Carto、搜索、路线、高程、天气与航海覆盖，并保留逐区域来源哈希。
- 个人数据：点位、轨迹、集合、乐观版本、GPX、GeoJSON、ZIP、媒体所有权和孤儿清理形成闭环。
- 地图体验：本地 Carto、区域 PMTiles、全球概览和两个在线来源切换；网络失败、Carto 延迟、海岸/海洋/低缩放误判和视口平移均有回归断言。
- 附加信息图层：无密钥目录、持久化启停/刷新设置、运行状态、统一 GeoJSON、缓存、bbox、AIS 解码、P0/P1 入口、独立管理页及等高线保留逻辑有单元和浏览器回归。
- 全球本地化：国家多边形定位和中文提示一致，台湾相关包、资源名、要素详情与全球概览图层统一显示“台湾省”。
- 性能：启动只请求一次地图包目录，并将 DOM、画布和系统就绪时间与三次测试中位数比较。
- 恢复：先校验路径、大小和 SHA256，再在隔离 Docker 网络中验证数据库、地图、搜索、路线、知识库、个人数据和导出。

## 证据与副作用

Playwright 截图写入忽略版本控制的 `runtime/ui-smoke`、`runtime/resource-console-smoke` 和 `runtime/information-layer-console-smoke`。性能脚本输出当前值、基线值和百分比变化。恢复演练报告写入 `runtime/recovery-audit`。

`scripts/smoke-test.ps1` 会创建临时集合、点位、轨迹、媒体和导出文件，并在成功或失败时执行清理。浏览器测试拦截需要写入的维护请求，不会触发真实删除或重建。`recovery` profile 会创建临时隔离容器、网络和卷，并由恢复脚本清理。

## 维护规则

修复回归时，应把最小稳定断言放进最接近问题的自动化脚本，并同步更新 `test-cases.json`。新增浏览器脚本时还要将它复制进 `services/tools/ui-test/Dockerfile`；`static` profile 会检查这个约束。

性能基线只在有意改变启动路径或测试环境时更新。至少记录三次新的浏览器上下文，保存中位数，并让 guardrail 明显宽于正常波动，避免把一次本机抖动当作产品退化。

提交前至少运行 `static`；涉及运行逻辑时运行 `full`；涉及恢复材料时运行 `recovery`。GitHub Actions 会在 PR 和 `main` 推送上自动执行 `static`。
