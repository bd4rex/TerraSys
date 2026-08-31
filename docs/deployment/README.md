# Deployment guide

> English | [简体中文](README.zh-CN.md)

TerraSys supports two maintained deployment targets. Both run the same Docker Compose topology, database migrations, data products, and PowerShell implementation scripts; only the host runtime and service manager differ.

## Choose a target

| Target | Best for | Host runtime | Primary entry point | Background service | Backup scheduler |
| --- | --- | --- | --- | --- | --- |
| [Windows workstation](WINDOWS.md) | A personal desktop or laptop with local map-building tools | Docker Desktop with Linux containers and Windows PowerShell | `start-terrasys.cmd` | Docker Desktop plus the current user session | Windows Task Scheduler |
| [Linux server](LINUX.md) | An always-on trusted LAN or VPN server | Docker Engine, Compose plugin, and PowerShell 7 | `./terrasys.sh start` | `terrasys.service` | `terrasys-backup.timer` |

Choose one host method for a given working tree. Personal backups and validated offline kits are portable between the two targets, but Docker database or index volumes must not be copied while they are running.

## Shared deployment contract

Both methods use the same repository layout:

1. `services/docker-compose.yml` defines the eight-service runtime.
2. `scripts/*.ps1` contains the cross-platform lifecycle, build, verification, backup, and restore logic.
3. Root `.cmd` files are stable Windows compatibility launchers.
4. `terrasys.sh` is the unified Linux launcher.
5. `services/.env` stores host-local secrets, bind settings, and active blue-green volume pointers; it is never committed.
6. `raw/`, `products/`, `data/`, `backups/`, and `offline-kit/` contain local state and large artifacts rather than source code.

See [Project structure](../PROJECT_STRUCTURE.md) for the complete ownership and Git policy.

## Equivalent daily commands

| Action | Windows | Linux |
| --- | --- | --- |
| Start | `start-terrasys.cmd` | `./terrasys.sh start` |
| Start without rebuilding images | `start-terrasys-offline.cmd` | `./terrasys.sh start-offline` |
| Health check | `health-check.cmd` | `./terrasys.sh health` |
| API lifecycle smoke test | `smoke-test.cmd` | `./terrasys.sh smoke` |
| Personal-data backup | `backup-terrasys.cmd` | `./terrasys.sh backup` |
| Verify map packs | `region-pack.cmd Verify` | `./terrasys.sh region-pack Verify` |
| Stop | `stop-terrasys.cmd` | `./terrasys.sh stop` |

## Safe upgrade sequence

Use the same sequence on both platforms:

1. create and verify a personal-data backup;
2. make sure no data build or restore job is running;
3. fetch and fast-forward the source checkout;
4. start normally so migrations and image changes are applied;
5. run the health check and smoke test;
6. keep the previous backup until the updated installation has been used successfully.

Large generated products remain active until a staged replacement passes its own integrity checks. A source update must not require deleting healthy map, search, routing, or knowledge products.

## Network boundary

TerraSys is designed for one trusted user on localhost, a trusted LAN, or a private VPN. Set `TERRASYS_BIND_ADDRESS` to `127.0.0.1` for local-only Windows use or to one exact trusted LAN/VPN address for shared access. Do not bind it to a public interface without first adding authentication, TLS, rate limits, and a stricter upload policy.
