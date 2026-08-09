# GitHub 发布说明

> [English](GITHUB_UPLOAD.md) | 简体中文 · 快照 `2026-08-03T23:12:23+08:00`

## 当前仓库

- 仓库：[bd4rex/TerraSys](https://github.com/bd4rex/TerraSys)
- 可见性：公开
- 默认分支：`main`
- 本地远端：`origin`
- 首次 Git 发布：`2026-08-01T18:44:56+08:00`

大型地图产品和私人数据不会进入 GitHub。仓库保存可重现系统、双语文档、目录、配置、脚本、迁移、测试和小型种子/参考资源。

## 文档约定

- 每份文档顶部的语言切换参考了 [Ant Design 仓库](https://github.com/ant-design/ant-design)直接提供中英文入口的做法。
- 变更记录参考 [Vue core changelog](https://github.com/vuejs/core/blob/main/CHANGELOG.md)，采用版本优先、带日期且便于阅读的分组结构。
- 时间统一使用带明确时区偏移的 ISO 8601 格式；历史标签必须链接到权威提交，不暗示不存在的 tag 或 Release。

## 提交范围

应提交：

- 根 README、变更记录、`.gitignore` 与命令入口；
- `docs/` 和其他维护中的 Markdown；
- `config/`、`scripts/`、`services/`、`tests/`；
- `web/index.html`、`web/resources.html`、`web/src/`、`web/config/`；
- Dockerfile、Compose 和 PostGIS 迁移；
- 只有在有意刷新并审查时，才提交小型生成目录或概览元数据。

不得提交：

- `services/.env` 或密钥；
- `raw/`、`products/`、`tmp/`、`runtime/`、`backups/`、`offline-kit/` payload；
- Docker 卷或 VHDX；
- `data/media/`、导出和个人数据库 dump；
- `.gitignore` 排除的下载字形、sprites、vendor 和大型地图产品。

## 发布流程

工作区同时有运行时生成变更时，使用独立分支并显式暂存：

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

合并前：

1. 检查中英文链接与 Markdown 锚点；
2. 运行文档校验及相关项目测试；
3. 检查 `git diff --cached`，防止加入生成清单或私人数据；
4. 确认 PR 基线为 `main` 且检查通过；
5. 在 GitHub 合并，不再需要时删除分支。

## 版本历史

用户可见里程碑写入 [CHANGELOG.zh-CN.md](../CHANGELOG.zh-CN.md)及英文对应文件。每项保留 ISO 8601 时间戳和权威提交哈希；GitHub 上不可见的 tag/Release 不得宣称存在。

## GitHub About

About 是公开发现入口，使用英文描述；README 语言链接提供本地化入口。
