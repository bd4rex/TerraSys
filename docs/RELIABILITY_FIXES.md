# Reliability upgrade notes

> English | [简体中文](RELIABILITY_FIXES.zh-CN.md) · 2026-09-06

This change addresses the reliability findings from the September project review. It changes source code and adds regression tests; applying database migrations, rebuilding images, refreshing large offline kits, and exercising the full service stack remain deployment steps.

## Review coverage

| Review items | Fixes and regression coverage |
| --- | --- |
| 1, 2, 5: personal restore, map rollback, cancelled builds | Transactional personal restore with safety checkpoints; fully validated map candidates, operation locks, activation journals and retryable recovery. Failure injection covers publication and recovery errors. |
| 3, 6: incomplete offline kits and mismatched images | Shared file and image inventories for creation, refresh and verification; empty-directory restore, missing inputs, repeated refresh and image mismatch tests. |
| 4: blocked MCP initialization | Newline-delimited UTF-8 JSON-RPC; tests keep stdin open and exercise notifications, malformed frames and subsequent requests. |
| 7: partial GPX imports | Validate the entire file before writing in one transaction; tests reject invalid later tracks and roll back later database failures. |
| 8, 11, 12: stale frontend responses and empty map catalogs | Input changes immediately invalidate routes and saves retain their request snapshot; polling shares work for the same viewport; removing the final map clears the catalog. Tests cover delayed/reversed responses and style reloads. |
| 9, 10: incorrect distances and missed nearby places | Geography distance calculations and spatial index, plus a stored-distance migration; actual SQL regressions cover higher latitudes and the antimeridian. |
| 13, 14: ineffective AIS disablement and cache growth | On-demand connections, interruptible stop, idle leases, capacity limits and TTL/LRU eviction; tests cover requests during shutdown and concurrent cache loading. |

## Upgrade and recovery

1. Create and verify a personal backup before deploying the updated source. Restart through the normal `start-terrasys.cmd` or `./terrasys.sh start` entry point so the API image and ordered migrations are updated.
2. Migration `008_geography_distances.sql` recalculates stored track lengths using geography and adds an index for nearby-place queries. Corrected tracks receive normal version/history updates; rerunning the migration does not change already-correct rows. Reload any open track editor after migration.
3. Map builds finish and verify the base map, details and candidate manifest before publication. A short activation journal hides an incomplete commit from the API. Startup, maintenance recovery and subsequent package operations repair an interrupted commit from retained snapshots. Preserve an unresolved `<pack>.activation.json` and its private snapshot directory together.
4. Personal restore uses a transaction, a safety dump and original media under `data/restore-recovery/`. If startup reports an interrupted restore, run `pwsh -File scripts/restore-terrasys.ps1 -RecoverInterrupted` from the project to roll back that operation. Keep the journal and checkpoint until recovery succeeds. Do not manually start readers over an unresolved restore.
5. Regenerate or refresh offline kits to schema v5. `config/offline-kit.json` is the shared project/build-image inventory. A refresh that changes the required image set must also refresh the archive; `-SkipDockerImages` rejects an incompatible existing archive before changing the kit. Legacy kits remain verifiable for their recorded files, with an explicit warning that project completeness is unverified.

Offline verification reports `projectComplete` separately from `rebuildReady`. A kit made without Docker images can have complete project files while remaining `rebuildReady=false`. Full offline recovery and rebuild capability still needs the isolated recovery drill against the real archived data and images. Package copying refuses active/interrupted map mutations and rejects sources whose checksums no longer match their build manifest.

AIS no longer opens an external connection at API startup. A map request or an explicit connection test starts it; administrative disable stops it, and idle demand expires after a lease based on the configured refresh interval. No source queries are made through a disabled layer API. The in-memory live-data cache is limited to 128 entries with expiry and LRU eviction.

## Validation

Install the test dependencies from `tests/requirements.txt` in a virtual environment and run `tests/run-suite.ps1 -Profile static -PythonExecutable <venv-python>`. The profile includes temporary-directory and mocked-Docker failure injection, FastAPI transaction fixtures, standard MCP subprocesses, live-layer tests and isolated Node request-order tests.

The dedicated PostGIS CI job executes distance, nearby-query and migration checks in the empty `terrasys_reliability_test` database. These SQL tests are explicitly skipped locally without `TERRASYS_TEST_DATABASE_URL`. See the [test guide](../tests/README.md) for the browser/full/recovery profiles. Passing isolated tests does not replace validation of real containers, large maps, media and offline archives before release.
