# Linux server deployment

> English | [简体中文](LINUX_DEPLOYMENT.zh-CN.md)
>
> Supported baseline: Ubuntu Server 24.04 LTS, Docker Engine, Docker Compose plugin, and PowerShell 7.

This guide deploys TerraSys on a trusted server or VPN. The server downloads source code, pinned container images, and public geographic datasets directly from the internet; only private PostGIS/media backups need to cross the private network.

## 1. Expand an Ubuntu LVM root disk

Inspect the exact disk, partition, physical volume, and logical volume before changing storage:

```bash
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
sudo pvs
sudo vgs
sudo lvs
findmnt /
```

For the common Ubuntu layout where the virtual disk is `/dev/sda`, LVM uses partition 3, and `/` is `/dev/ubuntu-vg/ubuntu-lv`:

```bash
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
df -h /
sudo pvs
sudo lvs
```

Do not copy these device names to a host with a different layout. `lvextend -r` grows the filesystem together with the logical volume.

## 2. Update the operating system

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
sudo apt-get autoremove --purge -y
sudo timedatectl set-timezone Asia/Shanghai
sudo reboot
```

After reconnecting, verify `uname -r`, `cat /etc/os-release`, and `apt list --upgradable`. Use `sudo do-release-upgrade -c` only to check whether Ubuntu offers a supported release upgrade; do not force an unsupported release path.

## 3. Install the runtime

Install Docker Engine and its Compose plugin from Docker's official Ubuntu repository, then install PowerShell from Microsoft's Ubuntu repository:

- [Docker Engine for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [PowerShell on Ubuntu](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu)

Verify the runtime:

```bash
docker version
docker compose version
pwsh --version
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and reconnect after changing Docker-group membership.

## 4. Clone and configure TerraSys

```bash
sudo install -d -o "$USER" -g "$USER" -m 0750 /opt/terrasys
git clone https://github.com/bd4rex/TerraSys.git /opt/terrasys/app
cd /opt/terrasys/app
./terrasys.sh test-suite -Profile static
./terrasys.sh start
```

The first start creates strong local PostgreSQL and Nominatim passwords in `services/.env`. Add the host binding explicitly when the machine has any untrusted interface:

```dotenv
TERRASYS_BIND_ADDRESS=172.16.100.75
TERRASYS_HTTP_PORT=8080
```

Use the server's actual trusted LAN/VPN address. TerraSys is a single-user trusted-network system; do not publish port `8080` directly to the internet. Restrict the environment file:

```bash
chmod 0600 services/.env
```

On Linux, the start command also records the invoking user's numeric UID and GID in that file. It creates every host-side directory and placeholder file before Compose can create a root-owned bind target. The API runs with the invoking identity so media, export, cache, maintenance, and public-data build paths remain writable without granting broad filesystem permissions.

## 5. Restore private data

Place a verified TerraSys backup directory below `backups/`, then run:

```bash
./terrasys.sh restore -BackupDirectory /opt/terrasys/app/backups/20260816-120000
```

The directory must contain `terrasys.dump`, `manifest.json`, and optional `media/`. The restore command validates file sizes and SHA256 values before replacing the new database. Keep at least one additional copy of the backup until server verification finishes.

## 6. Download and build public data on the server

The server should obtain large reproducible assets from their public upstream sources instead of copying them through a VPN. Kiwix knowledge archives, Natural Earth assets, and regional OSM sources use resumable public downloads; the overview raster uses Natural Earth's NACIS CDN:

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
./terrasys.sh build-world-overview-vector
./terrasys.sh build-osm-carto
./terrasys.sh start --no-build
```

The China snapshot and regional source downloads use resumable staging files and are activated only after format/integrity validation. If Geofabrik cannot be reached, catalog refresh preserves the checked-in snapshot. The two Korea packs use the public non-military extracts from OpenStreetMap Korea, validate the complete PBF, and record its SHA256 in the product manifest. Osmium reference counts are checked during download, pack build, and shared-source merge; the current filtered North Korea extract has an explicit finite 20,000 limit while South Korea requires zero. The first regional build also downloads Planetiler's three shared basemap archives directly from their public upstreams with resume support, verifies their ZIP structure, and inventories their SHA256 values for all later offline builds. The versioned lake-centerline release is additionally pinned to its expected byte size and SHA256 before activation.

The OSM Carto build automatically acquires its five public water, ice-sheet, and Natural Earth Shapefile archives with resume support. It validates required ZIP members and records SHA256 before import. The large water archive is reused from the already verified Planetiler cache when available.

The renderer always remains pinned to the same OCI manifest SHA256. If Docker Hub or the host's configured mirror rejects that repository, the build first retries the Overv organization's `ghcr.io` image and then uses `docker.1ms.run` as a secondary fallback. Docker must verify the identical digest before accepting the image, and the selected full reference is saved in local `services/.env`. A manually configured `OSM_CARTO_IMAGE` must retain the documented digest.

Nominatim likewise permits a registry-prefix override through `NOMINATIM_IMAGE` and rejects any mismatched manifest digest. The start command recognizes an already-local, digest-correct `docker.1ms.run` fallback image; that selection also carries through shared-index rebuilds and offline image export.

Nominatim, Valhalla, Planetiler, and OSM Carto are resource intensive. Build them sequentially on a 16 GiB host and retain ample free disk space.

## 7. Install boot startup and daily backups

```bash
sudo ./scripts/install-linux-service.sh --user "$USER" --root /opt/terrasys/app --start
systemctl status terrasys.service --no-pager
systemctl list-timers terrasys-backup.timer --no-pager
```

The installer creates a systemd application service and a persistent daily backup timer. Logs are available through:

```bash
journalctl -u terrasys.service -n 200 --no-pager
journalctl -u terrasys-backup.service -n 200 --no-pager
```

## 8. Verify and update

```bash
cd /opt/terrasys/app
./terrasys.sh health
./terrasys.sh smoke
docker compose -f services/docker-compose.yml ps
curl --fail http://127.0.0.1:8080/healthz
```

For a later application update:

```bash
cd /opt/terrasys/app
git pull --ff-only
./terrasys.sh test-suite -Profile static
sudo systemctl restart terrasys.service
./terrasys.sh health
```

Run `./terrasys.sh help` for every Linux command replacing the root Windows `.cmd` entry points.
