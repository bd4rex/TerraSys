# 部署指南

> [English](README.md) | 简体中文

TerraSys 维护两种部署目标。两者使用相同的 Docker Compose 拓扑、数据库迁移、数据产品和 PowerShell 实现脚本；区别只在宿主机运行时与服务管理方式。

## 选择部署目标

| 目标 | 适用场景 | 宿主机运行时 | 主入口 | 后台服务 | 备份计划 |
| --- | --- | --- | --- | --- | --- |
| [Windows 工作站](WINDOWS.zh-CN.md) | 带本地地图构建工具的个人台式机或笔记本 | 使用 Linux 容器的 Docker Desktop 与 Windows PowerShell | `start-terrasys.cmd` | Docker Desktop 与当前用户会话 | Windows 任务计划程序 |
| [Linux 服务器](LINUX.zh-CN.md) | 长期开机的可信局域网或 VPN 服务器 | Docker Engine、Compose 插件与 PowerShell 7 | `./terrasys.sh start` | `terrasys.service` | `terrasys-backup.timer` |

同一份工作树应选择一种宿主机方式。个人备份和已校验离线包可以在两种目标间迁移，但运行中的 Docker 数据库卷或索引卷不能直接复制。

## 共同部署约定

两种方式使用相同的仓库结构：

1. `services/docker-compose.yml` 定义八服务运行拓扑。
2. `scripts/*.ps1` 保存跨平台生命周期、构建、校验、备份和恢复逻辑。
3. 根目录 `.cmd` 文件是稳定的 Windows 兼容启动器。
4. `terrasys.sh` 是 Linux 统一入口。
5. `services/.env` 保存本机密钥、监听设置和蓝绿卷活动指针，永不提交。
6. `raw/`、`products/`、`data/`、`backups/`、`offline-kit/` 保存本地状态和大型产物，不属于源代码。

完整所有权与 Git 规则见[项目结构](../PROJECT_STRUCTURE.zh-CN.md)。

## 日常命令对照

| 操作 | Windows | Linux |
| --- | --- | --- |
| 启动 | `start-terrasys.cmd` | `./terrasys.sh start` |
| 不重建镜像启动 | `start-terrasys-offline.cmd` | `./terrasys.sh start-offline` |
| 健康检查 | `health-check.cmd` | `./terrasys.sh health` |
| API 生命周期冒烟测试 | `smoke-test.cmd` | `./terrasys.sh smoke` |
| 个人数据备份 | `backup-terrasys.cmd` | `./terrasys.sh backup` |
| 校验地图包 | `region-pack.cmd Verify` | `./terrasys.sh region-pack Verify` |
| 停止 | `stop-terrasys.cmd` | `./terrasys.sh stop` |

## 安全升级顺序

两个平台都使用以下顺序：

1. 创建并校验个人数据备份；
2. 确认没有数据构建或恢复任务在运行；
3. 获取代码并以 fast-forward 更新工作树；
4. 正常启动，让迁移与镜像变更生效；
5. 执行健康检查和冒烟测试；
6. 更新后的安装稳定使用前，保留上一份备份。

大型生成产品只有在暂存替代版本通过自身完整性检查后才会切换。代码更新不应要求删除仍健康的地图、搜索、路线或知识产品。

## 网络边界

TerraSys 面向 localhost、可信局域网或私有 VPN 中的单个可信用户。Windows 仅本机使用时把 `TERRASYS_BIND_ADDRESS` 设为 `127.0.0.1`；共享访问时设为一个明确的可信局域网/VPN 地址。加入身份认证、TLS、限流和更严格上传策略前，不得监听公网接口。
