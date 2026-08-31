# Windows workstation deployment

> English | [简体中文](WINDOWS.zh-CN.md)
>
> Deployment index: [English](README.md) | [简体中文](README.zh-CN.md)

This guide installs TerraSys on a trusted Windows 10/11 workstation. Docker Desktop runs the Linux containers; the root `.cmd` launchers call the shared PowerShell implementation under `scripts/`.

## 1. Requirements

- 64-bit Windows 10 or Windows 11;
- Windows PowerShell 5.1 or newer;
- Git for Windows;
- Docker Desktop configured for Linux containers;
- enough free NTFS space for Docker images, regional PBF/PMTiles products, search/routing indexes, knowledge archives, backups, and candidate builds.

Keep the source checkout and Docker Desktop data on a local fixed disk. Do not place active PostGIS, Nominatim, Valhalla, or Carto data under cloud-sync software.

## 2. Clone the source

The path below is an example; the scripts resolve the repository root dynamically and do not require drive `D:`.

```powershell
git clone https://github.com/bd4rex/TerraSys.git D:\TerraSys
Set-Location D:\TerraSys
```

Do not clone private backups or generated map products into Git. Restore them through the documented backup or offline-kit workflow after the source checkout is ready.

## 3. Configure secrets and binding

Create the ignored host configuration:

```powershell
Copy-Item services\.env.example services\.env
notepad services\.env
```

Before saving:

- replace `POSTGRES_PASSWORD` and `NOMINATIM_PASSWORD` with two different random values of at least 20 characters;
- use `TERRASYS_BIND_ADDRESS=127.0.0.1` for local-only access;
- for a trusted LAN or VPN, use the workstation's exact stable address instead of `0.0.0.0`;
- keep `TERRASYS_HTTP_PORT=8080` unless that port is already reserved;
- do not commit `services/.env` or paste it into issue reports.

If `services/.env` is absent, the normal start script creates random database passwords automatically. An explicitly prepared file is preferred because it also forces the network binding decision before the first container starts.

## 4. First start

Start Docker Desktop and wait until its engine reports ready, then run:

```powershell
.\start-terrasys.cmd
.\health-check.cmd
```

The start command:

1. verifies Docker;
2. creates missing bind-mount directories;
3. validates local secrets and pinned runtime images;
4. starts PostGIS and applies ordered migrations;
5. builds or reuses the API image;
6. starts the core stack and any already-prepared advanced services;
7. starts the allowlisted maintenance worker.

Open `http://127.0.0.1:8080/` for a local-only installation, or the exact configured LAN/VPN address. Only nginx publishes the host port; the database and engines remain internal to Docker.

## 5. Restore personal data

Place one verified TerraSys backup directory under `backups/`, then run:

```powershell
.\restore-terrasys.cmd -BackupDirectory .\backups\<backup-id>
.\health-check.cmd
.\smoke-test.cmd
```

The backup directory must contain `terrasys.dump` and `manifest.json`; it may also contain `media/`. Keep an independent copy until the restored installation passes both checks.

## 6. Prepare offline capabilities

The core stack can run before large map and knowledge products are present. Prepare the advanced stack when storage and time are available:

```powershell
.\prepare-advanced.cmd
.\region-pack.cmd List
.\region-pack.cmd Verify
```

Run heavy builds serially on a 16 GiB machine. Candidate products do not replace active products until their format, size, checksum, coverage, and service probes pass.

See [Rebuild from scratch](../REBUILD.md) for the full data-build order and [Data pipeline](../DATA_PIPELINE.md) for product ownership.

## 7. Install daily backups

Create a checksum-verified backup manually first:

```powershell
.\backup-terrasys.cmd
```

Then register the current user task:

```powershell
.\install-backup-task.cmd -DailyAt "03:00"
Get-ScheduledTask -TaskName "TerraSys Daily Personal Backup"
```

The task uses the current user with limited privileges and starts when possible after a missed schedule. For disaster recovery, pass `-MirrorRoot` to a separate physical disk or protected network path and verify that destination regularly.

## 8. Acceptance checks

Run after installation, restore, or upgrade:

```powershell
.\health-check.cmd
.\smoke-test.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-suite.ps1 -Profile static
```

For a development workstation with the Playwright image and live services prepared, also run the `browser` or `full` test profile described in [Test suite](../../tests/README.md).

## 9. Upgrade

```powershell
.\backup-terrasys.cmd
git status --short
git pull --ff-only
.\start-terrasys.cmd
.\health-check.cmd
.\smoke-test.cmd
```

Stop and investigate instead of pulling if `git status --short` shows unknown source-code edits. Local data and generated products are intentionally ignored; do not delete them to make Git appear clean.

## 10. Stop or start without rebuilding

```powershell
.\stop-terrasys.cmd
.\start-terrasys-offline.cmd
```

The offline start reuses validated local images and products. It does not turn an incomplete download or candidate build into an installed product.
