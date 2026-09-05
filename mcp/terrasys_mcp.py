#!/usr/bin/env python3
"""TerraSys MCP stdio server.

This adapter intentionally stays outside the TerraSys runtime stack. It exposes
selected read-only TerraSys HTTP API calls to MCP clients over stdio without
requiring database credentials or Docker Compose changes.
"""

from __future__ import annotations

import json
import os
import sys
import traceback
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "terrasys-mcp"
SERVER_VERSION = "0.1.0"
DEFAULT_API_URL = "http://localhost:8080/api"
MAX_TEXT_CHARS = 24_000


class McpError(Exception):
    def __init__(self, code: int, message: str, data: Any | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


@dataclass(frozen=True)
class TerraSysClient:
    base_url: str
    timeout: float

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        url = f"{self.base_url}{path}"
        clean_params = {
            key: value
            for key, value in (params or {}).items()
            if value is not None and value != ""
        }
        if clean_params:
            url = f"{url}?{urlencode(clean_params, doseq=True)}"
        request = Request(url, headers={"Accept": "application/json", "User-Agent": f"{SERVER_NAME}/{SERVER_VERSION}"})
        try:
            with urlopen(request, timeout=self.timeout) as response:
                content_type = response.headers.get("Content-Type", "")
                body = response.read()
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise McpError(-32010, f"TerraSys API returned HTTP {exc.code}", {"url": url, "body": detail}) from exc
        except (TimeoutError, URLError) as exc:
            raise McpError(-32011, "TerraSys API is unavailable", {"url": url, "reason": str(exc)}) from exc
        if "application/json" not in content_type:
            return body.decode("utf-8", errors="replace")
        try:
            return json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise McpError(-32012, "TerraSys API returned invalid JSON", {"url": url}) from exc


def api_client() -> TerraSysClient:
    base_url = os.environ.get("TERRASYS_API_URL", DEFAULT_API_URL).rstrip("/")
    timeout = float(os.environ.get("TERRASYS_MCP_TIMEOUT", "8"))
    return TerraSysClient(base_url=base_url, timeout=timeout)


def compact_json(value: Any, *, max_chars: int = MAX_TEXT_CHARS) -> str:
    text = json.dumps(value, ensure_ascii=False, indent=2, default=str)
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "\n... truncated ..."


def feature_summary(collection: dict[str, Any], limit: int) -> dict[str, Any]:
    features = list(collection.get("features") or [])
    limited = features[:limit]
    return {
        "type": collection.get("type", "FeatureCollection"),
        "count": len(features),
        "returned": len(limited),
        "features": limited,
    }


def installed_pack_summary(payload: dict[str, Any]) -> dict[str, Any]:
    packs = list(payload.get("packs") or [])
    installed = [pack for pack in packs if pack.get("installed")]
    return {
        "activeDataset": payload.get("activeDataset"),
        "catalogVersion": payload.get("catalogVersion"),
        "installed": payload.get("installed", len(installed)),
        "provinceCount": payload.get("provinceCount"),
        "coveredProvinceCount": payload.get("coveredProvinceCount"),
        "packs": [
            {
                "id": pack.get("id"),
                "name": pack.get("name"),
                "kind": pack.get("kind"),
                "installed": pack.get("installed"),
                "enabled": pack.get("enabled"),
                "version": pack.get("version"),
                "updateStatus": pack.get("updateStatus"),
            }
            for pack in installed
        ],
    }


TOOLS: list[dict[str, Any]] = [
    {
        "name": "terrasys_health",
        "description": "Check whether the TerraSys API is reachable and summarize personal data counts.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "terrasys_search",
        "description": "Search TerraSys personal places, tracks, and local reference places.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "minLength": 1, "maxLength": 200},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "terrasys_places",
        "description": "List TerraSys places as a compact GeoJSON FeatureCollection summary.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "maxLength": 200, "default": ""},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 25},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "terrasys_tracks",
        "description": "List TerraSys tracks as a compact GeoJSON FeatureCollection summary.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "maxLength": 200, "default": ""},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "terrasys_map_packs",
        "description": "Summarize installed TerraSys map packs without exposing raw product files.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "terrasys_resources",
        "description": "Read the cached TerraSys resource inventory summary.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "terrasys_export_geojson",
        "description": "Export TerraSys personal places and tracks as GeoJSON through the existing API.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 500,
                    "default": 100,
                    "description": "Maximum number of returned features in the MCP response.",
                }
            },
            "additionalProperties": False,
        },
    },
]


def require_int(args: dict[str, Any], key: str, default: int, minimum: int, maximum: int) -> int:
    value = args.get(key, default)
    if not isinstance(value, int) or value < minimum or value > maximum:
        raise McpError(-32602, f"{key} must be an integer between {minimum} and {maximum}")
    return value


def require_string(args: dict[str, Any], key: str, default: str = "", *, required: bool = False, max_length: int = 200) -> str:
    value = args.get(key, default)
    if required and (not isinstance(value, str) or not value.strip()):
        raise McpError(-32602, f"{key} is required")
    if not isinstance(value, str) or len(value) > max_length:
        raise McpError(-32602, f"{key} must be a string up to {max_length} characters")
    return value.strip()


def call_tool(name: str, arguments: dict[str, Any] | None) -> dict[str, Any]:
    args = arguments or {}
    client = api_client()
    if name == "terrasys_health":
        health = client.get("/health")
        status = client.get("/status")
        return {"api": health, "status": status}
    if name == "terrasys_search":
        query = require_string(args, "query", required=True)
        limit = require_int(args, "limit", 10, 1, 50)
        return client.get("/search", {"q": query, "limit": limit})
    if name == "terrasys_places":
        query = require_string(args, "query")
        limit = require_int(args, "limit", 25, 1, 100)
        return feature_summary(client.get("/places.geojson", {"q": query}), limit)
    if name == "terrasys_tracks":
        query = require_string(args, "query")
        limit = require_int(args, "limit", 10, 1, 50)
        return feature_summary(client.get("/tracks.geojson", {"q": query}), limit)
    if name == "terrasys_map_packs":
        return installed_pack_summary(client.get("/map-packs"))
    if name == "terrasys_resources":
        return client.get("/resources", {"cached": "true"})
    if name == "terrasys_export_geojson":
        limit = require_int(args, "limit", 100, 1, 500)
        return feature_summary(client.get("/export/geojson"), limit)
    raise McpError(-32601, f"Unknown tool: {name}")


def read_message() -> dict[str, Any] | None:
    line = sys.stdin.buffer.readline()
    if line == b"":
        return None
    try:
        message = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise McpError(-32700, "Invalid JSON-RPC payload") from exc
    if not isinstance(message, dict):
        raise McpError(-32600, "JSON-RPC message must be an object")
    return message


def write_message(payload: dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(body + b"\n")
    sys.stdout.buffer.flush()


def success(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def failure(request_id: Any, exc: McpError) -> dict[str, Any]:
    error: dict[str, Any] = {"code": exc.code, "message": exc.message}
    if exc.data is not None:
        error["data"] = exc.data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def handle_request(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    if request_id is None and isinstance(method, str) and method.startswith("notifications/"):
        return None
    if method == "initialize":
        return success(
            request_id,
            {
                "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )
    if method == "tools/list":
        return success(request_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        if not isinstance(name, str):
            raise McpError(-32602, "tools/call requires a tool name")
        result = call_tool(name, params.get("arguments") or {})
        return success(request_id, {"content": [{"type": "text", "text": compact_json(result)}]})
    raise McpError(-32601, f"Method not found: {method}")


def main() -> int:
    while True:
        message = None
        try:
            message = read_message()
            if message is None:
                return 0
            response = handle_request(message)
            if response is not None:
                write_message(response)
        except McpError as exc:
            request_id = None
            try:
                request_id = message.get("id")  # type: ignore[name-defined]
            except Exception:
                pass
            write_message(failure(request_id, exc))
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            write_message(failure(None, McpError(-32603, "Internal MCP server error", {"reason": str(exc)})))


if __name__ == "__main__":
    raise SystemExit(main())
