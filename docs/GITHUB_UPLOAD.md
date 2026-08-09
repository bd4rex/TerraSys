# GitHub Publication Notes

> English | [简体中文](GITHUB_UPLOAD.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

## Current repository

- Repository: [bd4rex/TerraSys](https://github.com/bd4rex/TerraSys)
- Visibility: public
- Default branch: `main`
- Local remote: `origin`
- First Git publication: `2026-08-01T18:44:56+08:00`

Large map products and private data are deliberately not stored in GitHub. The repository contains the reproducible system, documentation, catalogs, configuration, scripts, migrations, tests, and small seed/reference assets.

## Documentation conventions

- The language switch at the top of every document is inspired by the direct English/Chinese navigation used in the [Ant Design repository](https://github.com/ant-design/ant-design).
- The changelog uses a version-first, dated, human-readable structure inspired by the [Vue core changelog](https://github.com/vuejs/core/blob/main/CHANGELOG.md).
- Timestamps use ISO 8601 with an explicit offset. Historical labels always link to the authoritative commit and never imply an absent tag or Release.

## Commit scope

Commit:

- root README, changelog, `.gitignore`, and command launchers;
- `docs/` and other maintained Markdown;
- `config/`, `scripts/`, `services/`, and `tests/`;
- `web/index.html`, `web/resources.html`, `web/src/`, and `web/config/`;
- Dockerfiles, Compose configuration, and PostGIS migrations;
- small generated catalog or overview metadata only when it is intentionally refreshed and reviewed.

Do not commit:

- `services/.env` or credentials;
- `raw/`, `products/`, `tmp/`, `runtime/`, `backups/`, and `offline-kit/` payloads;
- Docker volumes or VHDX files;
- `data/media/`, exports, or personal database dumps;
- downloaded glyph, sprite, vendor, and large map artifacts covered by `.gitignore`.

## Publication workflow

Use a focused branch and explicit staging when the worktree also contains generated runtime changes:

```powershell
Set-Location D:\TerraSys
git status -sb
git switch -c agent/<description>
git add README.md README.zh-CN.md CHANGELOG.md CHANGELOG.zh-CN.md docs
git diff --cached --check
git commit -m "<description>"
git push -u origin agent/<description>
gh pr create --draft --fill
```

Before merging:

1. verify English/Chinese links and Markdown anchors;
2. run documentation validation and relevant project tests;
3. inspect `git diff --cached` so generated manifests or private data are not included;
4. confirm the PR base is `main` and checks pass;
5. merge through GitHub and delete the branch when no longer needed.

## Version history

Use [CHANGELOG.md](../CHANGELOG.md) and its Chinese counterpart for user-visible milestones. Every entry records an ISO 8601 timestamp and the authoritative commit hash. Do not claim a tag or GitHub Release existed unless it is visible in the repository.

## GitHub About

The repository About description is maintained in English because it is the public discovery surface. README language links provide the localized project entry points.
