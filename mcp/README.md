# TerraSys MCP Server

> English | [简体中文](README.zh-CN.md)

This directory contains an isolated Model Context Protocol server for TerraSys. It runs as a stdio adapter for MCP clients and calls the existing TerraSys HTTP API; it does not join Docker Compose, expose PostGIS credentials, or mutate local GIS data.

## Boundary

- Transport: MCP over stdio.
- Default upstream: `http://localhost:8080/api`.
- Configuration: `TERRASYS_API_URL` and optional `TERRASYS_MCP_TIMEOUT`.
- Dependencies: Python standard library only.
- Default capability set: read-only TerraSys queries and GeoJSON export through existing GET endpoints.

## Tools

| Tool | Purpose |
| --- | --- |
| `terrasys_health` | Check API health and personal data counts. |
| `terrasys_search` | Search personal places, tracks, and local reference places. |
| `terrasys_places` | List personal places as compact GeoJSON. |
| `terrasys_tracks` | List tracks as compact GeoJSON. |
| `terrasys_map_packs` | Summarize installed map packs. |
| `terrasys_resources` | Read the cached resource inventory. |
| `terrasys_export_geojson` | Export personal places and tracks as a bounded GeoJSON response. |

## Run

Start TerraSys first:

```powershell
.\start-terrasys.cmd
```

Then configure an MCP client to launch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Administrator\Documents\个人GIS\scripts\start-mcp.ps1
```

For a LAN-exposed TerraSys web endpoint, keep the MCP server on the same trusted host unless you intentionally proxy stdio through another security boundary.

## Example Client Configuration

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

## Safety Notes

The first version intentionally avoids write tools, arbitrary SQL, arbitrary PowerShell, direct filesystem browsing, and destructive maintenance actions. Add those later only behind narrow allowlists and explicit confirmations.
