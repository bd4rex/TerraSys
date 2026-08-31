# Project structure

> English | [简体中文](PROJECT_STRUCTURE.zh-CN.md)

TerraSys separates version-controlled source from host-local data and renewable products. This keeps Git reviewable while allowing a deployment to retain large offline assets and private records across source upgrades.

## Stable root entry points

| Path | Responsibility |
| --- | --- |
| `README.md` / `README.zh-CN.md` | Product overview and quickest supported start |
| `start-terrasys.cmd`, `health-check.cmd`, other root `.cmd` files | Stable Windows compatibility launchers; they delegate to `scripts/*.ps1` |
| `terrasys.sh` | Unified Linux command dispatcher; it delegates to the same PowerShell scripts |
| `CHANGELOG.md` / `CHANGELOG.zh-CN.md` | User-visible unreleased and historical changes |

The root launchers intentionally remain at repository level so existing shortcuts, scheduled tasks, offline-kit instructions, and operator habits do not break. New implementation logic belongs under `scripts/`, not inside a launcher.

## Version-controlled implementation

| Directory | Responsibility |
| --- | --- |
| `.github/workflows/` | Pull-request and cross-platform repository checks |
| `config/` | Planetiler, OSM Carto, and map-build configuration |
| `docs/` | Maintained bilingual architecture, operations, deployment, and recovery documentation |
| `docs/deployment/` | Shared deployment index plus Windows and Linux host guides |
| `mcp/` | Read-only-by-default MCP adapter and its tests/documentation |
| `qgis/` | QGIS integration assets |
| `scripts/` | Cross-platform PowerShell lifecycle and data-pipeline implementation |
| `scripts/linux/` | Narrow Linux compatibility helpers used by the shared scripts |
| `services/` | Compose topology, service images/configuration, API, database migrations, and systemd templates |
| `tests/` | Static contracts, unit tests, browser tests, recovery drills, and performance baselines |
| `tools/` | Small pinned or repository-owned build helpers |
| `web/` | Browser application, local styles, fonts, sprites, and checked-in overview metadata |

## Host-local state and generated products

| Directory | Ownership and lifecycle |
| --- | --- |
| `services/.env` | Host-local secrets and active volume pointers; ignored and never shared |
| `raw/` | Downloaded source snapshots, provider state, provenance, and build inputs |
| `products/` | Verified derived maps, routing graphs, elevation, knowledge archives, and manifests |
| `data/` | Personal media/exports plus renewable caches and maintenance state |
| `backups/` | Checksum-protected personal PostGIS/media recovery points |
| `offline-kit/` | Portable disconnected recovery packages |
| `runtime/` | Test screenshots, audits, task logs, and runtime reports |
| `tmp/` | Candidate builds and disposable scratch space |

These directories contain placeholders or selected small manifests in Git only when reproducibility requires them. Private records, secrets, database dumps, downloaded PBF/ZIM files, PMTiles, Docker volume data, and transient logs must not be committed.

## Ownership rules

1. Personal PostGIS records and content-addressed media are durable user data.
2. `backups/` and verified offline kits are recovery material, not a substitute for source control.
3. Map tiles, Carto databases, Nominatim indexes, Valhalla graphs, terrain caches, and downloaded knowledge archives are replaceable products.
4. A candidate product is disposable until its manifest and service probes pass; the active version remains available during a rebuild.
5. `services/.env` is the only Compose environment file used by a deployment and must stay outside Git.
6. Windows and Linux share source and backup formats, but must not share a live Docker data directory.

## Documentation structure

- `docs/README.md` is the bilingual documentation index.
- `docs/deployment/README.md` is the platform-selection entry point.
- Architecture explains component boundaries; operations explains recurring administration; deployment guides explain host setup; rebuild explains full product generation; recovery explains disaster restoration.
- Historical design records remain clearly separated from current operational instructions.

When moving a maintained document, update both language files and every relative link in the same commit. The static repository test enforces bilingual pairs and valid local Markdown links.
