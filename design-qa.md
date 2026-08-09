# Resource maintenance layout QA

> English | [简体中文](design-qa.zh-CN.md) · Snapshot `2026-08-03T23:12:23+08:00`

- Reference: `C:\Users\Administrator\Desktop\屏幕截图 2026-07-22 193947.png`
- Capture: `D:\TerraSys\runtime\ui-smoke\resource-manager.png`
- Viewport: 1440 x 900 desktop

## Checks

- PASS: the summary strip contains status totals only and no detached cancel actions.
- PASS: every active task has one cancel action in its own row.
- PASS: running work exposes stage, elapsed time, local size, and a labelled stage-progress bar.
- PASS: generation throughput and processed/output totals fit between the stage label and progress track without moving the row action.
- PASS: queued work exposes queue position and a visually distinct waiting track.
- PASS: normal update rows no longer show a fake percentage-like meter.
- PASS: row content remains aligned and readable without nested cards or overlapping controls.
- PASS: the narrow layout moves task progress beneath the row title and keeps the cancel action attached.

No P0, P1, or P2 visual issues remain.

final result: passed
