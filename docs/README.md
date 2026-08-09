# Documentation index

> English | [简体中文](README.zh-CN.md)
>
> Documentation snapshot: `2026-08-07T14:04:59+08:00`

Every maintained Markdown document has an English default file and a Simplified Chinese companion. Commands, paths, identifiers, checksums, and timestamps are intentionally kept identical between languages.

## Current system

| Subject | English | 简体中文 |
| --- | --- | --- |
| Project overview | [README](../README.md) | [README](../README.zh-CN.md) |
| Architecture | [Architecture](ARCHITECTURE.md) | [架构](ARCHITECTURE.zh-CN.md) |
| Configuration | [Configuration](CONFIGURATION.md) | [配置](CONFIGURATION.zh-CN.md) |
| Data pipeline | [Data pipeline](DATA_PIPELINE.md) | [数据流水线](DATA_PIPELINE.zh-CN.md) |
| Operations | [Operations](OPERATIONS.md) | [运维](OPERATIONS.zh-CN.md) |
| Test suite | [Test suite](../tests/README.md) | [测试用例集](../tests/README.zh-CN.md) |
| Weaker-model full rebuild | [AI rebuild playbook](AI_REBUILD_EXECUTION_PLAN.md) | [重建执行手册](AI_REBUILD_EXECUTION_PLAN.zh-CN.md) |
| Rebuild | [Rebuild from scratch](REBUILD.md) | [从零重建](REBUILD.zh-CN.md) |
| Offline recovery | [Offline recovery](OFFLINE_RECOVERY.md) | [离线恢复](OFFLINE_RECOVERY.zh-CN.md) |
| Resource lifecycle | [Resource and version management](RESOURCE_AND_VERSION_MANAGEMENT.md) | [资源与版本管理](RESOURCE_AND_VERSION_MANAGEMENT.zh-CN.md) |
| OSM update policy | [Incremental updates](OSM_INCREMENTAL_UPDATES.md) | [增量更新](OSM_INCREMENTAL_UPDATES.zh-CN.md) |
| Sources and licenses | [Sources and licenses](SOURCES_AND_LICENSES.md) | [来源与许可](SOURCES_AND_LICENSES.zh-CN.md) |
| Roadmap | [Roadmap](ROADMAP.md) | [路线图](ROADMAP.zh-CN.md) |

## History and design records

| Subject | English | 简体中文 |
| --- | --- | --- |
| Changelog | [Version history](../CHANGELOG.md) | [版本历史](../CHANGELOG.zh-CN.md) |
| Process log | [Process log](PROCESS_LOG.md) | [过程日志](PROCESS_LOG.zh-CN.md) |
| Original MVP plan | [MVP plan](local-mvp-plan.md) | [MVP 规划](local-mvp-plan.zh-CN.md) |
| Local stack note | [Local stack](local-stack.md) | [本地服务栈](local-stack.zh-CN.md) |
| Jiangsu/Anhui MVP | [Regional MVP](mvp-d-giss.md) | [区域 MVP](mvp-d-giss.zh-CN.md) |
| OsmAnd study | [OsmAnd reference](OSMAND_REFERENCE.md) | [OsmAnd 参考](OSMAND_REFERENCE.zh-CN.md) |
| Resource-layout QA | [QA record](../design-qa.md) | [QA 记录](../design-qa.zh-CN.md) |
| GitHub publication note | [GitHub upload](GITHUB_UPLOAD.md) | [GitHub 上传](GITHUB_UPLOAD.zh-CN.md) |

Historical planning documents are retained because they explain why the current architecture exists. The root README, architecture, configuration, operations, and recovery guides are the authoritative descriptions of the current system.

## Translation maintenance rule

When a document changes:

1. update both language files in the same change;
2. preserve commands, paths, hashes, version identifiers, and timestamps exactly;
3. keep the language switch at the top of both files;
4. check local relative links before publishing.
