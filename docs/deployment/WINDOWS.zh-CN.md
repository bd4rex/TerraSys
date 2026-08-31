# Windows 工作站部署

> [English](WINDOWS.md) | 简体中文
>
> 部署索引：[English](README.md) | [简体中文](README.zh-CN.md)

本指南用于把 TerraSys 安装到可信 Windows 10/11 工作站。Docker Desktop 运行 Linux 容器；根目录 `.cmd` 启动器调用 `scripts/` 下的共享 PowerShell 实现。

## 1. 前提条件

- 64 位 Windows 10 或 Windows 11；
- Windows PowerShell 5.1 或更高版本；
- Git for Windows；
- 配置为 Linux 容器模式的 Docker Desktop；
- 本地 NTFS 磁盘有足够空间容纳 Docker 镜像、区域 PBF/PMTiles、搜索/路线索引、知识库、备份和候选构建。

源代码工作树和 Docker Desktop 数据应位于本地固定磁盘。不要把活动 PostGIS、Nominatim、Valhalla 或 Carto 数据放入云同步目录。

## 2. 克隆代码

以下路径只是示例；脚本会动态解析仓库根目录，不要求必须使用 `D:` 盘。

```powershell
git clone https://github.com/bd4rex/TerraSys.git D:\TerraSys
Set-Location D:\TerraSys
```

不要把私人备份或生成的地图产品加入 Git。源代码工作树准备好后，通过正式备份或离线包流程恢复这些内容。

## 3. 配置密钥与监听地址

创建被忽略的本机配置：

```powershell
Copy-Item services\.env.example services\.env
notepad services\.env
```

保存前完成以下修改：

- 把 `POSTGRES_PASSWORD` 与 `NOMINATIM_PASSWORD` 替换为两个不同且不少于 20 字符的随机值；
- 仅本机访问时使用 `TERRASYS_BIND_ADDRESS=127.0.0.1`；
- 可信局域网或 VPN 使用工作站明确且稳定的地址，不要使用 `0.0.0.0`；
- 除非端口已被占用，否则保留 `TERRASYS_HTTP_PORT=8080`；
- 不得提交 `services/.env`，也不要把内容粘贴到问题报告。

如果 `services/.env` 不存在，正常启动脚本会自动生成随机数据库密码。仍建议显式准备该文件，以便第一个容器启动前就确定网络监听范围。

## 4. 首次启动

启动 Docker Desktop 并等待引擎就绪，然后运行：

```powershell
.\start-terrasys.cmd
.\health-check.cmd
```

启动命令会：

1. 验证 Docker；
2. 创建缺失的 bind mount 目录；
3. 校验本机密钥和固定摘要运行镜像；
4. 启动 PostGIS 并应用有序迁移；
5. 构建或复用 API 镜像；
6. 启动核心服务与已经准备好的高级服务；
7. 启动白名单维护工作器。

仅本机安装打开 `http://127.0.0.1:8080/`，共享安装使用明确配置的局域网/VPN 地址。只有 nginx 发布宿主机端口；数据库和其他引擎仍位于 Docker 内部网络。

## 5. 恢复个人数据

把一份已校验 TerraSys 备份目录放到 `backups/` 下，然后运行：

```powershell
.\restore-terrasys.cmd -BackupDirectory .\backups\<backup-id>
.\health-check.cmd
.\smoke-test.cmd
```

备份目录必须包含 `terrasys.dump` 和 `manifest.json`，也可以包含 `media/`。恢复后的安装通过两项检查前，保留另一份独立副本。

## 6. 准备离线能力

大型地图和知识产品尚未准备时，核心服务也可以先运行。存储和时间允许后准备高级服务：

```powershell
.\prepare-advanced.cmd
.\region-pack.cmd List
.\region-pack.cmd Verify
```

16 GiB 主机应串行执行重型构建。候选产品只有通过格式、大小、校验和、覆盖范围及服务探测后，才会替换活动产品。

完整数据构建顺序见[从零重建](../REBUILD.zh-CN.md)，产品所有权见[数据流水线](../DATA_PIPELINE.zh-CN.md)。

## 7. 安装每日备份

先手工创建一份带校验的备份：

```powershell
.\backup-terrasys.cmd
```

然后注册当前用户任务：

```powershell
.\install-backup-task.cmd -DailyAt "03:00"
Get-ScheduledTask -TaskName "TerraSys Daily Personal Backup"
```

该任务以当前用户和有限权限运行；错过计划后会在可运行时补执行。灾难恢复应通过 `-MirrorRoot` 指向另一块物理磁盘或受保护网络路径，并定期核验目标内容。

## 8. 验收检查

安装、恢复或升级后运行：

```powershell
.\health-check.cmd
.\smoke-test.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-suite.ps1 -Profile static
```

已经准备 Playwright 镜像与在线服务的开发工作站，还应执行[测试用例集](../../tests/README.zh-CN.md)说明的 `browser` 或 `full` 配置。

## 9. 升级

```powershell
.\backup-terrasys.cmd
git status --short
git pull --ff-only
.\start-terrasys.cmd
.\health-check.cmd
.\smoke-test.cmd
```

如果 `git status --short` 出现未知源代码改动，应停止并查明原因，不要直接拉取。本地数据和生成产品本就被忽略；不得为了让 Git 显示干净而删除它们。

## 10. 停止或不重建启动

```powershell
.\stop-terrasys.cmd
.\start-terrasys-offline.cmd
```

离线启动只复用已校验的本地镜像和产品，不会把未完成下载或候选构建误判为已安装产品。
