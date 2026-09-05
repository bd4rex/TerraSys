# TerraSys test suite

> English | [简体中文](README.zh-CN.md)

This suite turns regressions found during the project's iterative development into a single reusable workflow. The machine-readable catalog is [`test-cases.json`](test-cases.json), and [`run-suite.ps1`](run-suite.ps1) is the automation entry point.

## Execution profiles

| Profile | When to use it | Coverage | Typical cost and dependencies |
| --- | --- | --- | --- |
| `static` | Every commit and GitHub PR | Repository contracts plus MCP, API transactions, frontend requests, cache, offline-kit and recovery failure regressions | Typically under a minute; Python test dependencies, Node.js and PowerShell 7; no running services |
| `browser` | UI, map, or resource-console changes | `static`, health, main UI, resource console, world map, and performance regressions | Requires Docker and the running eight-service stack |
| `full` | API, resource lifecycle, data-model changes, or pre-release | `browser` plus the complete API and personal-data lifecycle | Creates temporary personal records and media; the script cleans them in `finally` |
| `recovery` | Backup, recovery, image, or migration changes | `full` plus an isolated offline-kit recovery drill | Highest cost; requires a complete generated offline kit |

Run these commands from the project directory:

```powershell
pwsh -NoProfile -File ./tests/run-suite.ps1 -Profile static
pwsh -NoProfile -File ./tests/run-suite.ps1 -Profile browser
pwsh -NoProfile -File ./tests/run-suite.ps1 -Profile full
pwsh -NoProfile -File ./tests/run-suite.ps1 -Profile recovery
```

Every profile also runs deterministic reliability tests: standard MCP subprocesses, real FastAPI requests with transaction fixtures, delayed frontend responses, cache/AIS lifecycle, offline-project copying, and map/restore failure injection. These tests use temporary directories and mocked Docker commands; they do not operate the personal database or installed maps. Python 3.11+, Node.js 20+ and PowerShell 7 are required. Install `python -m pip install -r tests/requirements.txt` in a virtual environment, then pass its Python path through `-PythonExecutable` when needed.

Actual PostGIS tests only run with an explicit `TERRASYS_TEST_DATABASE_URL` pointing to an empty dedicated database named `terrasys_reliability_test`. Never use the personal database. CI provisions that disposable database in a separate Linux job; locally these three SQL tests are reported as skipped when it is absent. All other reliability checks run without Docker.

The browser profiles build `terrasys-ui-test:suite` and share the `terrasys-web` network namespace. Use `-SkipImageBuild` to reuse an existing image during repeated runs; do not skip the build after changing a test or its baseline.

## Regression coverage

The catalog groups the project's hard-won contracts into these areas:

- Repository and docs: parseable configuration, syntactically valid scripts, paired bilingual files, and valid relative links.
- Map packages and derivatives: all 34 Chinese province units and the global catalog are complete; every enabled region propagates into Carto, search, routing, elevation, weather, and nautical coverage with per-region source hashes.
- Personal data: places, tracks, collections, optimistic versions, GPX, GeoJSON, ZIP, media ownership, and orphan cleanup form a complete lifecycle.
- Map behavior: local Carto, regional PMTiles, world overview, and both online sources; network failure, Carto lag, coast/ocean/low-zoom false positives, and viewport movement have explicit regressions.
- Additional information layers: the no-key catalog, persistent enable/refresh settings, runtime status, normalized GeoJSON, cache, bounds, AIS decoding, P0/P1 entry, standalone management console, and retained contour control have unit and browser regressions.
- Global localization: country-polygon selection and Chinese prompts agree, while Taiwan-related packages, resource names, feature details, and world-overview layers consistently display `台湾省`.
- Performance: startup requests the package inventory once and compares DOM, canvas, and system-ready timings with a retained three-run median.
- Recovery: paths, sizes, and SHA256 values are verified before an isolated Docker network tests the database, maps, search, routing, knowledge services, personal data, and exports.

## Evidence and side effects

Playwright screenshots go to the gitignored `runtime/ui-smoke`, `runtime/resource-console-smoke`, and `runtime/information-layer-console-smoke` directories. The performance test prints current, baseline, and percentage-delta values. Recovery reports go to `runtime/recovery-audit`.

`scripts/smoke-test.ps1` creates temporary collections, places, tracks, media, and exports, then cleans them on success or failure. Browser tests intercept write-oriented maintenance requests and do not perform real deletion or rebuild actions. The `recovery` profile creates temporary isolated containers, a network, and volumes that the recovery script removes afterward.

## Maintenance rules

When fixing a regression, put the smallest stable assertion in the automation closest to the behavior and update `test-cases.json` in the same change. A new browser script must also be copied into `services/tools/ui-test/Dockerfile`; the `static` profile enforces that contract.

Refresh the performance baseline only after an intentional startup-path or test-environment change. Record at least three fresh browser contexts, retain the median, and keep the guardrail materially wider than normal variance so a single workstation fluctuation is not treated as a product regression.

Run at least `static` before every commit, `full` for runtime behavior, and `recovery` for recovery-material changes. GitHub Actions runs `static` automatically on pull requests and pushes to `main`.
