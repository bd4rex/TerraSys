# TerraSys MCP 服务

> [English](README.md) | 简体中文

这个目录提供一个相对独立的 TerraSys Model Context Protocol 服务。它作为 MCP 客户端可启动的 stdio 适配层运行，并调用现有 TerraSys HTTP API；它不加入 Docker Compose，不暴露 PostGIS 凭据，也不直接改写本地 GIS 数据。

## 边界

- 传输方式：stdio 上的 MCP。
- 默认上游：`http://localhost:8080/api`。
- 配置项：`TERRASYS_API_URL`，以及可选的 `TERRASYS_MCP_TIMEOUT`。
- 依赖：只使用 Python 标准库。
- 默认能力：通过现有 GET 端点提供只读查询和 GeoJSON 导出。

## 工具

| 工具 | 用途 |
| --- | --- |
| `terrasys_health` | 检查 API 健康状态和个人数据数量。 |
| `terrasys_search` | 搜索个人地点、轨迹和本地参考地点。 |
| `terrasys_places` | 以精简 GeoJSON 形式列出个人地点。 |
| `terrasys_tracks` | 以精简 GeoJSON 形式列出轨迹。 |
| `terrasys_map_packs` | 汇总已安装地图包。 |
| `terrasys_resources` | 读取缓存的资源清单。 |
| `terrasys_export_geojson` | 以有数量上限的 GeoJSON 响应导出个人地点和轨迹。 |

## 运行

先启动 TerraSys：

```powershell
.\start-terrasys.cmd
```

然后在 MCP 客户端中配置启动命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Administrator\Documents\个人GIS\scripts\start-mcp.ps1
```

如果 TerraSys Web 入口已经开放给局域网，仍建议 MCP 服务只在同一台可信主机上运行，除非你明确为 stdio 代理增加了额外安全边界。

## 客户端配置示例

```json
{
  "mcpServers": {
    "terrasys": {
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "C:\\Users\\Administrator\\Documents\\个人GIS\\scripts\\start-mcp.ps1"
      ],
      "env": {
        "TERRASYS_API_URL": "http://localhost:8080/api"
      }
    }
  }
}
```

## 安全说明

第一版刻意不提供写入工具、任意 SQL、任意 PowerShell、直接浏览文件系统和破坏性维护操作。后续如果要增加这些能力，建议放在明确的白名单和显式确认之后。
