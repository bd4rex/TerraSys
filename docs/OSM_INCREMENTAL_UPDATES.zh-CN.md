# OSM 增量更新与完整快照基线

> [English](OSM_INCREMENTAL_UPDATES.md) | 简体中文 · 快照 `2026-08-03T23:12:23+08:00`

## 当前策略

生产更新继续使用完整快照重建。增量复制只能进入隔离试验，不得覆盖生产 PBF、PMTiles、Nominatim、Valhalla 或 OSM Carto 数据。

每次可恢复发布必须保留：

- 上次验证通过的完整 OSM PBF 与 SHA256；
- 复制序列、源时间、提供方和地图包清单；
- 由该快照生成的 PMTiles 与共享索引回退点；
- 所有试验 OSC、序列和 SHA256。

只读准备检查：

```powershell
D:\TerraSys\plan-osm-incremental-updates.cmd
D:\TerraSys\plan-osm-incremental-updates.cmd -Json
```

## 试验流水线

1. 从已校验完整快照复制 staging PBF，不在活动文件上更新。
2. 从源 state 锁定起始序列，连续下载到已发布目标序列。
3. 保存每个 OSC 与 SHA256，不猜测未发布序列。
4. 用 `osmium apply-changes` 从旧到新应用 diff。
5. 执行 `osmium fileinfo`、`osmium check-refs`、边界与对象数量检查。
6. 先重建一个省级 PMTiles，对比清单、抽样瓦片和关键地点。
7. 通过后再构建共享搜索、路线和相关渲染候选；原子发布并保留上一代。

参考：[Osmium apply-changes](https://docs.osmcode.org/osmium/latest/osmium-apply-changes.html)、[Pyosmium 复制工具](https://docs.osmcode.org/pyosmium/v4.3.0/user_manual/10-Replication-Tools/)和 [OpenStreetMap planet diffs](https://wiki.openstreetmap.org/wiki/Planet.osm/diffs)。

## 灾备规则

- 任一序列缺失、哈希不符、引用异常或地图抽样退化时立即放弃。
- 连续运行一个月并至少与一次同期完整快照一致前，不得作为唯一更新路径。
- 稳定后仍应至少每季度验证一次完整快照。
- 搜索与路线是派生物；完整 OSM、复制状态和个人备份才是恢复根。

## 计划阶段

1. 江苏单包离线 staging，只生成报告不激活。
2. 江苏/安徽连续增量，与完整快照对象和瓦片抽样比较。
3. 分别评估 Nominatim/Valhalla 原生更新与完整候选重建。
4. 满足回退、审计和定期完整基线后才允许计划任务执行。
