from __future__ import annotations

import json
import os
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


def read_json_file(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def write_json_file(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def directory_usage(path: Path) -> dict[str, int]:
    total_bytes = 0
    file_count = 0
    if not path.is_dir():
        return {"bytes": 0, "files": 0}
    try:
        for root, _, filenames in os.walk(path):
            for filename in filenames:
                try:
                    total_bytes += os.path.getsize(os.path.join(root, filename))
                    file_count += 1
                except OSError:
                    continue
    except OSError:
        pass
    return {"bytes": total_bytes, "files": file_count}


def parse_state_text(content: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().replace(r"\:", ":")
    return values


def upstream_source_states(
    catalog: dict[str, Any], installed_ids: set[str], refresh: bool, cache_path: Path
) -> dict[str, Any]:
    cache = read_json_file(cache_path) or {"checkedAt": None, "sources": {}}
    if not refresh:
        return cache

    allowed_hosts = {"download.openstreetmap.fr", "download.geofabrik.de"}
    sources: dict[str, Any] = {}
    urls = {
        str(dataset.get("sourceProfile", {}).get("stateUrl"))
        for dataset in catalog.get("datasets", [])
        if str(dataset.get("id")) in installed_ids
        and isinstance(dataset.get("sourceProfile"), dict)
        and dataset.get("sourceProfile", {}).get("stateUrl")
    }
    for url in sorted(urls):
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
            sources[url] = {"error": "不受信任的上游地址"}
            continue
        try:
            request = Request(url, headers={"User-Agent": "TerraSys/1.0 offline-map-updater"})
            with urlopen(request, timeout=12) as response:
                content = response.read(256 * 1024).decode("utf-8", errors="strict")
            sources[url] = {**parse_state_text(content), "checkedAt": datetime.now().astimezone().isoformat()}
        except (OSError, UnicodeError, HTTPError, URLError) as exc:
            previous = (cache.get("sources") or {}).get(url, {})
            sources[url] = {**previous, "error": str(exc), "failedAt": datetime.now().astimezone().isoformat()}
    refreshed = {"checkedAt": datetime.now().astimezone().isoformat(), "sources": sources}
    write_json_file(cache_path, refreshed)
    return refreshed
