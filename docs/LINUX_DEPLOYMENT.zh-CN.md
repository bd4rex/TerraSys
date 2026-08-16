# Linux 服务器部署

> [English](LINUX_DEPLOYMENT.md) | 简体中文
>
> 支持基线：Ubuntu Server 24.04 LTS、Docker Engine、Docker Compose 插件和 PowerShell 7。

本指南用于把 TerraSys 部署到可信服务器或 VPN 网络。服务器直接从公网下载源代码、固定摘要的容器镜像及公开地理数据；只有私有 PostGIS/媒体备份需要经过内网传输。

## 1. 扩展 Ubuntu LVM 根磁盘

变更存储前，先确认准确的磁盘、分区、物理卷和逻辑卷：

```bash
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
sudo pvs
sudo vgs
sudo lvs
findmnt /
```

常见 Ubuntu 布局中，虚拟磁盘为 `/dev/sda`、LVM 使用第 3 分区、根目录位于 `/dev/ubuntu-vg/ubuntu-lv`，对应命令是：

```bash
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
df -h /
sudo pvs
sudo lvs
```

如果服务器布局不同，不得照抄这些设备名。`lvextend -r` 会同时扩展逻辑卷和文件系统。

## 2. 更新操作系统

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
sudo apt-get autoremove --purge -y
sudo timedatectl set-timezone Asia/Shanghai
sudo reboot
```

重新连接后检查 `uname -r`、`cat /etc/os-release` 和 `apt list --upgradable`。只用 `sudo do-release-upgrade -c` 查询 Ubuntu 是否提供受支持的大版本升级，不强制跨越未开放的升级路径。

## 3. 安装运行环境

从 Docker 官方 Ubuntu 软件源安装 Docker Engine 与 Compose 插件，再从 Microsoft Ubuntu 软件源安装 PowerShell：

- [Docker Engine Ubuntu 安装说明](https://docs.docker.com/engine/install/ubuntu/)
- [PowerShell Ubuntu 安装说明](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu)

验证运行环境：

```bash
docker version
docker compose version
pwsh --version
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

修改 Docker 组成员后，需要退出并重新登录。

## 4. 克隆并配置 TerraSys

```bash
sudo install -d -o "$USER" -g "$USER" -m 0750 /opt/terrasys
git clone https://github.com/bd4rex/TerraSys.git /opt/terrasys/app
cd /opt/terrasys/app
./terrasys.sh test-suite -Profile static
./terrasys.sh start
```

首次启动会在 `services/.env` 中创建高强度 PostgreSQL 和 Nominatim 本地密码。服务器存在任何不可信网络接口时，应明确限制监听地址：

```dotenv
TERRASYS_BIND_ADDRESS=172.16.100.75
TERRASYS_HTTP_PORT=8080
```

请替换为服务器真实的可信局域网/VPN 地址。TerraSys 是单用户可信网络系统，不应把 `8080` 端口直接发布到公网。限制环境文件权限：

```bash
chmod 0600 services/.env
```

Linux 启动命令还会把当前用户的数字 UID 和 GID 写入该文件，并在 Compose 之前创建全部宿主机目录与占位文件，避免 Docker 生成 root 所有的绑定路径。API 以当前用户身份运行，因此媒体、导出、缓存、维护及公开数据构建路径无需放宽为全局可写，也能保持正常读写。

## 5. 恢复私有数据

把已校验的 TerraSys 备份目录放到 `backups/` 下，然后运行：

```bash
./terrasys.sh restore -BackupDirectory /opt/terrasys/app/backups/20260816-120000
```

目录必须包含 `terrasys.dump`、`manifest.json`，可以包含 `media/`。恢复命令会先验证文件大小和 SHA256，再替换新数据库。服务器验证完成前，至少保留另一份备份副本。

## 6. 由服务器直接下载并构建公开数据

大型可复现资源应由服务器从公开上游直接获取，不通过 VPN 搬运。Kiwix 知识库、Natural Earth 资源和区域 OSM 源都使用可续传的公开下载，其中概览栅格使用 Natural Earth 的 NACIS CDN：

```bash
./terrasys.sh download-web-assets
./terrasys.sh sync-world-catalog
./terrasys.sh download-osm
./terrasys.sh region-pack Build -PackId jiangsu
./terrasys.sh region-pack Build -PackId anhui
./terrasys.sh region-pack Build -PackId shandong
./terrasys.sh region-pack Build -PackId gf-north-korea
./terrasys.sh region-pack Build -PackId gf-south-korea
./terrasys.sh prepare-advanced -SkipStart
./terrasys.sh sync-elevation
./terrasys.sh build-world-overview-vector
./terrasys.sh build-osm-carto
./terrasys.sh start --no-build
```

中国快照与区域源使用可断点续传的暂存文件，只有通过格式/完整性校验后才会启用。如果 Geofabrik 暂时不可达，目录刷新会保留仓库内已校验的快照。朝鲜和韩国地图包使用 OpenStreetMap Korea 的公开非军事要素提取文件，完整扫描 PBF 后把 SHA256 写入产品清单。下载、地图包构建和共享源合并都会检查 Osmium 引用计数；当前经过过滤的朝鲜提取文件显式使用 20,000 的有限上限，韩国必须为 0。首次区域构建还会通过服务器公网从各自上游断点续传 Planetiler 的三个共享底图归档，校验 ZIP 结构并记录 SHA256，后续离线构建直接复用；其中带版本号的湖泊中心线归档还会在启用前核对固定字节数和 SHA256。

OSM Carto 构建会自动从公开上游断点续传五份水域、冰盖和 Natural Earth Shapefile 归档，校验 ZIP 中的必需文件并在导入前记录 SHA256；如果 Planetiler 缓存中已有经过验证的大型水域归档，会直接复用而不重复下载。

渲染器始终固定到同一个 OCI 清单 SHA256。若 Docker Hub 或主机配置的加速器拒绝该仓库，构建命令会先尝试 Overv 组织的 `ghcr.io` 镜像，再把 `docker.1ms.run` 作为次级回退；Docker 必须验证完全相同的摘要才会接受镜像，成功选择的完整引用会写入本机 `services/.env`。手工设置 `OSM_CARTO_IMAGE` 时也必须保留文档中的固定摘要。

Nominatim 也支持通过 `NOMINATIM_IMAGE` 更换 registry 前缀，并同样拒绝任何不匹配的清单摘要。启动命令会识别本机已有且摘要正确的 `docker.1ms.run` 回退镜像；该选择也会贯穿共享索引重建与离线包导出。

Nominatim、Valhalla、Planetiler 和 OSM Carto 都会大量占用资源。16 GiB 主机应按顺序构建，并保留充足磁盘空间；Valhalla 首次构建使用 4 GiB 内存上限和最多 5 GiB memory+swap 上限，完成后的常驻使用量会明显降低。

## 7. 安装开机启动与每日备份

```bash
sudo ./scripts/install-linux-service.sh --user "$USER" --root /opt/terrasys/app --start
systemctl status terrasys.service --no-pager
systemctl list-timers terrasys-backup.timer --no-pager
```

安装器会创建 systemd 应用服务和可补跑的每日备份计时器。日志查看命令：

```bash
journalctl -u terrasys.service -n 200 --no-pager
journalctl -u terrasys-backup.service -n 200 --no-pager
```

## 8. 验证与更新

```bash
cd /opt/terrasys/app
./terrasys.sh health
./terrasys.sh smoke
docker compose -f services/docker-compose.yml ps
curl --fail http://127.0.0.1:8080/healthz
```

后续更新应用：

```bash
cd /opt/terrasys/app
git pull --ff-only
./terrasys.sh test-suite -Profile static
sudo systemctl restart terrasys.service
./terrasys.sh health
```

运行 `./terrasys.sh help` 可查看替代根目录全部 Windows `.cmd` 入口的 Linux 命令。
