# Full-capability rebuild playbook for a weaker model

> English | [简体中文](AI_REBUILD_EXECUTION_PLAN.zh-CN.md)
>
> Documentation snapshot: `2026-08-07T14:04:59+08:00`

This playbook is for rebuilding every observable TerraSys capability in an empty repository with a model that is materially less capable than the current development model. The target is equivalent behavior, data contracts, offline operation, recovery, and operational experience; line-for-line implementation parity is not required.

Do not send this entire document to the model as one large request. Send the fixed system prompt first, followed by exactly one work-package prompt. Move to the next package only after the current package passes its tests and has a Git checkpoint.

## 1. Definition of success

The rebuild is complete only when all of these conditions hold:

1. Only `http://127.0.0.1:8080` is exposed to the host. PostGIS, Martin, FastAPI, Nominatim, Valhalla, Kiwix, and OSM Carto communicate only on the container network.
2. Once local resources are prepared, maps, personal data, search, routing, terrain, weather, nautical references, knowledge, backup, and recovery work without internet access.
3. Personal PostGIS records and content-addressed media are authoritative. Maps, indexes, weather snapshots, and caches are rebuildable products.
4. Every derived product follows “stage → verify → activate → retain rollback.” Failure or cancellation never replaces the active version.
5. The browser can submit only fixed resource IDs and allowlisted actions. It cannot run arbitrary commands or access the database directly.
6. Regional catalogs, manifests, APIs, database migrations, resource states, and error semantics remain stable.
7. All four test profiles—`static`, `browser`, `full`, and `recovery`—pass with auditable evidence.
8. English and Chinese documentation remains paired and cross-linked, with identical commands, paths, versions, and timestamps.

## 2. Rebuild scope

| Capability area | Required capabilities |
| --- | --- |
| Local entry point | Single nginx entry point, static assets, API/Martin/Kiwix/Carto proxies, PMTiles HTTP Range 206 |
| Maps | MapLibre, OSM Carto, regional PMTiles, Natural Earth world overview, online reference providers, deterministic fallback |
| Catalogs and packs | 34 Chinese provincial units, more than 550 Geofabrik units, manifests, verification, enable/disable, update, rebuild, rollback, protected removal |
| Personal data | Places, tracks, collections, notes, tags, ratings, optimistic versions, audit history, and read-only Martin views |
| Import/export | GPX import, GeoJSON/GPX/ZIP export, SHA256 media, ownership, and orphan cleanup |
| Search | Unified personal-data, lightweight OSM reference, Nominatim geocoding, and reverse-geocoding search |
| Routing and terrain | Valhalla driving/cycling/walking, elevation profiles, HGT sampling, Terrarium, browser contours |
| Environment and knowledge | Weather, nautical references, emergency facilities, Chinese Wikipedia and Wikivoyage |
| Resource management | Stale-while-refresh inventory, storage classification, versions/sources, update checks, allowlisted jobs, real progress, cancellation, retry |
| Operations and recovery | Idempotent startup, migrations, health checks, personal backup, full offline kit, SHA256 verification, isolated recovery drill |
| Quality | Static contracts, API lifecycle, Playwright, performance baselines, fault injection, security boundaries, bilingual documentation |

The current authoritative references are [Architecture](ARCHITECTURE.md), [Configuration](CONFIGURATION.md), [Data pipeline](DATA_PIPELINE.md), [Operations](OPERATIONS.md), [Rebuild](REBUILD.md), and the [test suite](../tests/README.md).

## 3. Constraints for a weaker model

These controls compensate for weaker long-context reasoning, cross-file consistency, and failure recovery.

### 3.1 One atomic task per turn

- Change no more than eight files per turn; split the task if it needs more.
- Add only one migration, one API capability group, one UI flow, or one operational action per turn.
- Never refactor, add a feature, and update dependencies in the same turn.
- Read relevant files before proposing changes. Never claim that something exists or passed without evidence.
- Run the target test and the smallest relevant regression suite at the end of every turn.

### 3.2 Fixed context packet

Each turn receives only:

1. `PROJECT_CONTRACT.md`: architecture and security invariants;
2. `REBUILD_STATUS.md`: completed, current, blocked, and latest test state;
3. three to eight source files named by the current work package;
4. the corresponding tests and complete failure logs;
5. explicit inputs, outputs, prohibitions, and acceptance commands.

The model must not depend on unprovided chat history. At the end of each turn, use the handoff prompt to compress verified state into `REBUILD_STATUS.md`.

### 3.3 Evidence first

Completion requires a file diff, command exit codes, structured test output, HTTP responses, database queries, screenshots, or a recovery audit. A plausible UI, a running container, or the model's claim is not acceptance evidence.

### 3.4 Two-model or two-pass review

If the platform has only one weaker model, run at least two separate passes for each work package:

1. implementation pass: implement only the accepted scope;
2. review pass: start with fresh context and inspect the diff and tests against the contract.

The reviewer must inspect actual files and test output instead of accepting the implementation summary.

## 4. Fixed prompts

### 4.1 Executor system prompt

Paste this before every work package:

```text
You are the implementation engineer for the TerraSys rebuild. Your capability is limited, so you must work through small changes, explicit contracts, and automated tests.

Global rules:
1. Read the files and logs I name, then propose a plan of no more than seven steps.
2. Complete only one work package in this turn. Do not opportunistically refactor other areas.
3. Preserve existing behavior and user changes. Never reset, overwrite, or delete work outside this package.
4. Every data replacement must use “stage, verify, atomically activate, retain rollback.” Failure or cancellation cannot change the active version.
5. Personal PostGIS data and content-addressed media are authoritative; maps and indexes are rebuildable products.
6. The browser cannot hold database credentials or submit arbitrary host commands.
7. Only nginx may bind 127.0.0.1:8080. Do not expand network exposure.
8. All coordinates use WGS84 longitude/latitude. Never swap latitude and longitude.
9. Never fabricate tests, progress, hashes, transfer rates, or service state.
10. Run the specified acceptance commands after editing. When a test fails, find the cause; never delete assertions to obtain a green result.

Your final response must contain exactly:
- Outcome: complete or incomplete;
- Changed files: one explanation per file;
- Contract decisions: invariants preserved in this turn;
- Tests: commands, exit codes, and key output;
- Remaining risks: anything not verified;
- Next context: only the files needed for the next turn.
```

### 4.2 Reviewer prompt

```text
You are an independent reviewer. Do not trust the implementer's summary; inspect the actual diff, relevant source files, tests, and logs.

Tasks:
1. Map each acceptance criterion to its implementation location and test evidence.
2. Look for silent degradation, hard-coded regions, fake progress, missing rollback, path traversal, coordinate reversal, temporary-data leaks, public ports, and documentation drift.
3. Report only defects tied to a file and behavior, ordered P0/P1/P2.
4. If there are no blockers, explicitly list remaining untested risks instead of saying only “looks good.”
5. Do not modify code. Return the smallest fix and the regression assertion that should be added.
```

### 4.3 Failure-repair prompt

```text
Acceptance for the current work package failed. Fix only this failure and do not expand the feature scope.

Inputs include the failing command, complete error, latest diff, related source files, and expected contract.
First return the three most likely root causes, the smallest read-only check that distinguishes them, and the check results.
After confirming the root cause, implement the smallest fix, preserve the last usable version, and rerun the failing test plus its preceding regression layer.
Do not relax assertions, add arbitrary sleeps, swallow exceptions, return fixed success values, or skip tests.
```

### 4.4 Phase handoff prompt

```text
Produce an update of no more than 120 lines for REBUILD_STATUS.md. Record only verifiable facts:
- current commit and working-tree state;
- completed work packages and evidence;
- incomplete work packages;
- known risks and failures;
- active and rollback data versions;
- no more than eight files needed by the next package;
- the single next acceptance command.
Do not copy chat history, do not speculate, and do not equate “container running” with “feature passed.”
```

## 5. Phase plan and step-by-step prompts

The plan has 9 phases (Phase 0–8) and 24 work packages. Create a Git checkpoint after every package. Do not advance while a phase gate is failing.

### Phase 0: freeze the baseline and build the capability ledger

#### WP-00 Establish the observable baseline

Goal: make the reference project a verifiable source of requirements rather than relying on memory.

```text
Work package WP-00: establish the TerraSys capability baseline without changing product code.

Read README, ARCHITECTURE, CONFIGURATION, DATA_PIPELINE, OPERATIONS, REBUILD, the tests directory, Compose, and FastAPI routes.
Produce:
1. PROJECT_CONTRACT.md with network, data ownership, version-switching, coordinate, resource-coverage, and security invariants;
2. CAPABILITY_MATRIX.md with each capability, user entry point, API/script, persistent data, dependent service, failure fallback, and existing test;
3. API_BASELINE.json with method, path, success status, important fields, and representative errors;
4. REBUILD_STATUS.md with every work item initially marked not started.

Do not copy secrets, machine-specific data, or large derived products. Mark unobservable behavior as unknown instead of guessing.
Acceptance: every capability maps to at least one entry point and test plan; JSON parses; relative documentation links resolve.
```

#### WP-01 Capture golden samples

```text
Work package WP-01: capture minimum golden samples from the running reference system; implement nothing.

Save normalized contract samples for /api/health, /api/status, /api/capabilities, /api/map-packs, /api/resources, personal-data CRUD, search, route, elevation, weather, and nautical APIs. Capture PMTiles Range 206 headers, the Martin catalog, the migration list, and four key UI screenshots. Remove timestamps and random IDs from contract fixtures.

Use test-only personal records, delete them at the end, and confirm counts return to baseline. Never export real personal data or secrets.
Produce GOLDEN_SAMPLES.md, sanitized JSON fixtures, and collection commands. Record capture time, reference commit, and normalization rules for every sample.
```

Gate G0: no capability or entry point is unclassified; golden samples can be collected repeatedly; reference-system data counts are unchanged.

### Phase 1: repository skeleton, CI, and runtime boundary

#### WP-02 Create the repository skeleton

```text
Work package WP-02: create the minimum testable repository skeleton.

Create config, services, scripts, web, tests, docs, and .github/workflows. Add bilingual READMEs, license/source placeholders, .gitignore, and a secret-free services/.env.example. Create a static test entry point that validates JSON/YAML, PowerShell syntax, bilingual documentation pairs, relative links, test-catalog integrity, and browser-image test inputs.

Do not add business implementations, real passwords, downloaded data, or empty tests that always pass.
Acceptance: static runs in the business-empty repository; deliberately breaking one JSON makes it fail, and restoring the JSON makes it pass.
```

#### WP-03 Establish Compose and the single entry point

```text
Work package WP-03: implement the eight-service Compose topology and single nginx entry point.

Service names: web, api, postgis, martin, nominatim, valhalla, kiwix, osm-carto. Pin third-party images by digest. Only web/nginx publishes 127.0.0.1:8080. Configure internal DNS, health checks, read-only mounts, and named volumes. nginx routes /, /api/, /martin/, /wiki/, /carto/, and /tiles/, rejects dotfiles, and supports PMTiles Range requests.

Do not implement business APIs. Minimal health placeholder containers are allowed for topology verification but must be removed after WP-04.
Acceptance: docker compose config succeeds; host scanning sees only 127.0.0.1:8080; internal services publish no host ports.
```

#### WP-04 Add secrets, startup, and migration entry points

```text
Work package WP-04: implement idempotent startup, shutdown, local secrets, and migration entry points.

When services/.env is absent, create independent random 32-byte POSTGRES_PASSWORD and NOMINATIM_PASSWORD values; never overwrite an existing file. start-terrasys starts PostGIS, waits for health, synchronizes the role password, runs ordered migrations, and starts core services. stop-terrasys can run repeatedly. Every native PowerShell command must check its exit code.

Acceptance: starting twice does not change passwords, duplicate migrations, or lose data; stopping twice causes no destructive error; Git does not track .env.
```

Gate G1: `static` passes; Compose parses; there is one loopback entry point; repeated startup preserves the same database and secrets.

### Phase 2: authoritative personal data and API foundation

#### WP-05 Add database migrations and published views

```text
Work package WP-05: implement replayable PostGIS migrations.

Create app.places, app.tracks, app.media, app.change_log, app.reference_places, app.dataset_state, app.collections, app.place_collections, app.places_web, and app.tracks_web in order. Add PostGIS, pg_trgm, GiST/GIN indexes, update-time triggers, row-level change capture, and a migration registry.

Migrations must be idempotent and run with ON_ERROR_STOP. Never drop/recreate existing data during an upgrade. Martin may publish only the two approved views.
Acceptance: clean migration, repeated migration, and upgrade from the prior migration all pass; system and private tables do not appear in the Martin catalog.
```

#### WP-06 Establish the FastAPI contract

```text
Work package WP-06: implement FastAPI foundations, connection pooling, and consistent errors.

Implement only /health, /status, and /capabilities. Use pinned dependencies, parameterized SQL, a connection pool, and explicit timeouts. Health responses distinguish API liveness, database availability, and optional capability readiness. An uninstalled advanced resource is not an API failure; an exception cannot be swallowed as HTTP 200.

Acceptance: fixtures for healthy database, unavailable database, and unprepared optional capability return contract-matching states; logs contain no password or connection string.
```

#### WP-07 Implement places, tracks, and collections

```text
Work package WP-07: implement the complete personal place, track, and collection lifecycle.

Implement place/track GeoJSON queries, create/update/delete for places and tracks, collection CRUD, and collection membership. Coordinates are WGS84 longitude/latitude. Updates use a version-based optimistic lock and reject stale versions. Every write enters change_log. Search initially covers personal places and tracks.

Write a failing API test before each endpoint group. Tests use a unique prefix and clean up in finally.
Acceptance: CRUD, spatial query, collection membership, version conflict, invalid geometry, and return-to-baseline cleanup all pass.
```

#### WP-08 Add media, import, and export

```text
Work package WP-08: implement media, GPX import, and portable exports.

Limit images to 64 MB, decode before acceptance, and store by SHA256. Multiple metadata records may share a physical file; remove it only when its final owner is deleted. Parse GPX with a safe XML parser. Provide per-track GPX, all-track GPX, GeoJSON, and ZIP export with a manifest and SHA256 entries.

Reject path traversal, ZIP slip, disguised images, oversized files, and external XML entities. Failed uploads leave no temporary file.
Acceptance: duplicate media, two owners, orphan cleanup, malicious inputs, export contents, and SHA256 all have automated tests.
```

Gate G2: personal-data lifecycle passes; migrations replay; Martin's allowlist is correct; test records and files leave zero residue.

### Phase 3: map catalogs, regional products, and browser map

#### WP-09 Define catalog and manifest contracts

```text
Work package WP-09: implement regional catalogs and the map-pack state machine.

Create the 34-unit Chinese provincial catalog, global Geofabrik hierarchy, render configuration, and resource catalog. Define stable resourceId, bounds, source, members, and build estimates. A map is installed only when PMTiles and its manifest both exist and satisfy byte, header, and metadata policy.

Implement available, staged, installed, disabled, update-available, rollback, and invalid states. File existence or a healthy container alone cannot imply readiness.
Acceptance: catalog counts, unique IDs, parent/child integrity, Taiwan Province display normalization, missing manifest, byte drift, and invalid PMTiles fixtures are asserted.
```

#### WP-10 Implement regional build and atomic activation

```text
Work package WP-10: implement the regional PBF-to-PMTiles pipeline.

Download to a staged path and validate. Extract mainland provinces by .poly from one authoritative China snapshot to avoid conflicting object versions. Use a pinned Planetiler build for base OpenMapTiles and high-detail POIs. The manifest records source sequence/time, members, bounds, input/output SHA256, tools, and build time.

Atomically activate only after staged verification and retain .previous. Cancellation, insufficient space, checksum failure, or build failure must preserve the active version.
Acceptance: Plan has no side effects; Build, Verify, Update, Rebuild, Rollback, Enable/Disable, and token-protected Remove have state-machine tests.
```

#### WP-11 Build the world overview and PMTiles transport

```text
Work package WP-11: implement the local z0-7 world overview and PMTiles Range service.

Use Natural Earth 110m/50m/10m to build a world PMTiles archive containing land, water, country/province borders, cities, major roads, railways, and rivers. Build to staged, validate the header and minimum size before activation, and store SHA256 in the manifest. nginx must return correct 206, Content-Range, and cache validators for every PMTiles archive.

Acceptance: random beginning/middle/end Range requests are correct; an updated archive never reuses stale PMTiles bytes; the world remains browsable with no regional pack.
```

#### WP-12 Build the MapLibre map shell

```text
Work package WP-12: implement source switching and deterministic fallback on the main map.

Provide local Carto, regional PMTiles, world overview, OSM Standard, and OpenFreeMap. Load multiple installed regions together; a regional shortcut changes only the camera. Online providers are contacted only after explicit user selection and only for the current viewport. Failure falls back through the alternate online provider to the local overview. Source changes must not reconstruct the full MapLibre instance.

Implement coverage checks that avoid coastal, ocean, antimeridian, and low-zoom false installation prompts. Hide automatic suggestions below z8 by default.
Acceptance: Playwright checks all five sources, provider failure, viewport movement, cross-region, coast, and antimeridian cases with no unexpected console or network failures.
```

Gate G3: three installed test regions browse together; low-zoom world coverage has no blank map; Range 206 and failure fallback tests pass.

### Phase 4: search, routing, terrain, environment, and knowledge

#### WP-13 Add lightweight search and Nominatim

```text
Work package WP-13: implement unified search, geocoding, and reverse geocoding.

Export named OSM nodes from the shared capability PBF, transactionally replace app.reference_places, and store source scope and SHA256 in app.dataset_state. /search merges personal places, tracks, lightweight references, and Nominatim with personal results first. /geocode and /reverse use timeouts and distinguish not-ready, timeout, no-result, and success.

Build Nominatim in a candidate volume. Switch only after database integrity, search, and reverse checks; retain the previous volume.
Acceptance: Chinese/English names, empty input, special characters, timeout, candidate failure, representative points in every enabled region, and scope hashes are tested.
```

#### WP-14 Add Valhalla, elevation, and terrain

```text
Work package WP-14: implement routing and a unified elevation source.

Build a candidate Valhalla product from the same shared PBF as search. Support driving, cycling, and walking, returning geometry, distance, duration, and an elevation profile. HGT supplies Valhalla, point/route sampling, Terrarium tiles, and browser contours.

Serialize Valhalla and Nominatim builds on a 16 GiB host. Every enabled region needs a real short-route probe. Missing any region marks the capability stale/blocked; service health alone is insufficient.
Acceptance: three travel modes, routes outside coverage, damaged HGT, candidate failure, elevation range, and Terrarium PNG decoding pass.
```

#### WP-15 Add weather, nautical, emergency, and Kiwix

```text
Work package WP-15: implement lightweight derived resources and local knowledge.

Weather and nautical manifests record every enabled region ID and source SHA256. A regional-scope change automatically queues lightweight synchronization. Emergency facilities come from the lightweight reference index. Kiwix serves Chinese Wikipedia and Wikivoyage under same-origin /wiki/ and must never silently use the internet. Large knowledge downloads support resume and atomic installation after exact SHA256 verification.

Acceptance: freshness changes correctly after adding/disabling a region; a missing region cannot appear fully ready; Kiwix search and article viewing work offline; interrupted downloads preserve the old version.
```

#### WP-16 Add local OSM Carto

```text
Work package WP-16: implement the default OSM Carto raster renderer.

Create a shared Carto PBF from every installed and enabled region. Import a candidate database with osm2pgsql and local water, ice, and Natural Earth external datasets. Switch candidate Mapnik/mod_tile only after it renders a non-empty test tile for every region. Include the database volume and tile cache in recovery policy.

Acceptance: active Carto remains available during a build; every regional tile exceeds the blank threshold; candidate failure never switches; the source manifest exactly matches enabled regions.
```

Gate G4: unified search, geocode/reverse, three routing modes, elevation, weather, nautical, emergency, knowledge, and Carto all pass per-region semantic checks.

### Phase 5: resource lifecycle and maintenance jobs

#### WP-17 Implement inventory and classification

```text
Work package WP-17: implement resource inventory, storage classification, and stale-while-refresh behavior.

Cover maps, OSM sources, search, routing, elevation, knowledge, web assets, Carto, backups, PostGIS, media, and caches. Each item returns stable resourceType, storageClass, scope, validationPolicy, status, bytes, version, source, and freshness.

GET /resources returns the last complete snapshot first and starts one lock-protected background refresh; ?cached=true never scans; ?check_upstream=true is the only form that checks trusted upstreams. Measure Docker volumes separately from host paths. Refresh failure cannot remove the last readable snapshot.
Acceptance: 20 concurrent requests start one scan; slow disks do not hide maintenance state; damaged cache falls back safely; fixture totals match classifications.
```

#### WP-18 Add the allowlisted job queue and real progress

```text
Work package WP-18: implement the host maintenance job queue.

The browser submits only fixed resourceId/action pairs. The API validates them and writes a persistent JSON job; one worker runs allowlisted scripts. Implement queued/running/succeeded/failed/cancelled, queue position, heartbeat, phase, measurable byte/tile/feature rates, cancellation, and explicit retry. Show only processing when progress is not measurable.

Recover queue state after worker restart, but never automatically retry a failed shared-index build. Reject paths, commands, argument injection, and concurrent heavy jobs.
Acceptance: malicious actions, unknown IDs, duplicate submission, cancellation race, worker crash, log truncation, and restart recovery are tested.
```

#### WP-19 Build the resource console

```text
Work package WP-19: implement the resource and version management page.

Provide Available, Local, and Updates views; global catalog hierarchy and search; per-row status, source, version, storage, freshness, valid actions, and independent task state. A persistent task rail cannot replace the browsing workspace. Poll maintenance state independently instead of rescanning all resources for task updates.

Every destructive action requires an explicit resource ID or confirmation token. Browser tests intercept write requests and never perform a real deletion or rebuild.
Acceptance: API row counts, catalog search, overflow-free layout, task progress/cancel/retry, protected actions, and narrow screens pass.
```

Gate G5: resource status matches actual files and volumes; concurrent inventory and job recovery work; the UI shows neither fake progress nor unauthorized actions.

### Phase 6: complete UX and localization

#### WP-20 Complete the main application workflow

```text
Work package WP-20: finish the main-map user workflow.

Implement unified search, details, saving reference features, place/track editing, collections, layers, routing, terrain/contours, weather, nautical, emergency, knowledge entry points, legend, attribution, and responsive sidebar. Keyboard, focus, collapsed-sidebar, and narrow-screen use must work.

Chinese display normalization covers package names, prompts, feature details, and every world-overview label layer; Taiwan is displayed consistently as 台湾省. Never change source OSM IDs or write display-name normalization back into authoritative data.
Acceptance: main UI, world map, and resource-console Playwright suites pass; screenshots receive visual review; there are no unexpected console or network errors.
```

Gate G6: key workflows complete on desktop and narrow screens; offline content remains visible after online failure; bilingual and Chinese display normalization is consistent.

### Phase 7: backup, recovery, and offline disaster recovery

#### WP-21 Implement personal backup and restore

```text
Work package WP-21: implement personal-data backup, retention, and restore.

A backup contains a PostGIS dump, media, and a SHA256 manifest, with 14 retained by default. It may mirror to a second physical disk; reject same-disk mirrors. A restore path must be inside the backup root. Verify everything before stopping API/Martin, cleanly restoring, applying migrations, copying media, and restarting.

Acceptance: normal restore, modified file, missing media, path traversal, same-disk mirror, old-schema upgrade, and post-restore count/hash tests pass. A verification failure never overwrites the current database.
```

#### WP-22 Build the full offline kit and isolated drill

```text
Work package WP-22: implement a full offline kit and a real disconnected recovery drill.

The kit includes the application, maps and sources, shared PBF, routing, elevation, knowledge, overview, weather, nautical data, Carto, Nominatim/Carto snapshots, personal backup, pinned images, and build-tool caches. The manifest records path, size, and SHA256. verification.json is not included in its own manifest.

Restore on a Docker --internal network and verify the database, map Range requests, Martin, search, routing, elevation, Kiwix, personal data, and exports. Remove temporary containers, volumes, and network afterward; retain a runtime/recovery-audit JSON report.
Acceptance: the recovery profile passes with network or DNS blocked; changing one byte makes verification fail before restoration starts.
```

Gate G7: the latest personal backup restores; the latest full kit verifies; the isolated drill passes and leaks no temporary resources.

### Phase 8: performance, fault, and security hardening

#### WP-23 Validate the release candidate

```text
Work package WP-23: validate the release candidate without adding product features.

Run static, browser, full, and recovery. Run API contract diff, migration replay, port exposure, secret scanning, path traversal, upload abuse, command allowlist, candidate-switch failure injection, network outage, and disk-space preflight checks. Measure performance in at least three fresh browser contexts, use the median as baseline, and keep guardrails comfortably wider than normal variance.

Produce RELEASE_EVIDENCE.md with commit hash, environment, commands, exit codes, duration, screenshots, performance median, recovery audit, known limitations, and rollback steps. Any P0/P1 issue or unexplained flaky test blocks release.
```

Gate G8: all automation is green; evidence reproduces from a clean environment; there are no secrets, public internal ports, or undocumented migration risks.

## 6. Test projects

### 6.1 Existing test layers that must be retained

| Layer | Required coverage | Entry point | Release use |
| --- | --- | --- | --- |
| `static` | JSON/YAML, PowerShell, bilingual docs, links, catalog, browser image inputs | `tests/run-suite.ps1 -Profile static` | Every commit |
| `browser` | Health, main UI, resource page, world map, performance | `tests/run-suite.ps1 -Profile browser` | UI/map changes |
| `full` | browser + API, resource, and personal-data lifecycle | `tests/run-suite.ps1 -Profile full` | Runtime changes and release candidate |
| `recovery` | full + isolated offline recovery | `tests/run-suite.ps1 -Profile recovery` | Recovery changes and release |

Existing cases `TC-STATIC-001` through `TC-RECOVERY-002` are the minimum compatibility baseline. Never lower it by deleting assertions.

### 6.2 Tests required specifically for a rebuild

| ID | Test project | Key assertions |
| --- | --- | --- |
| RT-UNIT-001 | Catalog and manifest units | Unique IDs, complete hierarchy, byte/hash/state derivation, Taiwan Province display |
| RT-UNIT-002 | Coordinates and geometry | Longitude/latitude order, ranges, empty geometry, multiline, antimeridian, boundary inclusion |
| RT-UNIT-003 | Optimistic lock and audit | Stale-version conflict, version increment, complete change_log |
| RT-UNIT-004 | Media lifecycle | SHA256 deduplication, multiple owners, final-owner deletion, no failed-upload residue |
| RT-UNIT-005 | Maintenance allowlist | Unknown action, command/argument injection, path traversal, duplicate jobs rejected |
| RT-CONTRACT-001 | OpenAPI/error snapshot | Methods, paths, fields, status codes, and error shapes match baseline |
| RT-CONTRACT-002 | Migration matrix | Empty database, every historical version, replay, interrupted recovery |
| RT-CONTRACT-003 | Resource freshness | Enabled scope exactly matches Carto/search/route/elevation/weather/nautical provenance |
| RT-INTEG-001 | PMTiles HTTP Range | Beginning/middle/end 206, Content-Range, cache version, invalid range |
| RT-INTEG-002 | Candidate activation failure | Download/build/verify/switch failure preserves active version |
| RT-INTEG-003 | Worker persistence | Crash, restart, cancel race, no automatic failed-job retry, correlated logs |
| RT-INTEG-004 | Partial service failure | Explicit API/UI degradation when Nominatim, Valhalla, Kiwix, or Carto is unavailable |
| RT-UI-001 | Core user journey | Search → details → save → edit → collection → export → delete |
| RT-UI-002 | Map source and coverage | Five sources, online failure, coast, ocean, low zoom, antimeridian, cross-region |
| RT-UI-003 | Accessibility and responsive UI | Keyboard, focus, collapsed sidebar, desktop and narrow screen without overflow |
| RT-PERF-001 | First interaction | One map-packs request; three-run median for DOM, canvas, and system-ready |
| RT-PERF-002 | API and I/O | Cached inventory, random PMTiles Range, search and tile latency percentiles |
| RT-LOAD-001 | Concurrent reads | 20 resource requests trigger one scan; browsing does not block job status |
| RT-FAULT-001 | Network outage | Local capability and active products survive provider, upstream, and DNS failure |
| RT-FAULT-002 | Insufficient disk | Preflight check; failed staged write does not damage active product |
| RT-SEC-001 | Network exposure | Only 127.0.0.1:8080; no host database or engine ports |
| RT-SEC-002 | Input and file safety | Parameterized SQL; XXE, ZIP slip, traversal, disguised image, oversized upload rejected |
| RT-SEC-003 | Supply chain and secrets | Image digests, pinned dependencies, no Git secrets, no credentials in logs |
| RT-REC-001 | Personal restore | Counts, geometry, media, and export hashes match before and after restore |
| RT-REC-002 | Full disconnected restore | Every offline capability works on an internal network; temporary resources cleaned |
| RT-DOC-001 | Executable documentation | Paired languages, valid links, and commands/paths/ports/versions matching implementation |

### 6.3 Test-data matrix

Minimum fixtures include:

- regions: Jiangsu, Anhui, Shandong, plus one uninstalled region;
- global locations: Japan, United States, Taiwan Province, offshore coast, open ocean, and both sides of the antimeridian;
- text: Simplified Chinese, English, mixed language, emoji, quotes, wildcard characters, and whitespace;
- geometry: point, short track, multiline track, boundary point, invalid longitude/latitude, and empty geometry;
- media: valid JPEG/PNG, identical content under different names, damaged image, oversized file, and two owners;
- services: all ready, one service down, stale data, one enabled region missing, and only surplus old coverage;
- products: current, previous, staged, damaged manifest, byte drift, and checksum failure;
- recovery: valid kit, missing file, extra file, traversal path, size change, and one-byte modification.

Fixtures must never contain real personal data. They must be reproducible and cleaned in `finally`.

### 6.4 Performance and I/O acceptance guidance

Do not copy absolute timings from another machine. Establish the target baseline with three fresh browser contexts and at least 30 API/Range requests, recording medians and p95. Then apply these relative limits:

- startup `map-packs` request count equals one;
- DOM, canvas, and system-ready medians regress no more than 25% from the approved baseline;
- p95 latency for random 1 MiB PMTiles Range reads regresses no more than 30%;
- cached inventory p95 is not blocked by a full disk scan;
- maintenance status still returns within its polling interval during concurrent browsing;
- Valhalla and Nominatim builds are serialized on a 16 GiB host and do not “pass” by exhausting swap.

Write machine-specific absolute guardrails into `tests/performance-baseline.json` only after measurement. Record disk type, available memory, Docker version, data size, and test time.

## 7. Per-package acceptance checklist

The executor answers yes/no and attaches evidence for every item:

1. Did this turn complete only one work package?
2. Were the relevant contract and current implementation read first?
3. Were unrelated uncommitted user changes preserved?
4. Is there a minimal failing test or contract fixture?
5. Were the target test and preceding regression layer run?
6. Were exit codes checked instead of only reading output text?
7. Is stage/verify/activate/rollback protection present where needed?
8. Did network exposure, secrets, data model, or deletion semantics change? If so, was there dedicated review?
9. Were bilingual docs and the test catalog updated?
10. Are unverified risks recorded?

If any critical answer is no, the package status is incomplete.

## 8. Milestones and model allocation

| Milestone | Work packages | Suggested checkpoint | Parallelism |
| --- | --- | --- | --- |
| M0 Requirements frozen | WP-00–01 | Capability ledger, golden samples | Sequential |
| M1 Bootable core | WP-02–04 | static, single entry, idempotent startup | Limited after WP-02 |
| M2 Personal-data MVP | WP-05–08 | API lifecycle, export/recovery | Database first, then sequential |
| M3 Map MVP | WP-09–12 | PMTiles, world overview, map UI | WP-11 can validate late in WP-10 |
| M4 Advanced offline | WP-13–16 | Search, route, terrain, environment, Carto | Builds sequential; code reviews independent |
| M5 Resource platform | WP-17–20 | Inventory, jobs, both UIs | UI after API contracts stabilize |
| M6 Disaster recovery | WP-21–22 | Backup and isolated recovery | Sequential |
| M7 Release | WP-23 | Complete evidence and rollback | Tests grouped; final gate sequential |

For a weaker model, use one implementation pass, one independent review pass, and at most two targeted repair passes per work package. If two repairs still fail, stop accumulating patches. Return to the latest green checkpoint, shrink the task, or add a fixture.

## 9. Final release decision

Declare “all capabilities rebuilt” only when every item has evidence:

- every capability-matrix row has an implementation location and automated test;
- the API baseline has no unapproved deletion or semantic change;
- the database migrates from both an empty database and historical backups;
- every enabled region appears in map provenance and all six derived capability manifests;
- all five map sources and offline fallback pass browser tests;
- personal data, media, and exports leave no test residue;
- performance results come from at least three reproducible measurements;
- both a personal backup and full offline kit have actually been restored;
- the `recovery` profile passes on an internal network;
- release evidence records commit hash, timestamp, environment, known limitations, and rollback.

If any item has only a narrative claim and no inspectable evidence, report “capability implemented, release validation incomplete,” not “fully complete.”
