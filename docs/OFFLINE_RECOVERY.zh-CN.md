# TerraSys 离线恢复指南

> [English](OFFLINE_RECOVERY.md) | 简体中文 · 快照 `2026-08-03T23:12:23+08:00`

本指南设计为在互联网和镜像仓库都不可用时仍能执行。建议打印一份，与离线磁盘放在一起。

## 恢复包内容

- TerraSys 应用、脚本、双语文档、浏览器库、字形和 sprites；
- 最新 PostgreSQL 与媒体备份；
- 所有已安装 PMTiles 及来源清单；
- 区域 PBF、中国 PBF/状态、边界和 Planetiler 缓存输入；
- 共享能力 PBF、Valhalla 图/海拔、维基百科和维基导游、Nominatim 一致快照；
- OSM Carto 来源记录、瓦片缓存和一致数据库快照；
- Natural Earth 全球概览、天气、航海和全球区域目录；
- 固定版本的运行、高级引擎、地图构建、Osmium 与浏览器测试镜像；
- 覆盖所有 payload 和镜像归档的 SHA256 清单。

恢复包不包含 Windows 或 Docker Desktop 安装程序。准备完全断网替换电脑时，要另存一份验证过的 Docker Desktop 安装包。

## 灾难发生前

1. 在不同物理磁盘上保存两份副本。
2. 复制后运行 `verify-offline-kit.cmd`。
3. 每次创建新包后运行 `test-offline-recovery.cmd`。
4. 把成功报告和恢复包 ID 记录在纸面。
5. 做好物理保护，因为备份可能包含私人位置、备注、轨迹和照片。

## 校验恢复包

从原项目执行：

```powershell
D:\TerraSys\verify-offline-kit.cmd -KitDirectory E:\TerraSys-OFFLINE\YYYYMMDD-HHMMSS
```

从恢复包内部执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-offline-kit.ps1 -KitDirectory .
```

任一大小或哈希检查失败都不能继续恢复。

## 在替换电脑上恢复

前提：64 位 Windows、Linux 容器模式 Docker Desktop，以及能够同时容纳恢复包、项目和 Docker 镜像的空间。目标目录必须为空。

```powershell
D:\TerraSys\restore-offline-kit.cmd `
  -KitDirectory E:\TerraSys-OFFLINE\YYYYMMDD-HHMMSS `
  -TargetDirectory D:\TerraSys-RESTORED
```

恢复过程：

1. 校验每个文件；
2. 把 payload 复制到空目标目录；
3. 不访问镜像仓库地加载 Docker 镜像；
4. Compose 启动前恢复 Nominatim 与 OSM Carto 卷；
5. 生成新的本地数据库和 Nominatim 密码；
6. 不重建镜像和高级索引地启动服务；
7. 恢复最新个人数据库和媒体；
8. 运行正常健康检查。

健康检查成功后才能打开 `http://localhost:8080/`。

## 恢复后的手工检查

1. 在概览和街道缩放浏览江苏、安徽。
2. 缩放到本地全球概览，定位一个未安装区域，确认不启用在线地图也会出现正确离线包提示。
3. 在系统页面校验江苏、安徽，再查看一个未安装目录项但不要启动下载。
4. 搜索 `南京` 并打开一个 OSM 参考结果。
5. 打开个人点位，检查集合和照片。
6. 导出个人 GeoJSON。
7. 导入一个小 GPX，再删除临时轨迹。
8. 在替换电脑上创建新备份。
9. 搜索完整地址、反查地图点并规划短距离驾车/步行路线。
10. 启用地形和应急设施，在外网禁用时打开 `/wiki/`。
11. 切换到 OSM 原版，确认本地 OSM Carto 瓦片可用。

完全断网时，OSM Standard 和 OpenFreeMap 不可用属于正常现象；Natural Earth、OSM Carto、已安装 PMTiles、个人数据、搜索/路线、已拥有地形和 Kiwix 仍应本地工作。

## 只恢复文件，不启动服务

```powershell
D:\TerraSys\restore-offline-kit.cmd `
  -KitDirectory E:\TerraSys-OFFLINE\YYYYMMDD-HHMMSS `
  -TargetDirectory D:\TerraSys-RESTORED `
  -PrepareOnly `
  -SkipImageLoad
```

适用于 Docker 尚未安装或只想检查文件的情况。

## 断网重建区域地图

```powershell
D:\TerraSys-RESTORED\region-pack.cmd Build -PackId jiangsu
D:\TerraSys-RESTORED\region-pack.cmd Build -PackId anhui
D:\TerraSys-RESTORED\build-capability-source.cmd
D:\TerraSys-RESTORED\import-reference-search.cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\TerraSys-RESTORED\scripts\build-osm-carto.ps1
D:\TerraSys-RESTORED\health-check.cmd
```

断网时不要运行 `download-osm.cmd` 或 `download-web-assets.cmd`，它们会主动访问上游。

## 失败规则

- 诊断时不要删除唯一备份或地图包。
- 不要忽略校验失败。
- 恢复过程中尽量把原离线磁盘保持只读。
- 恢复到新的空目录，不要覆盖状态不明的安装。
- 镜像加载失败时先保留恢复包并检查磁盘健康，再尝试其他副本。
