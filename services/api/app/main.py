from __future__ import annotations

import hashlib
import json
import math
import mimetypes
import os
import re
import shutil
import sys
import uuid
import zipfile
from array import array
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from functools import lru_cache
from io import BytesIO
from pathlib import Path
from threading import Lock, Thread
from time import sleep
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from defusedxml import ElementTree
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse, Response
from PIL import Image
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field, field_validator
from starlette.requests import Request as StarletteRequest

from app.personal_export import gpx_document
from app.resource_support import directory_usage, read_json_file, upstream_source_states, write_json_file


DATABASE_URL = os.environ["DATABASE_URL"]
MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/data/media"))
EXPORT_ROOT = Path(os.environ.get("EXPORT_ROOT", "/data/exports"))
BACKUP_ROOT = Path(os.environ.get("BACKUP_ROOT", "/data/backups"))
OFFLINE_KIT_ROOT = Path(os.environ.get("OFFLINE_KIT_ROOT", "/data/offline-kit"))
MAP_CATALOG_PATH = Path(os.environ.get("MAP_CATALOG_PATH", "/data/map-catalog.json"))
REGION_CATALOG_PATH = Path(os.environ.get("REGION_CATALOG_PATH", "/data/region-catalog.json"))
WORLD_REGION_CATALOG_PATH = Path(os.environ.get("WORLD_REGION_CATALOG_PATH", "/data/world-region-catalog.json"))
MAP_PACK_ROOT = Path(os.environ.get("MAP_PACK_ROOT", "/data/map-packs"))
OSM_ROOT = Path(os.environ.get("OSM_ROOT", "/data/osm"))
OSM_STATE_PATH = Path(os.environ.get("OSM_STATE_PATH", "/data/china.state.txt"))
CAPABILITY_MANIFEST_PATH = Path(os.environ.get("CAPABILITY_MANIFEST_PATH", "/data/terrasys-core.manifest.json"))
NOMINATIM_URL = os.environ.get("NOMINATIM_URL", "http://nominatim:8080").rstrip("/")
VALHALLA_URL = os.environ.get("VALHALLA_URL", "http://valhalla:8002").rstrip("/")
KIWIX_URL = os.environ.get("KIWIX_URL", "http://kiwix:8080").rstrip("/")
ELEVATION_ROOT = Path(os.environ.get("ELEVATION_ROOT", "/data/elevation"))
TERRAIN_CACHE_ROOT = Path(os.environ.get("TERRAIN_CACHE_ROOT", "/data/terrain-cache"))
BUILD_CACHE_ROOT = Path(os.environ.get("BUILD_CACHE_ROOT", "/data/build-cache"))
OSM_RESOURCE_ROOT = Path(os.environ.get("OSM_RESOURCE_ROOT", "/data/osm-resources"))
ROUTING_RESOURCE_ROOT = Path(os.environ.get("ROUTING_RESOURCE_ROOT", "/data/routing-resources"))
ENCYCLOPEDIA_RESOURCE_ROOT = Path(os.environ.get("ENCYCLOPEDIA_RESOURCE_ROOT", "/data/encyclopedia-resources"))
WEB_RESOURCE_ROOT = Path(os.environ.get("WEB_RESOURCE_ROOT", "/data/web-resources"))
WEATHER_RESOURCE_ROOT = Path(os.environ.get("WEATHER_RESOURCE_ROOT", "/data/weather-resources"))
NAUTICAL_RESOURCE_ROOT = Path(os.environ.get("NAUTICAL_RESOURCE_ROOT", "/data/nautical-resources"))
OVERVIEW_RESOURCE_ROOT = Path(os.environ.get("OVERVIEW_RESOURCE_ROOT", "/data/overview-resources"))
OSM_CARTO_MANIFEST_PATH = Path(os.environ.get("OSM_CARTO_MANIFEST_PATH", "/data/osm-carto/osm-carto.manifest.json"))
OSM_CARTO_CACHE_ROOT = Path(os.environ.get("OSM_CARTO_CACHE_ROOT", "/data/osm-carto-cache"))
OSM_CARTO_URL = os.environ.get("OSM_CARTO_URL", "http://osm-carto:80").rstrip("/")
MAINTENANCE_ROOT = Path(os.environ.get("MAINTENANCE_ROOT", "/data/maintenance"))
RESOURCE_INVENTORY_CACHE_PATH = MAINTENANCE_ROOT / "resource-inventory-cache.json"
RESOURCE_INVENTORY_REVISION_PATH = MAINTENANCE_ROOT / "resource-inventory-revision.json"
RESOURCE_INVENTORY_SCHEMA = 3
MAP_PACK_STATE_PATH = MAINTENANCE_ROOT / "map-pack-state.json"
SHARED_INDEX_STATE_PATH = MAINTENANCE_ROOT / "shared-index-state.json"
MAX_MEDIA_BYTES = 50 * 1024 * 1024

RESOURCE_CLASSIFICATIONS: dict[str, dict[str, str]] = {
    "standard-maps": {"resourceType": "standard-map", "storageClass": "primary", "scope": "regional", "validationPolicy": "manifest-size-and-async-sha256"},
    "map-rollbacks": {"resourceType": "standard-map", "storageClass": "rollback", "scope": "regional", "validationPolicy": "paired-manifest-size"},
    "map-build-staging": {"resourceType": "standard-map", "storageClass": "staging", "scope": "regional", "validationPolicy": "never-active-until-verified"},
    "map-version-history": {"resourceType": "version-metadata", "storageClass": "history", "scope": "regional", "validationPolicy": "json-schema"},
    "other-map-products": {"resourceType": "unknown", "storageClass": "unclassified", "scope": "unknown", "validationPolicy": "manual-review"},
    "osm-sources": {"resourceType": "osm-source", "storageClass": "primary", "scope": "regional", "validationPolicy": "osmium-structural-scan-on-activation"},
    "source-rollbacks": {"resourceType": "osm-source", "storageClass": "rollback", "scope": "regional", "validationPolicy": "paired-snapshot-and-state"},
    "legacy-source-comparisons": {"resourceType": "osm-source", "storageClass": "archive", "scope": "regional", "validationPolicy": "not-runtime-active"},
    "staged-source-downloads": {"resourceType": "osm-source", "storageClass": "staging", "scope": "regional", "validationPolicy": "never-active-until-verified"},
    "geocoder": {"resourceType": "search-index", "storageClass": "external-volume", "scope": "installed-regions", "validationPolicy": "blue-green-database-check-and-service-health"},
    "routing": {"resourceType": "routing-index", "storageClass": "primary", "scope": "installed-regions", "validationPolicy": "blue-green-candidate-check-and-service-health"},
    "terrain": {"resourceType": "elevation-grid", "storageClass": "primary", "scope": "regional", "validationPolicy": "hgt-name-and-byte-size"},
    "encyclopedia": {"resourceType": "encyclopedia", "storageClass": "primary", "scope": "global", "validationPolicy": "manifest-size-and-service-health"},
    "overview-map": {"resourceType": "overview-map", "storageClass": "primary", "scope": "global", "validationPolicy": "manifest-size-and-sha256"},
    "osm-carto-renderer": {"resourceType": "standard-map", "storageClass": "rendered", "scope": "installed-regions", "validationPolicy": "source-manifest-and-blue-green-service-health"},
    "weather": {"resourceType": "weather", "storageClass": "primary", "scope": "regional", "validationPolicy": "manifest-size-sha256-and-expiry"},
    "travel-guide": {"resourceType": "travel-guide", "storageClass": "primary", "scope": "global", "validationPolicy": "manifest-size-and-service-health"},
    "nautical": {"resourceType": "nautical", "storageClass": "primary", "scope": "regional", "validationPolicy": "manifest-size-and-sha256"},
    "tts": {"resourceType": "voice-runtime", "storageClass": "external-runtime", "scope": "system", "validationPolicy": "browser-runtime-capability"},
    "personal-database": {"resourceType": "personal-data", "storageClass": "personal", "scope": "personal", "validationPolicy": "database-health-and-backup"},
    "personal-media": {"resourceType": "personal-media", "storageClass": "personal", "scope": "personal", "validationPolicy": "database-reference-and-file-presence"},
    "backups": {"resourceType": "backup", "storageClass": "backup", "scope": "system", "validationPolicy": "manifest-and-restore-test"},
    "offline-kits": {"resourceType": "recovery-kit", "storageClass": "backup", "scope": "system", "validationPolicy": "full-manifest-sha256"},
    "web-assets": {"resourceType": "rendering-assets", "storageClass": "primary", "scope": "system", "validationPolicy": "runtime-load"},
    "regenerable-caches": {"resourceType": "cache", "storageClass": "cache", "scope": "system", "validationPolicy": "regenerable"},
}

RESOURCE_MANAGEMENT: dict[str, dict[str, str | bool]] = {
    "standard-maps": {"managementMode": "map-packs", "managementLabel": "管理地图包"},
    "map-rollbacks": {"managementMode": "map-packs", "managementLabel": "管理版本"},
    "map-version-history": {"managementMode": "map-packs", "managementLabel": "查看版本"},
    "osm-sources": {"managementMode": "map-packs", "managementLabel": "管理地图包"},
    "source-rollbacks": {"managementMode": "map-packs", "managementLabel": "管理版本"},
    "geocoder": {"managementMode": "maintenance", "managementResourceId": "shared-capabilities", "managementLabel": "重建索引", "managementHeavy": True},
    "routing": {"managementMode": "maintenance", "managementResourceId": "shared-capabilities", "managementLabel": "重建索引", "managementHeavy": True},
    "terrain": {"managementMode": "maintenance", "managementResourceId": "terrain", "managementLabel": "同步已安装区域地形", "managementHeavy": True},
    "overview-map": {"managementMode": "maintenance", "managementResourceId": "overview-map", "managementLabel": "重新获取"},
    "osm-carto-renderer": {"managementMode": "maintenance", "managementResourceId": "osm-carto", "managementLabel": "同步已安装区域", "managementHeavy": True},
    "weather": {"managementMode": "maintenance", "managementResourceId": "weather", "managementLabel": "刷新天气"},
    "nautical": {"managementMode": "maintenance", "managementResourceId": "nautical", "managementLabel": "重建"},
    "encyclopedia": {"managementMode": "maintenance", "managementResourceId": "encyclopedia", "managementLabel": "重新获取", "managementHeavy": True},
    "travel-guide": {"managementMode": "maintenance", "managementResourceId": "travel-guide", "managementLabel": "重新获取", "managementHeavy": True},
    "personal-database": {"managementMode": "application", "managementHref": "/", "managementLabel": "打开数据"},
    "personal-media": {"managementMode": "application", "managementHref": "/", "managementLabel": "打开数据"},
    "regenerable-caches": {"managementMode": "cache", "managementLabel": "清理缓存"},
}

MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
EXPORT_ROOT.mkdir(parents=True, exist_ok=True)
TERRAIN_CACHE_ROOT.mkdir(parents=True, exist_ok=True)
MAINTENANCE_ROOT.mkdir(parents=True, exist_ok=True)
(MAINTENANCE_ROOT / "jobs").mkdir(parents=True, exist_ok=True)

pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=6, kwargs={"row_factory": dict_row})
app = FastAPI(title="TerraSys Personal Data API", version="1.0.0", docs_url="/docs")
RESOURCE_INVENTORY_REFRESH_LOCK = Lock()


class PlaceInput(BaseModel):
    id: str | None = None
    version: int | None = Field(default=None, ge=1)
    name: str = Field(min_length=1, max_length=200)
    province: str = Field(default="", max_length=100)
    category: str = Field(default="todo", max_length=80)
    note: str = Field(default="", max_length=10000)
    tags: list[str] = Field(default_factory=list)
    collection_ids: list[str] = Field(default_factory=list)
    rating: int = Field(default=0, ge=0, le=5)
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)

    @field_validator("tags")
    @classmethod
    def clean_tags(cls, value: list[str]) -> list[str]:
        return list(dict.fromkeys(item.strip()[:80] for item in value if item.strip()))[:50]

    @field_validator("collection_ids")
    @classmethod
    def clean_collection_ids(cls, value: list[str]) -> list[str]:
        return list(dict.fromkeys(item.strip()[:100] for item in value if item.strip()))[:100]


class CollectionInput(BaseModel):
    id: str | None = None
    name: str = Field(min_length=1, max_length=100)
    color: str = Field(default="#267352", pattern=r"^#[0-9A-Fa-f]{6}$")
    note: str = Field(default="", max_length=2000)


class TrackInput(BaseModel):
    id: str | None = None
    version: int | None = Field(default=None, ge=1)
    name: str = Field(min_length=1, max_length=200)
    activity: str = Field(default="other", max_length=40)
    note: str = Field(default="", max_length=10000)
    tags: list[str] = Field(default_factory=list)
    color: str = Field(default="#c94532", pattern=r"^#[0-9A-Fa-f]{6}$")
    geometry: dict[str, Any]

    @field_validator("geometry")
    @classmethod
    def validate_geometry(cls, value: dict[str, Any]) -> dict[str, Any]:
        geometry_type = value.get("type")
        if geometry_type not in {"LineString", "MultiLineString"}:
            raise ValueError("geometry must be LineString or MultiLineString")
        coordinates = value.get("coordinates")
        if not isinstance(coordinates, list) or not coordinates:
            raise ValueError("geometry coordinates are required")
        lines = [coordinates] if geometry_type == "LineString" else coordinates
        point_count = 0
        for line in lines:
            if not isinstance(line, list) or len(line) < 2:
                raise ValueError("each track segment must contain at least two points")
            point_count += len(line)
            if point_count > 500_000:
                raise ValueError("track geometry contains too many points")
            for point in line:
                if not isinstance(point, list) or len(point) < 2:
                    raise ValueError("track coordinates must be longitude/latitude pairs")
                try:
                    longitude = float(point[0])
                    latitude = float(point[1])
                except (TypeError, ValueError) as exc:
                    raise ValueError("track coordinates must be numeric") from exc
                if not math.isfinite(longitude) or not math.isfinite(latitude):
                    raise ValueError("track coordinates must be finite")
                if not -180 <= longitude <= 180 or not -90 <= latitude <= 90:
                    raise ValueError("track coordinates are outside WGS84 bounds")
        return value


class RouteLocation(BaseModel):
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)
    name: str = Field(default="", max_length=200)


class RouteInput(BaseModel):
    locations: list[RouteLocation] = Field(min_length=2, max_length=12)
    costing: str = Field(default="auto")
    language: str = Field(default="zh-CN", max_length=20)

    @field_validator("costing")
    @classmethod
    def validate_costing(cls, value: str) -> str:
        if value not in {"auto", "bicycle", "pedestrian"}:
            raise ValueError("costing must be auto, bicycle, or pedestrian")
        return value


class MaintenanceJobInput(BaseModel):
    resourceId: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9._:-]+$")
    action: str = Field(default="update", pattern=r"^(build|update|rebuild|rollback|verify|remove)$")
    confirmToken: str | None = Field(default=None, max_length=160)


class MapPackActivationInput(BaseModel):
    enabled: bool


class MaintenanceSettingsInput(BaseModel):
    enabled: bool
    resources: dict[str, bool] = Field(default_factory=dict)

    @field_validator("resources")
    @classmethod
    def validate_automatic_resources(cls, value: dict[str, bool]) -> dict[str, bool]:
        allowed = {"weather", "world-region-catalog", "overview-map"}
        if any(resource_id not in allowed for resource_id in value):
            raise ValueError("automatic update resource is not allowed")
        return value


class UpstreamUnavailable(RuntimeError):
    pass


def place_feature(row: dict[str, Any]) -> dict[str, Any]:
    properties = {key: value for key, value in row.items() if key not in {"longitude", "latitude"}}
    return {
        "type": "Feature",
        "id": row["id"],
        "properties": properties,
        "geometry": {"type": "Point", "coordinates": [row["longitude"], row["latitude"]]},
    }


def track_feature(row: dict[str, Any]) -> dict[str, Any]:
    geometry = json.loads(row.pop("geometry"))
    return {"type": "Feature", "id": row["id"], "properties": row, "geometry": geometry}


def replace_place_collections(conn: Any, place_id: str, collection_ids: list[str]) -> None:
    unique_ids = list(dict.fromkeys(collection_ids))
    if unique_ids:
        existing = conn.execute(
            "SELECT id FROM app.collections WHERE id = ANY(%s)", [unique_ids]
        ).fetchall()
        if len(existing) != len(unique_ids):
            raise HTTPException(status_code=422, detail="One or more collections do not exist")
    conn.execute("DELETE FROM app.place_collections WHERE place_id=%s", [place_id])
    if unique_ids:
        conn.execute(
            """
            INSERT INTO app.place_collections (place_id, collection_id)
            SELECT %s, collection_id FROM unnest(%s::text[]) AS collection_id
            """,
            [place_id, unique_ids],
        )


PLACE_SELECT = """
SELECT id, name, province, category, note, tags, rating, source,
       (SELECT count(*) FROM app.media WHERE place_id=app.places.id) AS media_count,
       COALESCE((
         SELECT jsonb_agg(jsonb_build_object('id', collection.id, 'name', collection.name, 'color', collection.color)
                          ORDER BY collection.name)
         FROM app.place_collections AS membership
         JOIN app.collections AS collection ON collection.id=membership.collection_id
         WHERE membership.place_id=app.places.id
       ), '[]'::jsonb) AS collections,
       created_at, updated_at, sync_state, version,
       ST_X(geom) AS longitude, ST_Y(geom) AS latitude
FROM app.places
"""

TRACK_SELECT = """
SELECT id, name, activity, note, tags, color, distance_m, source,
       created_at, updated_at, sync_state, version,
       ST_AsGeoJSON(geom)::text AS geometry
FROM app.tracks
"""


@app.get("/health")
def health() -> dict[str, Any]:
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT current_database() AS database, PostGIS_Version() AS postgis"
        ).fetchone()
    return {"status": "ok", **row}


def upstream_json(
    base_url: str,
    path: str,
    *,
    params: dict[str, Any] | None = None,
    payload: dict[str, Any] | None = None,
    timeout: float = 8.0,
) -> Any:
    url = f"{base_url}{path}"
    if params:
        url = f"{url}?{urlencode(params, doseq=True)}"
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
    request = Request(
        url,
        data=body,
        headers={"Accept": "application/json", "Content-Type": "application/json", "User-Agent": "TerraSys/1.0"},
        method="POST" if body is not None else "GET",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise UpstreamUnavailable(f"{base_url} is unavailable") from exc


def upstream_available(base_url: str, path: str) -> bool:
    request = Request(f"{base_url}{path}", headers={"User-Agent": "TerraSys/1.0"})
    try:
        with urlopen(request, timeout=1.5) as response:
            return 200 <= response.status < 400
    except (HTTPError, URLError, TimeoutError):
        return False


def capability_manifest() -> dict[str, Any] | None:
    try:
        return json.loads(CAPABILITY_MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def shared_index_scope_state() -> dict[str, Any]:
    manifest = capability_manifest() or {}
    validation = read_json_file(SHARED_INDEX_STATE_PATH) or {}
    active_inputs = validation.get("inputs") if isinstance(validation.get("inputs"), list) else manifest.get("inputs", [])
    indexed_sources = {
        str(item.get("id")): str(item.get("sha256") or "")
        for item in active_inputs
        if isinstance(item, dict) and item.get("id")
    }
    indexed_ids = set(indexed_sources)
    disabled_ids = set(map_pack_preferences()["disabledPackIds"])
    enabled_sources: dict[str, str] = {}
    for dataset in map_catalog().get("datasets", []):
        pack_id = str(dataset.get("id") or "")
        product_name = Path(str(dataset.get("url") or "")).name
        manifest_name = Path(str(dataset.get("manifestUrl") or "")).name
        if pack_id and pack_id not in disabled_ids and product_name and manifest_name:
            if (MAP_PACK_ROOT / product_name).is_file() and (MAP_PACK_ROOT / manifest_name).is_file():
                pack_manifest = read_json_file(MAP_PACK_ROOT / manifest_name) or {}
                source = pack_manifest.get("source") if isinstance(pack_manifest.get("source"), dict) else {}
                enabled_sources[pack_id] = str(source.get("sha256") or "")
    enabled_ids = set(enabled_sources)
    mismatched_ids = {
        pack_id for pack_id, source_hash in enabled_sources.items()
        if not source_hash or indexed_sources.get(pack_id) != source_hash
    }
    verified = (
        validation.get("strategy") == "blue-green"
        and validation.get("status") == "active"
        and bool(validation.get("active"))
        and bool(validation.get("lastBuildMapAvailable"))
    )
    missing_ids = (enabled_ids - indexed_ids) | mismatched_ids
    complete = bool(indexed_sources) and not missing_ids
    return {
        "complete": complete,
        "current": complete and indexed_ids == enabled_ids,
        "verified": verified,
        "validation": validation,
        "enabledPackIds": sorted(enabled_ids),
        "indexedPackIds": sorted(indexed_ids),
        "missingPackIds": sorted(missing_ids),
        "mismatchedPackIds": sorted(mismatched_ids),
        "extraPackIds": sorted(indexed_ids - enabled_ids),
    }


def require_usable_shared_index() -> None:
    scope = shared_index_scope_state()
    if not scope["verified"] or not scope["indexedPackIds"]:
        raise HTTPException(status_code=503, detail="搜索与路线共享索引尚未就绪")


DEFAULT_MAINTENANCE_SETTINGS = {
    "enabled": False,
    "resources": {
        "weather": {"enabled": True, "intervalHours": 6},
        "world-region-catalog": {"enabled": True, "intervalHours": 168},
        "overview-map": {"enabled": False, "intervalHours": 720},
    },
}

STATIC_MAINTENANCE_RESOURCES = {
    "shared-capabilities": {"label": "搜索与路线共享索引", "heavy": True},
    "osm-carto": {"label": "本地 OSM 原版渲染", "heavy": True},
    "terrain": {"label": "全球地形与等高线", "heavy": True},
    "world-region-catalog": {"label": "全球区域目录", "heavy": False},
    "overview-map": {"label": "全球概览地图", "heavy": False},
    "weather": {"label": "天气快照", "heavy": False},
    "nautical": {"label": "航海参考", "heavy": False},
    "encyclopedia": {"label": "离线百科", "heavy": True},
    "travel-guide": {"label": "旅行指南", "heavy": True},
}


def maintenance_settings() -> dict[str, Any]:
    stored = read_json_file(MAINTENANCE_ROOT / "settings.json") or {}
    resources = {
        resource_id: {**defaults, **(stored.get("resources", {}).get(resource_id, {}) or {})}
        for resource_id, defaults in DEFAULT_MAINTENANCE_SETTINGS["resources"].items()
    }
    return {"enabled": bool(stored.get("enabled", DEFAULT_MAINTENANCE_SETTINGS["enabled"])), "resources": resources}


def maintenance_jobs() -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    try:
        paths = list((MAINTENANCE_ROOT / "jobs").glob("*.json"))
    except OSError:
        paths = []
    for path in paths:
        job = read_json_file(path)
        if job:
            jobs.append(job)
    ordered = sorted(jobs, key=lambda item: str(item.get("requestedAt", "")), reverse=True)
    active = [job for job in ordered if job.get("status") in {"queued", "running"}]
    completed = [job for job in ordered if job.get("status") not in {"queued", "running"}][:100]
    return sorted(active + completed, key=lambda item: str(item.get("requestedAt", "")), reverse=True)


def queue_lightweight_region_derivatives(trigger: str) -> list[str]:
    queued: list[str] = []
    active_resource_ids = {
        str(job.get("resourceId"))
        for job in maintenance_jobs()
        if job.get("status") in {"queued", "running"}
    }
    for resource_id, label in (("terrain", "全球地形与等高线"), ("weather", "天气快照"), ("nautical", "航海参考")):
        if resource_id in active_resource_ids:
            continue
        now = datetime.now().astimezone().isoformat()
        job_id = uuid.uuid4().hex
        write_json_file(MAINTENANCE_ROOT / "jobs" / f"{job_id}.json", {
            "id": job_id,
            "resourceId": resource_id,
            "action": "update",
            "operation": resource_id,
            "label": label,
            "heavy": resource_id == "terrain",
            "priority": 80 if resource_id == "terrain" else 60,
            "automatic": True,
            "trigger": trigger,
            "attempts": 0,
            "maxAttempts": 3,
            "nextAttemptAt": now,
            "cancelRequested": False,
            "status": "queued",
            "message": "启用区域范围已变化，正在补齐离线高程" if resource_id == "terrain" else "启用区域范围已变化，正在同步轻量派生资源",
            "requestedAt": now,
            "startedAt": None,
            "finishedAt": None,
            "exitCode": None,
            "logFile": f"logs/{job_id}.log",
        })
        queued.append(resource_id)
    return queued


def maintenance_file_tail(relative_path: str) -> str:
    relative = str(relative_path or "").replace("\\", "/").lstrip("/")
    if not relative:
        return ""
    root = MAINTENANCE_ROOT.resolve()
    path = (MAINTENANCE_ROOT / relative).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        return ""
    try:
        with path.open("rb") as stream:
            stream.seek(max(0, path.stat().st_size - 512 * 1024))
            content = stream.read().decode("utf-8", errors="ignore")
    except OSError:
        return ""
    return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", content)


def maintenance_log_text(job: dict[str, Any]) -> str:
    return maintenance_file_tail(str(job.get("logFile") or ""))


def scaled_log_number(value: str, binary: bool = False) -> float | None:
    match = re.fullmatch(r"<?\s*([0-9]+(?:\.[0-9]+)?)([kMGT]?)", str(value).strip())
    if not match:
        return None
    base = 1024 if binary else 1000
    powers = {"": 0, "k": 1, "M": 2, "G": 3, "T": 4}
    return float(match.group(1)) * (base ** powers[match.group(2)])


def maintenance_activity(job: dict[str, Any], log: str, stage: str) -> dict[str, Any] | None:
    if stage in {"生成地图瓦片", "生成丰富地点详情"}:
        archive = re.findall(
            r"features:\s*\[\s*(\S+)\s+(\d+)%\s+(\S+/s)\s*\]\s+(\S+)\s+tiles:\s*\[\s*(\S+)\s+(\S+/s)\s*\]\s+(\S+)",
            log,
        )
        if archive:
            feature_count, feature_percent, feature_rate, _, tile_count, tile_rate, output_size = archive[-1]
            output_bytes = scaled_log_number(output_size, binary=True)
            if stage == "生成丰富地点详情":
                existing_products = sorted(
                    MAP_PACK_ROOT.glob(f"{job.get('resourceId')}.details.*.pmtiles"),
                    key=lambda path: path.stat().st_mtime_ns,
                    reverse=True,
                )
                existing_product = existing_products[0] if existing_products else None
            else:
                existing_product = MAP_PACK_ROOT / f"{job.get('resourceId')}.pmtiles"
            expected_bytes = existing_product.stat().st_size if existing_product and existing_product.is_file() else 0
            product_percent = min(99, int((output_bytes or 0) / expected_bytes * 100)) if expected_bytes else None
            if product_percent is None:
                zoom_rows = re.findall(r"last tile:.*\(z(\d+)\s+(\d+)%\)", log)
                if zoom_rows:
                    zoom, zoom_percent = (int(value) for value in zoom_rows[-1])
                    product_percent = min(99, zoom_percent if zoom >= 16 else min(60, zoom * 4))
            return {
                "kind": "generation",
                "rate": scaled_log_number(tile_rate.removesuffix("/s")),
                "unit": "tiles/s",
                "processed": scaled_log_number(tile_count),
                "processedUnit": "tiles",
                "bytes": output_bytes,
                "featureRate": scaled_log_number(feature_rate.removesuffix("/s")),
                "featureCount": scaled_log_number(feature_count),
                "featurePercent": int(feature_percent),
                "percent": product_percent,
            }
        feature_lines = re.findall(r"read:\s*\[\s*(\S+)\s+(\d+)%\s+(\S+/s)\s*\]", log)
        if feature_lines:
            count, percent, rate = feature_lines[-1]
            return {
                "kind": "processing", "rate": scaled_log_number(rate.removesuffix("/s")), "unit": "features/s",
                "processed": scaled_log_number(count), "processedUnit": "features", "percent": int(percent),
            }

    if stage in {"下载行政边界", "下载区域源数据"}:
        error_log = maintenance_file_tail(f"logs/{job.get('id')}.error.log")
        curl_rows: list[tuple[str, str, str, str, str, str]] = []
        for line in error_log.splitlines():
            fields = line.split()
            if len(fields) < 11 or not fields[0].isdigit() or not fields[2].isdigit():
                continue
            curl_rows.append((fields[0], fields[1], fields[2], fields[3], fields[6], fields[-1]))
        if curl_rows:
            _, total, received_percent, received, average_speed, current_speed = curl_rows[-1]
            speed = scaled_log_number(current_speed, binary=True) or scaled_log_number(average_speed, binary=True)
            return {
                "kind": "download", "bytesPerSecond": speed, "receivedBytes": scaled_log_number(received, binary=True),
                "totalBytes": scaled_log_number(total, binary=True), "percent": int(received_percent),
            }
    return None


def maintenance_progress(job: dict[str, Any], queue_position: int | None = None) -> dict[str, Any]:
    status = str(job.get("status") or "")
    if status == "queued":
        operation_steps = {"region-pack": 5, "shared-capabilities": 5, "osm-carto": 4, "nautical": 4, "terrain": 1}
        return {
            "kind": "queued", "percent": 0, "stage": "等待本机维护服务",
            "queuePosition": queue_position, "step": 0, "steps": operation_steps.get(str(job.get("operation")), 1),
        }
    if status == "succeeded":
        return {"kind": "complete", "percent": 100, "stage": "维护完成", "queuePosition": None, "step": 1, "steps": 1}
    if status in {"failed", "cancelled"}:
        return {
            "kind": status, "percent": None, "stage": str(job.get("message") or ("任务失败" if status == "failed" else "任务已取消")),
            "queuePosition": None, "step": None, "steps": None,
        }
    if job.get("cancelRequested"):
        return {"kind": "indeterminate", "percent": None, "stage": "正在安全停止任务", "queuePosition": None, "step": None, "steps": None}
    if status != "running":
        return {"kind": "idle", "percent": None, "stage": str(job.get("message") or ""), "queuePosition": None, "step": None, "steps": None}

    if job.get("operation") == "shared-capabilities":
        log = maintenance_log_text(job)
        stages = (
            ("Promoting validated candidates", 5, 94, "切换已验证的新版本"),
            ("Validating candidate databases", 4, 84, "验证候选搜索与路线索引"),
            ("Building Nominatim candidate", 3, 46, "后台构建搜索候选版本"),
            ("Building Valhalla candidate", 2, 24, "后台构建路线候选版本"),
            ("Building a shared source snapshot", 1, 8, "生成共享源快照"),
        )
        for marker, step, percent, label in stages:
            if marker in log:
                return {
                    "kind": "staged",
                    "percent": percent,
                    "stage": label,
                    "queuePosition": None,
                    "step": step,
                    "steps": 5,
                    "activity": None,
                    "serviceContinuity": True,
                }
        return {
            "kind": "indeterminate", "percent": None, "stage": "准备后台候选索引",
            "queuePosition": None, "step": 0, "steps": 5, "serviceContinuity": True,
        }
    if job.get("operation") == "terrain":
        log = maintenance_log_text(job)
        markers = re.findall(r"ELEVATION_PROGRESS\s+(\d+)/(\d+)\s+([NS]\d{2}[EW]\d{3}\.hgt)", log)
        if markers:
            completed_value, total_value, grid_name = markers[-1]
            completed = int(completed_value)
            total = max(1, int(total_value))
            return {
                "kind": "staged", "percent": min(99, round(completed / total * 100)),
                "stage": f"同步全球高程格网 {grid_name}", "queuePosition": None,
                "step": completed, "steps": total, "serviceContinuity": True,
            }
        return {
            "kind": "indeterminate", "percent": None, "stage": "准备全球高程资源",
            "queuePosition": None, "step": 0, "steps": 1, "serviceContinuity": True,
        }
    if job.get("operation") == "osm-carto":
        log = maintenance_log_text(job)
        markers = re.findall(r"OSM_CARTO_STAGE\s+(\d+)/(\d+)\s+(IMPORT|EXTERNAL|VERIFY|ACTIVATE)", log)
        if markers:
            step_value, steps_value, phase = markers[-1]
            step = int(step_value)
            labels = {
                "IMPORT": "后台导入已安装区域",
                "EXTERNAL": "补齐 OSM Carto 外部图层",
                "VERIFY": "验证候选渲染器与区域瓦片",
                "ACTIVATE": "切换已验证的 OSM 原版数据库",
            }
            return {
                "kind": "staged", "percent": {1: 12, 2: 68, 3: 84, 4: 96}.get(step),
                "stage": labels.get(phase, "重建 OSM 原版渲染"), "queuePosition": None,
                "step": step, "steps": int(steps_value), "serviceContinuity": True,
            }
        return {
            "kind": "indeterminate", "percent": None, "stage": "准备 OSM Carto 候选数据库",
            "queuePosition": None, "step": 0, "steps": 4, "serviceContinuity": True,
        }
    if job.get("operation") == "nautical":
        log = maintenance_log_text(job)
        markers = re.findall(r"NAUTICAL_STAGE\s+(\d+)/(\d+)\s+(FILTER|CACHE|MERGE|EXPORT|VERIFY)(?:\s+(\d+)/(\d+))?", log)
        if markers:
            step_value, steps_value, phase, item_value, total_value = markers[-1]
            step = int(step_value)
            steps = int(steps_value)
            labels = {
                "FILTER": "筛选已安装区域航海要素", "CACHE": "复用区域航海缓存",
                "MERGE": "合并区域航海要素", "EXPORT": "生成航海图层", "VERIFY": "校验并切换航海资源",
            }
            base_percent = {1: 8, 2: 58, 3: 76, 4: 92}.get(step, 5)
            percent = base_percent
            activity = None
            if step == 1 and item_value and total_value:
                processed = int(item_value)
                total = max(1, int(total_value))
                percent = min(55, 8 + round(processed / total * 47))
                activity = {"processed": processed, "total": total, "processedUnit": "区域", "percent": percent}
            return {
                "kind": "staged", "percent": percent, "stage": labels.get(phase, "生成航海资源"),
                "queuePosition": None, "step": step, "steps": steps, "activity": activity,
                "serviceContinuity": True,
            }
        return {
            "kind": "indeterminate", "percent": None, "stage": "读取已安装区域资源",
            "queuePosition": None, "step": 0, "steps": 4, "serviceContinuity": True,
        }
    if job.get("operation") != "region-pack":
        return {"kind": "indeterminate", "percent": None, "stage": "正在执行维护脚本", "queuePosition": None, "step": 1, "steps": 1}
    if job.get("action") == "verify":
        return {"kind": "indeterminate", "percent": None, "stage": "校验地图文件与哈希", "queuePosition": None, "step": 1, "steps": 1}

    log = maintenance_log_text(job)
    detail_markers = re.findall(r"DETAIL_STAGE\s+(\d+)/(\d+)\s+(BUILD|VERIFY|CLEAN)", log)
    if detail_markers:
        _, _, phase = detail_markers[-1]
        labels = {
            "BUILD": "生成丰富地点详情",
            "VERIFY": "校验丰富地点详情",
            "CLEAN": "切换并清理旧详情版本",
        }
        percent = {"BUILD": 88, "VERIFY": 97, "CLEAN": 99}[phase]
        activity = maintenance_activity(job, log, labels[phase]) if phase == "BUILD" else None
        return {
            "kind": "staged", "percent": percent, "stage": labels[phase], "queuePosition": None,
            "step": 5, "steps": 5, "activity": activity, "serviceContinuity": True,
        }
    stages = (
        ("Building staged", 4, 68, "生成地图瓦片"),
        ("Merging ", 3, 48, "合并并检查区域数据"),
        ("Extracting ", 2, 28, "提取行政区域数据"),
        ("Downloading source for ", 1, 10, "下载区域源数据"),
        ("Downloading ", 1, 10, "下载行政边界"),
    )
    for marker, step, percent, label in stages:
        if marker in log:
            activity = maintenance_activity(job, log, label)
            activity_percent = activity.get("percent") if activity else None
            if activity_percent is not None:
                if label == "生成地图瓦片" and activity.get("kind") == "generation":
                    percent = min(96, 68 + round(float(activity_percent) * 0.28))
                elif label == "下载区域源数据":
                    percent = min(27, 10 + round(float(activity_percent) * 0.17))
            return {
                "kind": "staged", "percent": percent, "stage": label, "queuePosition": None, "step": step, "steps": 5,
                "activity": activity,
            }
    return {"kind": "staged", "percent": 5, "stage": "准备区域数据", "queuePosition": None, "step": 1, "steps": 5}


def maintenance_worker_state() -> dict[str, Any]:
    worker = read_json_file(MAINTENANCE_ROOT / "worker.json") or {}
    heartbeat = worker.get("heartbeatAt")
    online = False
    if heartbeat and worker.get("status") == "running":
        try:
            timestamp = datetime.fromisoformat(str(heartbeat).replace("Z", "+00:00"))
            online = (datetime.now().astimezone() - timestamp.astimezone()).total_seconds() < 20
        except ValueError:
            online = False
    return {**worker, "online": online}


def maintenance_snapshot() -> dict[str, Any]:
    jobs = maintenance_jobs()
    queued = sorted(
        (job for job in jobs if job.get("status") == "queued"),
        key=lambda item: (int(item.get("priority") or 100), str(item.get("requestedAt") or "")),
    )
    queue_positions = {str(job.get("id")): index + 1 for index, job in enumerate(queued)}
    enriched_jobs = [
        {**job, "progress": maintenance_progress(job, queue_positions.get(str(job.get("id"))))}
        for job in jobs
    ]
    return {
        "settings": maintenance_settings(),
        "worker": maintenance_worker_state(),
        "jobs": enriched_jobs,
    }


def normalized_geocoder_result(item: dict[str, Any]) -> dict[str, Any]:
    address = item.get("address") if isinstance(item.get("address"), dict) else {}
    extra_tags = item.get("extratags") if isinstance(item.get("extratags"), dict) else {}
    name = item.get("name") or address.get("name") or str(item.get("display_name", "")).split(",", 1)[0]
    try:
        longitude = float(item["lon"])
        latitude = float(item["lat"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Nominatim result has invalid coordinates") from exc
    return {
        "kind": "geocoder",
        "id": f"nominatim-{item.get('place_id', item.get('osm_id', uuid.uuid4()))}",
        "name": name or "未命名地点",
        "subtitle": item.get("display_name", ""),
        "category": item.get("category") or item.get("class", "place"),
        "subtype": item.get("type", ""),
        "longitude": longitude,
        "latitude": latitude,
        "details": {
            "address": address,
            "tags": extra_tags,
            "osm_type": item.get("osm_type"),
            "osm_id": item.get("osm_id"),
            "boundingbox": item.get("boundingbox", []),
        },
    }


def nominatim_search(query: str, limit: int = 10) -> list[dict[str, Any]]:
    items = upstream_json(
        NOMINATIM_URL,
        "/search",
        params={
            "q": query,
            "format": "jsonv2",
            "addressdetails": 1,
            "extratags": 1,
            "namedetails": 1,
            "accept-language": "zh-CN,zh,en",
            "limit": limit,
        },
        timeout=30.0,
    )
    return [normalized_geocoder_result(item) for item in items]


def haversine_meters(start: list[float], end: list[float]) -> float:
    lon1, lat1 = map(math.radians, start[:2])
    lon2, lat2 = map(math.radians, end[:2])
    dlon = lon2 - lon1
    dlat = lat2 - lat1
    value = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6_371_008.8 * 2 * math.asin(math.sqrt(value))


def hgt_name(longitude: float, latitude: float) -> tuple[str, str]:
    lat_floor = math.floor(latitude)
    lon_floor = math.floor(longitude)
    lat_part = f"{'N' if lat_floor >= 0 else 'S'}{abs(lat_floor):02d}"
    lon_part = f"{'E' if lon_floor >= 0 else 'W'}{abs(lon_floor):03d}"
    return lat_part, f"{lat_part}{lon_part}.hgt"


@lru_cache(maxsize=12)
def load_hgt(relative_name: str) -> tuple[int, array] | None:
    path = ELEVATION_ROOT / relative_name
    if not path.is_file():
        return None
    raw = path.read_bytes()
    side = math.isqrt(len(raw) // 2)
    if side * side * 2 != len(raw):
        return None
    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder == "little":
        samples.byteswap()
    return side, samples


@lru_cache(maxsize=256)
def resolve_hgt(folder: str, filename: str) -> str | None:
    for relative_name in (f"{folder}/{filename}", filename):
        if (ELEVATION_ROOT / relative_name).is_file():
            return relative_name
    return None


def elevation_at(longitude: float, latitude: float) -> float | None:
    folder, filename = hgt_name(longitude, latitude)
    relative_name = resolve_hgt(folder, filename)
    loaded = load_hgt(relative_name) if relative_name else None
    if not loaded:
        return None
    side, samples = loaded
    lat_floor = math.floor(latitude)
    lon_floor = math.floor(longitude)
    row = min(side - 1, max(0, int(round((lat_floor + 1 - latitude) * (side - 1)))))
    column = min(side - 1, max(0, int(round((longitude - lon_floor) * (side - 1)))))
    value = samples[row * side + column]
    return None if value <= -32_768 else float(value)


def route_profile(coordinates: list[list[float]], max_samples: int = 180) -> list[dict[str, float | None]]:
    if len(coordinates) < 2:
        return []
    step = max(1, math.ceil(len(coordinates) / max_samples))
    indexes = list(range(0, len(coordinates), step))
    if indexes[-1] != len(coordinates) - 1:
        indexes.append(len(coordinates) - 1)
    profile: list[dict[str, float | None]] = []
    distance = 0.0
    previous = coordinates[indexes[0]]
    for index in indexes:
        coordinate = coordinates[index]
        if profile:
            distance += haversine_meters(previous, coordinate)
        profile.append(
            {
                "distance_m": round(distance, 1),
                "elevation_m": elevation_at(float(coordinate[0]), float(coordinate[1])),
            }
        )
        previous = coordinate
    return profile


def decode_polyline(shape: str, precision: int = 6) -> list[list[float]]:
    coordinates: list[list[float]] = []
    index = 0
    latitude = 0
    longitude = 0
    factor = 10 ** precision
    while index < len(shape):
        deltas = []
        for _ in range(2):
            result = 0
            shift = 0
            while True:
                if index >= len(shape):
                    raise ValueError("Invalid encoded route shape")
                value = ord(shape[index]) - 63
                index += 1
                result |= (value & 0x1F) << shift
                shift += 5
                if value < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        latitude += deltas[0]
        longitude += deltas[1]
        coordinates.append([longitude / factor, latitude / factor])
    return coordinates


def valhalla_geometry(trip: dict[str, Any]) -> list[list[float]]:
    coordinates: list[list[float]] = []
    for leg in trip.get("legs", []):
        shape = leg.get("shape", [])
        if isinstance(shape, dict):
            shape = shape.get("coordinates", [])
        if isinstance(shape, str):
            shape = decode_polyline(shape)
        if not isinstance(shape, list):
            continue
        points = [[float(point[0]), float(point[1])] for point in shape if isinstance(point, list) and len(point) >= 2]
        if coordinates and points and coordinates[-1] == points[0]:
            points = points[1:]
        coordinates.extend(points)
    return coordinates


def tile_coordinate(z: int, x: float, y: float) -> tuple[float, float]:
    scale = 2 ** z
    longitude = x / scale * 360.0 - 180.0
    n = math.pi - 2.0 * math.pi * y / scale
    latitude = math.degrees(math.atan(math.sinh(n)))
    return longitude, latitude


def terrarium_value(elevation: float | None) -> tuple[int, int, int]:
    encoded = max(0.0, min(65_535.996, (elevation if elevation is not None else 0.0) + 32_768.0))
    whole = int(encoded)
    return whole // 256, whole % 256, min(255, int((encoded - whole) * 256))


@lru_cache(maxsize=8192)
def terrain_tile_lock(z: int, x: int, y: int) -> Lock:
    return Lock()


@lru_cache(maxsize=8192)
def tile_intersects_elevation(z: int, x: int, y: int) -> bool:
    west, north = tile_coordinate(z, x, y)
    east, south = tile_coordinate(z, x + 1, y + 1)
    for latitude_floor in range(math.floor(south), math.ceil(north)):
        for longitude_floor in range(math.floor(west), math.ceil(east)):
            folder, filename = hgt_name(longitude_floor + 0.5, latitude_floor + 0.5)
            if resolve_hgt(folder, filename):
                return True
    return False


@lru_cache(maxsize=1)
def empty_terrain_png() -> bytes:
    output = BytesIO()
    Image.new("RGB", (256, 256), terrarium_value(None)).save(output, format="PNG", compress_level=3)
    return output.getvalue()


def render_terrain_pixels(z: int, x: int, y: int) -> bytes:
    longitudes = [tile_coordinate(z, x + (pixel_x + 0.5) / 256, y + 0.5 / 256)[0] for pixel_x in range(256)]
    latitudes = [tile_coordinate(z, x + 0.5 / 256, y + (pixel_y + 0.5) / 256)[1] for pixel_y in range(256)]
    longitude_floors = [math.floor(longitude) for longitude in longitudes]
    longitude_fractions = [longitude - floor for longitude, floor in zip(longitudes, longitude_floors, strict=True)]
    unique_longitude_floors = set(longitude_floors)
    pixels = bytearray(256 * 256 * 3)
    column_cache: dict[tuple[int, int], int] = {}
    active_latitude_floor: int | None = None
    row_grids: dict[int, tuple[int, array] | None] = {}

    for pixel_y, latitude in enumerate(latitudes):
        latitude_floor = math.floor(latitude)
        latitude_fraction = latitude_floor + 1 - latitude
        if latitude_floor != active_latitude_floor:
            active_latitude_floor = latitude_floor
            row_grids = {}
            for longitude_floor in unique_longitude_floors:
                folder, filename = hgt_name(longitude_floor + 0.5, latitude_floor + 0.5)
                relative_name = resolve_hgt(folder, filename)
                row_grids[longitude_floor] = load_hgt(relative_name) if relative_name else None

        row_cache: dict[int, int] = {}
        for pixel_x, longitude_floor in enumerate(longitude_floors):
            loaded = row_grids[longitude_floor]
            value = 0
            if loaded:
                side, samples = loaded
                row = row_cache.get(side)
                if row is None:
                    row = min(side - 1, max(0, int(round(latitude_fraction * (side - 1)))))
                    row_cache[side] = row
                column_key = (pixel_x, side)
                column = column_cache.get(column_key)
                if column is None:
                    column = min(side - 1, max(0, int(round(longitude_fractions[pixel_x] * (side - 1)))))
                    column_cache[column_key] = column
                sample = samples[row * side + column]
                if sample > -32_768:
                    value = sample
            encoded = max(0, min(65_535, value + 32_768))
            offset = (pixel_y * 256 + pixel_x) * 3
            pixels[offset] = encoded // 256
            pixels[offset + 1] = encoded % 256
            pixels[offset + 2] = 0
    return bytes(pixels)


@app.get("/capabilities")
def capabilities() -> dict[str, Any]:
    manifest = capability_manifest()
    scope = shared_index_scope_state()
    elevation_files = sum(1 for _ in ELEVATION_ROOT.rglob("*.hgt")) if ELEVATION_ROOT.is_dir() else 0
    shared_index_usable = scope["verified"] and bool(scope["indexedPackIds"])
    return {
        "source": manifest,
        "services": {
            "geocoder": {"available": shared_index_usable and upstream_available(NOMINATIM_URL, "/status"), "coverageComplete": scope["complete"], "scopeCurrent": scope["current"], "verified": scope["verified"], "missingPackIds": scope["missingPackIds"], "extraPackIds": scope["extraPackIds"]},
            "routing": {"available": shared_index_usable and upstream_available(VALHALLA_URL, "/status"), "coverageComplete": scope["complete"], "scopeCurrent": scope["current"], "verified": scope["verified"], "missingPackIds": scope["missingPackIds"], "extraPackIds": scope["extraPackIds"]},
            "encyclopedia": {"available": upstream_available(KIWIX_URL, "/wiki/")},
            "elevation": {"available": elevation_files > 0, "files": elevation_files},
        },
    }


@app.get("/geocode")
def geocode(
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(default=10, ge=1, le=30),
) -> dict[str, Any]:
    require_usable_shared_index()
    try:
        results = nominatim_search(q.strip(), limit)
    except UpstreamUnavailable as exc:
        raise HTTPException(status_code=503, detail="离线地址索引尚未就绪") from exc
    return {"query": q.strip(), "results": results}


@app.get("/reverse")
def reverse_geocode(
    longitude: float = Query(ge=-180, le=180),
    latitude: float = Query(ge=-90, le=90),
    zoom: int = Query(default=18, ge=3, le=18),
) -> dict[str, Any]:
    require_usable_shared_index()
    try:
        item = upstream_json(
            NOMINATIM_URL,
            "/reverse",
            params={
                "lon": longitude,
                "lat": latitude,
                "zoom": zoom,
                "format": "jsonv2",
                "addressdetails": 1,
                "extratags": 1,
                "accept-language": "zh-CN,zh,en",
            },
            timeout=30.0,
        )
        result = normalized_geocoder_result(item)
    except (UpstreamUnavailable, ValueError) as exc:
        raise HTTPException(status_code=503, detail="离线反向地址索引尚未就绪") from exc
    return result


@app.post("/route")
def create_route(payload: RouteInput) -> dict[str, Any]:
    require_usable_shared_index()
    request_payload = {
        "locations": [
            {"lon": location.longitude, "lat": location.latitude, "type": "break", "name": location.name}
            for location in payload.locations
        ],
        "costing": payload.costing,
        "units": "kilometers",
        "language": payload.language,
        "shape_format": "geojson",
        "directions_options": {"units": "kilometers", "language": payload.language},
    }
    try:
        raw = upstream_json(VALHALLA_URL, "/route", payload=request_payload, timeout=60.0)
    except UpstreamUnavailable as exc:
        raise HTTPException(status_code=503, detail="离线路线引擎尚未就绪") from exc
    trip = raw.get("trip", {})
    coordinates = valhalla_geometry(trip)
    if len(coordinates) < 2:
        raise HTTPException(status_code=422, detail="路线引擎没有返回可用路径")
    maneuvers = []
    for leg in trip.get("legs", []):
        maneuvers.extend(
            {
                "instruction": maneuver.get("instruction", ""),
                "verbal_instruction": maneuver.get("verbal_pre_transition_instruction", ""),
                "length_km": maneuver.get("length", 0),
                "time_s": maneuver.get("time", 0),
                "type": maneuver.get("type"),
                "street_names": maneuver.get("street_names", []),
            }
            for maneuver in leg.get("maneuvers", [])
        )
    return {
        "costing": payload.costing,
        "summary": trip.get("summary", {}),
        "geometry": {"type": "LineString", "coordinates": coordinates},
        "maneuvers": maneuvers,
        "profile": route_profile(coordinates),
        "source": "Valhalla · OpenStreetMap 本地快照",
    }


@app.get("/elevation")
def elevation(
    longitude: float = Query(ge=-180, le=180),
    latitude: float = Query(ge=-90, le=90),
) -> dict[str, Any]:
    value = elevation_at(longitude, latitude)
    if value is None:
        raise HTTPException(status_code=404, detail="该坐标暂无本地高程数据")
    return {"longitude": longitude, "latitude": latitude, "elevation_m": value, "source": "本地全球高程格网"}


@app.get("/terrain/{z}/{x}/{y}.png")
def terrain_tile(z: int, x: int, y: int) -> Response:
    if z < 0 or z > 12 or x < 0 or y < 0 or x >= 2 ** z or y >= 2 ** z:
        raise HTTPException(status_code=404, detail="Terrain tile is outside the supported grid")
    cache_path = TERRAIN_CACHE_ROOT / str(z) / str(x) / f"{y}.png"
    if cache_path.is_file():
        return FileResponse(cache_path, media_type="image/png", headers={"Cache-Control": "public, max-age=604800"})

    with terrain_tile_lock(z, x, y):
        if cache_path.is_file():
            return FileResponse(cache_path, media_type="image/png", headers={"Cache-Control": "public, max-age=604800"})
        if tile_intersects_elevation(z, x, y):
            output = BytesIO()
            Image.frombytes("RGB", (256, 256), render_terrain_pixels(z, x, y)).save(output, format="PNG", compress_level=3)
            content = output.getvalue()
        else:
            content = empty_terrain_png()
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = cache_path.with_suffix(f".{uuid.uuid4().hex}.tmp")
        temporary_path.write_bytes(content)
        temporary_path.replace(cache_path)
    return Response(content=content, media_type="image/png", headers={"Cache-Control": "public, max-age=604800"})


@app.get("/emergency.geojson")
def emergency_geojson(
    categories: str = Query(default="", max_length=120),
    west: float = Query(default=-180, ge=-180, le=180),
    south: float = Query(default=-90, ge=-90, le=90),
    east: float = Query(default=180, ge=-180, le=180),
    north: float = Query(default=90, ge=-90, le=90),
    limit: int = Query(default=3000, ge=1, le=5000),
) -> dict[str, Any]:
    if east <= west or north <= south:
        raise HTTPException(status_code=422, detail="Invalid map bounds")
    selected = [item for item in categories.split(",") if item in {"medical", "security", "shelter", "supplies", "fuel"}]
    with pool.connection() as conn:
        rows = conn.execute(
            """
            WITH classified AS (
              SELECT id, name, category, subtype, tags, geom,
                     CASE
                       WHEN tags->>'amenity' IN ('hospital', 'clinic', 'doctors', 'pharmacy', 'dentist') THEN 'medical'
                       WHEN tags->>'amenity' IN ('police', 'fire_station')
                         OR tags->>'emergency' IN ('ambulance_station', 'fire_station') THEN 'security'
                       WHEN tags->>'amenity' = 'shelter'
                         OR tags->>'emergency' IN ('assembly_point', 'shelter') THEN 'shelter'
                       WHEN tags->>'amenity' IN ('marketplace', 'drinking_water', 'water_point')
                         OR tags->>'shop' IN ('supermarket', 'convenience', 'department_store', 'variety_store') THEN 'supplies'
                       WHEN tags->>'amenity' = 'fuel' OR tags->>'shop' = 'fuel' THEN 'fuel'
                     END AS emergency_category
              FROM app.reference_places
              WHERE geom && ST_MakeEnvelope(%s, %s, %s, %s, 4326)
            )
            SELECT id, name, category, subtype, emergency_category, tags,
                   ST_X(geom) AS longitude, ST_Y(geom) AS latitude
            FROM classified
            WHERE emergency_category IS NOT NULL
              AND (%s::text[] = '{}'::text[] OR emergency_category = ANY(%s::text[]))
            ORDER BY name
            LIMIT %s
            """,
            [west, south, east, north, selected, selected, limit],
        ).fetchall()
    features = [
        {
            "type": "Feature",
            "id": row["id"],
            "properties": {key: value for key, value in row.items() if key not in {"longitude", "latitude", "tags"}} | {"tags": row["tags"]},
            "geometry": {"type": "Point", "coordinates": [row["longitude"], row["latitude"]]},
        }
        for row in rows
    ]
    return {"type": "FeatureCollection", "features": features}


@app.get("/encyclopedia/search")
def encyclopedia_search(q: str = Query(min_length=1, max_length=200)) -> dict[str, Any]:
    if not upstream_available(KIWIX_URL, "/wiki/"):
        raise HTTPException(status_code=503, detail="离线百科尚未就绪")
    return {"query": q.strip(), "url": f"/wiki/search?pattern={urlencode({'q': q.strip()})[2:]}"}


@app.get("/weather")
def weather_snapshot() -> dict[str, Any]:
    payload = read_json_file(WEATHER_RESOURCE_ROOT / "latest.geojson")
    if not payload or payload.get("type") != "FeatureCollection":
        return {"type": "FeatureCollection", "features": [], "properties": {"status": "not-installed"}}
    return payload


@app.get("/nautical")
def nautical_features() -> Any:
    path = NAUTICAL_RESOURCE_ROOT / "seamarks.geojson"
    if not path.is_file():
        return {"type": "FeatureCollection", "features": [], "properties": {"status": "not-installed"}}
    return FileResponse(path, media_type="application/geo+json", headers={"Cache-Control": "public, max-age=3600"})


def current_osm_state() -> dict[str, str]:
    if not OSM_STATE_PATH.is_file():
        return {}
    values: dict[str, str] = {}
    for line in OSM_STATE_PATH.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.replace("\\:", ":")
    return values


def read_state_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value.replace("\\:", ":")
    except OSError:
        return {}
    return values


def source_sequence_relation(remote: str, local: str) -> int | None:
    remote_value = str(remote or "").strip()
    local_value = str(local or "").strip()
    if not remote_value or not local_value:
        return None
    if remote_value == local_value:
        return 0
    try:
        remote_number = int(remote_value)
        local_number = int(local_value)
    except ValueError:
        return None
    return 1 if remote_number > local_number else -1


def osm_catalog_file(relative_path: str) -> Path | None:
    normalized = relative_path.replace("\\", "/").removeprefix("raw/osm/")
    parts = Path(normalized).parts
    if not normalized or normalized.startswith("/") or any(part in {"", ".", ".."} for part in parts):
        return None
    return OSM_ROOT.joinpath(*parts)


def expand_region_dataset(
    unit: dict[str, Any],
    region_catalog: dict[str, Any],
    profiles: dict[str, Any],
    groups: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    defaults = region_catalog.get("defaults", {})
    unit_id = str(unit.get("id", ""))
    profile_id = str(unit.get("sourceProfileId", ""))
    profile = profiles.get(profile_id)
    group = groups.get(str(unit.get("groupId", "")))
    if not unit_id or not isinstance(profile, dict) or not isinstance(group, dict):
        raise HTTPException(status_code=503, detail="Region catalog contains an invalid unit")

    def template(name: str) -> str:
        return str(defaults.get(name, "")).replace("{id}", unit_id)

    source_file = str(profile.get("sourceFile") or template("sourceFileTemplate"))
    polygon_url = str(profile.get("polygonUrl") or template("polygonUrlTemplate"))
    bounds = list(unit.get("bounds", []))
    return {
        **unit,
        "id": unit_id,
        "kind": "province",
        "deprecated": False,
        "countryId": region_catalog.get("countryId"),
        "description": f"{group.get('name')} · 省级独立离线资源",
        "groupName": group.get("name"),
        "groupOrder": group.get("order"),
        "url": template("urlTemplate"),
        "manifestUrl": template("manifestUrlTemplate"),
        "sourceFile": source_file,
        "sourceProfile": profile,
        "members": [{"id": unit_id, "name": unit.get("shortName"), "polygonUrl": polygon_url}],
        "views": [{"id": "all", "label": unit.get("shortName"), "bounds": [bounds[:2], bounds[2:4]]}],
    }


@lru_cache(maxsize=4)
def cached_map_catalog(_revision: tuple[tuple[int, int], ...]) -> dict[str, Any]:
    try:
        catalog = json.loads(MAP_CATALOG_PATH.read_text(encoding="utf-8"))
        region_catalog = json.loads(REGION_CATALOG_PATH.read_text(encoding="utf-8"))
        world_catalog = json.loads(WORLD_REGION_CATALOG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Map pack catalog is unavailable") from exc
    if (
        not isinstance(catalog.get("datasets"), list)
        or not isinstance(region_catalog.get("datasets"), list)
        or not isinstance(world_catalog.get("datasets"), list)
    ):
        raise HTTPException(status_code=503, detail="Map pack catalog is invalid")
    if catalog["datasets"]:
        raise HTTPException(status_code=503, detail="Combination map datasets are not supported")
    profiles = region_catalog.get("sourceProfiles", {})
    groups = {str(item.get("id")): item for item in region_catalog.get("groups", []) if isinstance(item, dict)}
    province_datasets = [
        expand_region_dataset(item, region_catalog, profiles, groups)
        for item in region_catalog["datasets"]
        if isinstance(item, dict)
    ]
    world_datasets = [item for item in world_catalog["datasets"] if isinstance(item, dict)]
    datasets = province_datasets + world_datasets
    ids = [str(item.get("id")) for item in datasets]
    if len(ids) != len(set(ids)):
        raise HTTPException(status_code=503, detail="Map pack catalog contains duplicate ids")
    return {
        **catalog,
        "schemaVersion": 3,
        "version": f"{catalog.get('version')}+{region_catalog.get('version')}+{world_catalog.get('version')}",
        "datasets": datasets,
        "regionCatalog": {
            "version": region_catalog.get("version"),
            "countryId": region_catalog.get("countryId"),
            "unitLevel": region_catalog.get("unitLevel"),
            "groups": region_catalog.get("groups", []),
        },
    }


def map_catalog() -> dict[str, Any]:
    revision: list[tuple[int, int]] = []
    for path in (MAP_CATALOG_PATH, REGION_CATALOG_PATH, WORLD_REGION_CATALOG_PATH):
        try:
            stat = path.stat()
            revision.append((stat.st_size, stat.st_mtime_ns))
        except OSError:
            revision.append((-1, -1))
    return cached_map_catalog(tuple(revision))


def pack_file(url: str) -> Path:
    filename = Path(url).name
    if not filename or filename != url.rstrip("/").rsplit("/", 1)[-1]:
        raise HTTPException(status_code=503, detail="Map pack catalog contains an unsafe path")
    return MAP_PACK_ROOT / filename


def map_pack_preferences() -> dict[str, Any]:
    stored = read_json_file(MAP_PACK_STATE_PATH) or {}
    disabled = stored.get("disabledPackIds", [])
    return {
        "schemaVersion": 1,
        "disabledPackIds": sorted({str(item) for item in disabled if item}),
        "updatedAt": stored.get("updatedAt"),
    }


def set_map_pack_enabled(pack_id: str, enabled: bool) -> dict[str, Any]:
    preferences = map_pack_preferences()
    disabled = set(preferences["disabledPackIds"])
    if enabled:
        disabled.discard(pack_id)
    else:
        disabled.add(pack_id)
    preferences.update({
        "disabledPackIds": sorted(disabled),
        "updatedAt": datetime.now().astimezone().isoformat(),
    })
    write_json_file(MAP_PACK_STATE_PATH, preferences)
    invalidate_resource_inventory()
    return preferences


def resource_inventory_revision() -> str:
    marker = read_json_file(RESOURCE_INVENTORY_REVISION_PATH) or {}
    signatures: list[tuple[str, int, int]] = []
    try:
        paths = sorted(
            path for path in MAP_PACK_ROOT.iterdir()
            if path.is_file() and ".staged." not in path.name and ".swap-" not in path.name
        )
    except OSError:
        paths = []
    for path in paths:
        try:
            stat = path.stat()
            signatures.append((path.name, stat.st_size, stat.st_mtime_ns))
        except OSError:
            continue
    state_signature: tuple[int, int] | None = None
    try:
        stat = MAP_PACK_STATE_PATH.stat()
        state_signature = (stat.st_size, stat.st_mtime_ns)
    except OSError:
        pass
    payload = json.dumps(
        {
            "schema": RESOURCE_INVENTORY_SCHEMA,
            "marker": marker.get("revision"),
            "mapPacks": signatures,
            "preferences": state_signature,
        },
        ensure_ascii=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def invalidate_resource_inventory() -> None:
    write_json_file(
        RESOURCE_INVENTORY_REVISION_PATH,
        {"revision": uuid.uuid4().hex, "changedAt": datetime.now().astimezone().isoformat()},
    )


LEGACY_PACK_REPLACEMENTS = {
    "suwan": {"name": "苏皖组合包", "replacementIds": ["jiangsu", "anhui"]},
    "huzhe": {"name": "沪浙组合包", "replacementIds": ["shanghai", "zhejiang"]},
}


def legacy_map_packages(catalog: dict[str, Any], packs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    catalog_ids = {str(item.get("id")) for item in catalog.get("datasets", [])}
    pack_by_id = {str(item.get("id")): item for item in packs}
    legacy: list[dict[str, Any]] = []
    for pack_id, guidance in LEGACY_PACK_REPLACEMENTS.items():
        product = MAP_PACK_ROOT / f"{pack_id}.pmtiles"
        manifest = MAP_PACK_ROOT / f"{pack_id}.manifest.json"
        if pack_id in catalog_ids or (not product.is_file() and not manifest.is_file()):
            continue
        replacements = [
            {
                "id": replacement_id,
                "name": pack_by_id.get(replacement_id, {}).get("name") or replacement_id,
                "installed": bool(pack_by_id.get(replacement_id, {}).get("installed")),
            }
            for replacement_id in guidance["replacementIds"]
        ]
        legacy.append({
            "id": pack_id,
            "name": guidance["name"],
            "bytes": (product.stat().st_size if product.is_file() else 0) + (manifest.stat().st_size if manifest.is_file() else 0),
            "files": [path.name for path in (product, manifest) if path.is_file()],
            "replacementPacks": replacements,
            "readyToRemove": all(item["installed"] for item in replacements),
            "reason": "旧组合区域包已由可独立维护的省级地图包替代",
        })
    return legacy


def map_pack_state(
    dataset: dict[str, Any],
    verify_sha256: bool = False,
    *,
    known_pack_files: set[str] | None = None,
    known_osm_files: set[str] | None = None,
    known_polygon_files: set[str] | None = None,
    common_state: dict[str, str] | None = None,
    disabled_pack_ids: set[str] | None = None,
) -> dict[str, Any]:
    preference_enabled = str(dataset.get("id")) not in (disabled_pack_ids if disabled_pack_ids is not None else set(map_pack_preferences()["disabledPackIds"]))
    product_path = pack_file(str(dataset.get("url", "")))
    manifest_path = pack_file(str(dataset.get("manifestUrl", "")))
    manifest = None
    manifest_exists_on_disk = manifest_path.name in known_pack_files if known_pack_files is not None else manifest_path.is_file()
    if manifest_exists_on_disk:
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            manifest = None
    product_exists = product_path.name in known_pack_files if known_pack_files is not None else product_path.is_file()
    manifest_exists = manifest is not None
    installed = product_exists and manifest_exists
    enabled = installed and preference_enabled
    actual_bytes = product_path.stat().st_size if product_exists else 0
    expected_product = manifest.get("product", {}) if manifest else {}
    expected_bytes = int(expected_product.get("bytes", 0) or 0)
    expected_details = manifest.get("details", {}) if manifest and isinstance(manifest.get("details"), dict) else {}
    details_path = pack_file(str(expected_details.get("url") or expected_details.get("file"))) if expected_details else None
    details_exists = bool(details_path and details_path.is_file())
    details_bytes = details_path.stat().st_size if details_exists else 0
    expected_details_bytes = int(expected_details.get("bytes", 0) or 0)
    details_size_matches = bool(
        details_exists and expected_details_bytes > 0 and details_bytes == expected_details_bytes
    )
    rich_details_ready = bool(expected_details and details_size_matches)
    size_matches = bool(
        installed and expected_bytes > 0 and actual_bytes == expected_bytes and rich_details_ready
    )
    verification = "not-run"
    if verify_sha256 and installed:
        digest = hashlib.sha256()
        with product_path.open("rb") as stream:
            for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
                digest.update(block)
        details_digest = hashlib.sha256()
        if details_exists:
            with details_path.open("rb") as stream:
                for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
                    details_digest.update(block)
        verification = "verified" if (
            size_matches
            and digest.hexdigest() == expected_product.get("sha256")
            and details_digest.hexdigest() == expected_details.get("sha256")
        ) else "failed"
    source_profile = dataset.get("sourceProfile", {}) if isinstance(dataset.get("sourceProfile"), dict) else {}
    state_path = osm_catalog_file(str(source_profile.get("stateFile", "")))
    snapshot_path = osm_catalog_file(str(source_profile.get("snapshotFile", "")))
    snapshot_relative = snapshot_path.relative_to(OSM_ROOT).as_posix() if snapshot_path else ""
    source_ready = bool(snapshot_path and (snapshot_relative in known_osm_files if known_osm_files is not None else snapshot_path.is_file()))
    source_acquirable = source_ready or bool(source_profile.get("mode") == "direct" and source_profile.get("snapshotUrl"))
    state_relative = state_path.relative_to(OSM_ROOT).as_posix() if state_path else ""
    state_ready = bool(state_path and (state_relative in known_osm_files if known_osm_files is not None else state_path.is_file()))
    current_state = read_state_file(state_path) if state_ready else (common_state or {}) if source_profile.get("mode") != "direct" else {}
    boundary_ready = source_profile.get("mode") == "direct" or all(
        bool(member.get("id")) and (
            f"{member.get('id')}.poly" in known_polygon_files
            if known_polygon_files is not None
            else (OSM_ROOT / "polygons" / f"{member.get('id')}.poly").is_file()
        )
        for member in dataset.get("members", [])
        if isinstance(member, dict)
    )
    source = manifest.get("source", {}) if manifest else {}
    source_sequence = str(source.get("sequenceNumber") or "")
    current_sequence = str(current_state.get("sequenceNumber") or "")
    sequence_relation = source_sequence_relation(current_sequence, source_sequence)
    update_available = bool(installed and sequence_relation is not None and sequence_relation > 0)
    previous_product_path = MAP_PACK_ROOT / f"{dataset.get('id')}.previous.pmtiles"
    previous_manifest_path = MAP_PACK_ROOT / f"{dataset.get('id')}.previous.manifest.json"
    previous_product_exists = previous_product_path.name in known_pack_files if known_pack_files is not None else previous_product_path.is_file()
    previous_manifest_exists = previous_manifest_path.name in known_pack_files if known_pack_files is not None else previous_manifest_path.is_file()
    previous_manifest = read_json_file(previous_manifest_path) if previous_manifest_exists else None
    rollback_details = previous_manifest.get("details", {}) if previous_manifest and isinstance(previous_manifest.get("details"), dict) else {}
    rollback_details_path = pack_file(str(rollback_details.get("url") or rollback_details.get("file"))) if rollback_details else None
    rollback_details_exists = bool(rollback_details_path and rollback_details_path.is_file())
    rollback_details_bytes = rollback_details_path.stat().st_size if rollback_details_exists else 0
    rollback_artifacts = previous_product_exists or previous_manifest is not None or rollback_details_exists
    rollback_ready = bool(
        previous_product_exists
        and previous_manifest is not None
        and rollback_details
        and rollback_details_exists
    )
    staged_product_path = MAP_PACK_ROOT / f"{dataset.get('id')}.staged.pmtiles"
    if known_pack_files is not None:
        artifact_names = {
            product_path.name, manifest_path.name, previous_product_path.name,
            previous_manifest_path.name, staged_product_path.name,
        }
        if details_path:
            artifact_names.add(details_path.name)
        has_local_artifacts = bool(artifact_names & known_pack_files) or any(
            name.startswith(f"{dataset.get('id')}.swap-") for name in known_pack_files
        )
    else:
        has_local_artifacts = any(
            path.is_file()
            for path in (product_path, manifest_path, previous_product_path, previous_manifest_path, staged_product_path)
        ) or any(MAP_PACK_ROOT.glob(f"{dataset.get('id')}.swap-*"))
    rollback_product = previous_manifest.get("product", {}) if previous_manifest else {}
    rollback_source = previous_manifest.get("source", {}) if previous_manifest else {}
    return {
        "id": dataset.get("id"),
        "name": dataset.get("name"),
        "shortName": dataset.get("shortName"),
        "description": dataset.get("description", ""),
        "kind": dataset.get("kind", "province"),
        "deprecated": bool(dataset.get("deprecated", False)),
        "countryId": dataset.get("countryId"),
        "administrativeType": dataset.get("administrativeType"),
        "abbreviation": dataset.get("abbreviation"),
        "groupId": dataset.get("groupId"),
        "groupName": dataset.get("groupName"),
        "groupOrder": dataset.get("groupOrder"),
        "order": dataset.get("order"),
        "url": dataset.get("url"),
        "manifestUrl": dataset.get("manifestUrl"),
        "sourceFile": dataset.get("sourceFile"),
        "members": [
            {"id": member.get("id"), "name": member.get("name")}
            for member in dataset.get("members", [])
            if isinstance(member, dict)
        ],
        "bounds": dataset.get("bounds", []),
        "views": dataset.get("views", []),
        "estimatedInstallGiB": dataset.get("estimatedInstallGiB", []),
        "estimatedTemporaryGiB": dataset.get("estimatedTemporaryGiB"),
        "estimatedBuildMinutes": dataset.get("estimatedBuildMinutes", []),
        "sourceSizeMiB": dataset.get("sourceSizeMiB"),
        "sourceProvider": source_profile.get("provider"),
        "sourceMode": source_profile.get("mode", "extract"),
        "sourceSnapshotFile": source_profile.get("snapshotFile"),
        "sourceReady": source_ready,
        "boundariesReady": boundary_ready,
        "buildReady": source_acquirable and boundary_ready,
        "installed": installed,
        "enabled": enabled,
        "hasLocalArtifacts": has_local_artifacts,
        "partialInstall": product_exists != manifest_exists or bool(expected_details and not details_exists),
        "bytes": actual_bytes + details_bytes,
        "productBytes": actual_bytes,
        "detailsBytes": details_bytes,
        "detailsUrl": expected_details.get("url") if rich_details_ready else None,
        "detailsLayer": expected_details.get("layer") if rich_details_ready else None,
        "richDetailsReady": rich_details_ready,
        "detailsSizeMatches": details_size_matches,
        "sizeMatches": size_matches,
        "verification": verification,
        "updateAvailable": update_available,
        "generatedAt": manifest.get("generatedAt") if manifest else None,
        "sourceUpdatedAt": source.get("updatedAt") if source else None,
        "sourceSha256": source.get("sha256") if source else None,
        "sourceSequence": source_sequence or None,
        "currentSourceSequence": current_sequence or None,
        "currentSourceUpdatedAt": current_state.get("timestamp"),
        "rollbackReady": rollback_ready,
        "rollbackArtifacts": rollback_artifacts,
        "rollbackBytes": (previous_product_path.stat().st_size if previous_product_exists else 0) + rollback_details_bytes,
        "rollbackGeneratedAt": previous_manifest.get("generatedAt") if previous_manifest else None,
        "rollbackSourceSequence": rollback_source.get("sequenceNumber") if rollback_source else None,
        "rollbackSourceUpdatedAt": rollback_source.get("updatedAt") if rollback_source else None,
        "rollbackSizeMatches": bool(
            rollback_ready
            and int(rollback_product.get("bytes", 0) or 0) == previous_product_path.stat().st_size
            and int(rollback_details.get("bytes", 0) or 0) == rollback_details_bytes
        ),
    }


def map_pack_states(catalog: dict[str, Any], verify_sha256: bool = False) -> list[dict[str, Any]]:
    disabled_pack_ids = set(map_pack_preferences()["disabledPackIds"])
    try:
        known_pack_files = {entry.name for entry in MAP_PACK_ROOT.iterdir() if entry.is_file()}
    except OSError:
        known_pack_files = set()
    known_osm_files: set[str] = set()
    if OSM_ROOT.is_dir():
        for root, _, filenames in os.walk(OSM_ROOT):
            relative_root = Path(root).relative_to(OSM_ROOT).as_posix()
            known_osm_files.update(f"{relative_root}/{filename}".removeprefix("./") for filename in filenames)
    polygon_root = OSM_ROOT / "polygons"
    try:
        known_polygon_files = {entry.name for entry in polygon_root.iterdir() if entry.is_file()}
    except OSError:
        known_polygon_files = set()
    common_state = current_osm_state()
    packs = [
        map_pack_state(
            dataset,
            verify_sha256=verify_sha256,
            known_pack_files=known_pack_files,
            known_osm_files=known_osm_files,
            known_polygon_files=known_polygon_files,
            common_state=common_state,
            disabled_pack_ids=disabled_pack_ids,
        )
        for dataset in catalog["datasets"]
    ]
    for pack in packs:
        pack["coveragePackIds"] = []
        pack["coveragePackNames"] = []
        pack["covered"] = bool(pack["installed"])
        pack["coverageMode"] = "independent" if pack["installed"] else "none"
        pack["browsePackId"] = str(pack["id"]) if pack["installed"] else None
    return packs


def map_pack_state_for_id(catalog: dict[str, Any], pack_id: str) -> dict[str, Any] | None:
    dataset = next((item for item in catalog["datasets"] if str(item.get("id")) == pack_id), None)
    if dataset is None:
        return None
    return map_pack_state(
        dataset,
        common_state=current_osm_state(),
        disabled_pack_ids=set(map_pack_preferences()["disabledPackIds"]),
    )


def installed_map_pack_states(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    try:
        known_pack_files = {entry.name for entry in MAP_PACK_ROOT.iterdir() if entry.is_file()}
    except OSError:
        known_pack_files = set()
    disabled_pack_ids = set(map_pack_preferences()["disabledPackIds"])
    common_state = current_osm_state()
    states: list[dict[str, Any]] = []
    for dataset in catalog["datasets"]:
        if Path(str(dataset.get("url") or "")).name not in known_pack_files:
            continue
        state = map_pack_state(
            dataset,
            known_pack_files=known_pack_files,
            common_state=common_state,
            disabled_pack_ids=disabled_pack_ids,
        )
        if state["installed"]:
            states.append(state)
    return states


def read_osmosis_poly(path: Path) -> dict[str, list[list[list[float]]]]:
    include: list[list[list[float]]] = []
    exclude: list[list[list[float]]] = []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    index = 1
    while index < len(lines):
        ring_name = lines[index].strip()
        index += 1
        if not ring_name or ring_name == "END":
            continue
        ring: list[list[float]] = []
        while index < len(lines):
            line = lines[index].strip()
            index += 1
            if line == "END":
                break
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                ring.append([float(parts[0]), float(parts[1])])
            except ValueError:
                continue
        if len(ring) >= 3:
            (exclude if ring_name.startswith("!") else include).append(ring)
    return {"include": include, "exclude": exclude}


def map_pack_boundary_revision() -> tuple[tuple[str, int, int], ...]:
    polygon_root = OSM_ROOT / "polygons"
    try:
        paths = sorted(polygon_root.glob("*.poly"))
    except OSError:
        paths = []
    revision = []
    for path in paths:
        try:
            stat = path.stat()
            revision.append((path.name, stat.st_size, stat.st_mtime_ns))
        except OSError:
            continue
    return tuple(revision)


def cached_json_headers(etag: str) -> dict[str, str]:
    return {"Cache-Control": "no-cache", "ETag": etag}


def cached_json_response(request: StarletteRequest, content: bytes, etag: str) -> Response:
    headers = cached_json_headers(etag)
    client_etags = {
        candidate.strip()
        for candidate in request.headers.get("if-none-match", "").split(",")
        if candidate.strip()
    }
    if etag in client_etags or etag.strip('"') in client_etags or "*" in client_etags:
        return Response(status_code=304, headers=headers)
    return Response(content=content, media_type="application/json", headers=headers)


@lru_cache(maxsize=4)
def cached_map_pack_boundaries(_revision: tuple[tuple[str, int, int], ...]) -> tuple[bytes, str]:
    polygon_root = OSM_ROOT / "polygons"
    boundaries: dict[str, Any] = {}
    if polygon_root.is_dir():
        for path in sorted(polygon_root.glob("*.poly")):
            try:
                boundary = read_osmosis_poly(path)
            except OSError:
                continue
            if boundary["include"]:
                boundaries[path.stem] = boundary
    content = json.dumps({"boundaries": boundaries}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return content, f'"{hashlib.sha256(content).hexdigest()}"'


@app.get("/map-pack-boundaries")
def list_map_pack_boundaries(request: StarletteRequest) -> Response:
    content, etag = cached_map_pack_boundaries(map_pack_boundary_revision())
    return cached_json_response(request, content, etag)


def build_map_pack_payload() -> dict[str, Any]:
    catalog = map_catalog()
    packs = map_pack_states(catalog)
    osm_carto_manifest = read_json_file(OSM_CARTO_MANIFEST_PATH) or {}
    osm_carto_source = osm_carto_manifest.get("source") if isinstance(osm_carto_manifest.get("source"), dict) else {}
    osm_carto_pack_ids = sorted({str(pack_id) for pack_id in osm_carto_source.get("regions", []) if pack_id})
    datasets_by_id = {str(item.get("id")): item for item in catalog["datasets"]}
    upstream = read_json_file(MAINTENANCE_ROOT / "upstream-state.json") or {}
    upstream_sources = upstream.get("sources") if isinstance(upstream.get("sources"), dict) else {}
    for pack in packs:
        dataset = datasets_by_id.get(str(pack["id"]), {})
        profile = dataset.get("sourceProfile", {}) if isinstance(dataset.get("sourceProfile"), dict) else {}
        remote = upstream_sources.get(str(profile.get("stateUrl") or ""), {})
        remote_sequence = str(remote.get("sequenceNumber") or "")
        installed_sequence = str(pack.get("sourceSequence") or "")
        sequence_relation = source_sequence_relation(remote_sequence, installed_sequence)
        pack["upstreamSourceSequence"] = remote_sequence or None
        pack["upstreamSourceUpdatedAt"] = remote.get("timestamp")
        pack["lastCheckedAt"] = remote.get("checkedAt") or upstream.get("checkedAt")
        pack["updateError"] = remote.get("error")
        if pack["installed"] and sequence_relation is not None:
            pack["updateAvailable"] = sequence_relation > 0
            pack["updateStatus"] = "upstream" if sequence_relation > 0 else "current" if sequence_relation == 0 else "local-newer"
        elif pack["installed"]:
            pack["updateStatus"] = "unknown"
    provinces = [pack for pack in packs if pack["kind"] == "province"]
    return {
        "activeDataset": catalog.get("activeDataset"),
        "catalogVersion": catalog.get("version"),
        "installed": sum(1 for pack in packs if pack["installed"]),
        "provinceCount": len(provinces),
        "independentProvinceCount": sum(1 for pack in provinces if pack["installed"]),
        "coveredProvinceCount": sum(1 for pack in provinces if pack["covered"]),
        "osmCartoPackIds": osm_carto_pack_ids,
        "packs": packs,
        "legacyPackages": legacy_map_packages(catalog, packs),
    }


def file_revision(path: Path) -> tuple[int, int]:
    try:
        stat = path.stat()
        return stat.st_size, stat.st_mtime_ns
    except OSError:
        return -1, -1


def map_pack_payload_revision() -> tuple[Any, ...]:
    return (
        resource_inventory_revision(),
        *(file_revision(path) for path in (MAP_CATALOG_PATH, REGION_CATALOG_PATH, WORLD_REGION_CATALOG_PATH)),
        file_revision(MAINTENANCE_ROOT / "upstream-state.json"),
        file_revision(OSM_CARTO_MANIFEST_PATH),
    )


@lru_cache(maxsize=4)
def cached_map_pack_payload(_revision: tuple[Any, ...]) -> tuple[bytes, str]:
    content = json.dumps(build_map_pack_payload(), ensure_ascii=False, separators=(",", ":"), default=str).encode("utf-8")
    return content, f'"{hashlib.sha256(content).hexdigest()}"'


@app.get("/map-packs")
def list_map_packs(request: StarletteRequest) -> Response:
    content, etag = cached_map_pack_payload(map_pack_payload_revision())
    return cached_json_response(request, content, etag)


def warm_map_catalog_caches() -> None:
    sleep(5)
    try:
        cached_map_pack_payload(map_pack_payload_revision())
        cached_map_pack_boundaries(map_pack_boundary_revision())
    except Exception:
        pass


@app.on_event("startup")
def schedule_map_catalog_cache_warmup() -> None:
    Thread(target=warm_map_catalog_caches, name="map-catalog-warmup", daemon=True).start()


@app.put("/map-packs/{pack_id}/activation")
def update_map_pack_activation(pack_id: str, payload: MapPackActivationInput) -> dict[str, Any]:
    catalog = map_catalog()
    installed_states = installed_map_pack_states(catalog)
    packs = {str(pack["id"]): pack for pack in installed_states}
    pack = packs.get(pack_id) or map_pack_state_for_id(catalog, pack_id)
    if not pack:
        raise HTTPException(status_code=404, detail="Map pack not found")
    if not pack["installed"]:
        raise HTTPException(status_code=409, detail="Only installed map packs can be activated or deactivated")
    if any(job.get("resourceId") == pack_id and job.get("status") in {"queued", "running"} for job in maintenance_jobs()):
        raise HTTPException(status_code=409, detail="Map pack activation cannot change while a maintenance task is active")
    enabled_installed = [item for item in packs.values() if item["installed"] and item["enabled"]]
    if not payload.enabled and pack["enabled"] and len(enabled_installed) <= 1:
        raise HTTPException(status_code=409, detail="At least one installed map pack must remain enabled")
    set_map_pack_enabled(pack_id, payload.enabled)
    queued_derivatives = queue_lightweight_region_derivatives(f"map-pack-activation:{pack_id}")
    updated = map_pack_state(
        next(item for item in catalog["datasets"] if str(item.get("id")) == pack_id),
        disabled_pack_ids=set(map_pack_preferences()["disabledPackIds"]),
    )
    return {
        **updated,
        "indexRebuildRequired": True,
        "queuedDerivatives": queued_derivatives,
        "message": "渲染状态已更新；搜索与路线索引需要按新的启用范围重建",
    }


@app.get("/map-packs/{pack_id}/manifest")
def get_map_pack_manifest(pack_id: str) -> dict[str, Any]:
    catalog = map_catalog()
    dataset = next((item for item in catalog["datasets"] if str(item.get("id")) == pack_id), None)
    if not dataset:
        raise HTTPException(status_code=404, detail="Map pack not found")
    manifest = read_json_file(pack_file(str(dataset.get("manifestUrl", ""))))
    if not manifest:
        raise HTTPException(status_code=404, detail="Map pack manifest is not installed")
    state = map_pack_state(dataset)
    return {
        **manifest,
        "management": {
            "enabled": state["enabled"],
            "exportedAt": datetime.now().astimezone().isoformat(),
            "disasterRecoveryBaseline": "full-snapshot",
        },
    }


@app.get("/map-packs/{pack_id}/versions")
def get_map_pack_versions(pack_id: str) -> dict[str, Any]:
    catalog = map_catalog()
    dataset = next((item for item in catalog["datasets"] if str(item.get("id")) == pack_id), None)
    if not dataset:
        raise HTTPException(status_code=404, detail="Map pack not found")
    state = map_pack_state(dataset)
    history_root = MAP_PACK_ROOT / "history" / pack_id
    history = []
    if history_root.is_dir():
        for path in sorted(history_root.glob("*.manifest.json"), reverse=True):
            manifest = read_json_file(path)
            if not manifest:
                continue
            history.append({
                "id": path.stem,
                "kind": "manifest",
                "generatedAt": manifest.get("generatedAt"),
                "sourceSequence": (manifest.get("source") or {}).get("sequenceNumber"),
                "sourceUpdatedAt": (manifest.get("source") or {}).get("updatedAt"),
                "bytes": (manifest.get("product") or {}).get("bytes"),
                "sha256": (manifest.get("product") or {}).get("sha256"),
            })
    return {
        "id": pack_id,
        "current": {
            "generatedAt": state.get("generatedAt"),
            "sourceSequence": state.get("sourceSequence"),
            "sourceUpdatedAt": state.get("sourceUpdatedAt"),
            "bytes": state.get("bytes"),
            "sizeMatches": state.get("sizeMatches"),
        },
        "rollback": {
            "ready": state.get("rollbackReady"),
            "generatedAt": state.get("rollbackGeneratedAt"),
            "sourceSequence": state.get("rollbackSourceSequence"),
            "sourceUpdatedAt": state.get("rollbackSourceUpdatedAt"),
            "bytes": state.get("rollbackBytes"),
            "sizeMatches": state.get("rollbackSizeMatches"),
        },
        "history": history[:50],
    }


def cache_inventory(precomputed: dict[str, dict[str, int]] | None = None) -> list[dict[str, Any]]:
    definitions = [
        ("terrain-tiles", "地形瓦片缓存", TERRAIN_CACHE_ROOT, "浏览等高线时自动重新生成"),
        ("build-temp", "地图构建临时缓存", BUILD_CACHE_ROOT, "地图包构建时自动重新生成"),
    ]
    items = []
    for cache_id, name, path, description in definitions:
        usage = (precomputed or {}).get(cache_id) or directory_usage(path)
        items.append({
            "id": cache_id, "name": name, "pathLabel": path.name,
            "bytes": usage["bytes"], "files": usage["files"],
            "description": description, "regenerable": True,
        })
    inventory_usage = {"bytes": 0, "files": 0}
    try:
        inventory_usage = {"bytes": RESOURCE_INVENTORY_CACHE_PATH.stat().st_size, "files": 1}
    except OSError:
        pass
    items.append({
        "id": "resource-inventory", "name": "资源盘点缓存", "pathLabel": RESOURCE_INVENTORY_CACHE_PATH.name,
        "bytes": inventory_usage["bytes"], "files": inventory_usage["files"],
        "description": "再次打开资源管理页时自动重建", "regenerable": True,
    })
    return items


def offline_kit_usage() -> dict[str, int]:
    return directory_usage(OFFLINE_KIT_ROOT)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def declared_file_state(
    root: Path,
    manifest: dict[str, Any],
    filename: str,
    *,
    hash_small_files: bool = False,
) -> dict[str, Any]:
    path = root / Path(filename).name
    expected_bytes = int(manifest.get("bytes", 0) or 0)
    expected_sha256 = str(manifest.get("sha256") or "").lower()
    if not path.is_file():
        return {"valid": False, "reason": "payload-missing", "path": path}
    actual_bytes = path.stat().st_size
    if expected_bytes <= 0 or actual_bytes != expected_bytes:
        return {"valid": False, "reason": "size-mismatch", "path": path}
    if hash_small_files and expected_sha256 and actual_bytes <= 64 * 1024 * 1024:
        if sha256_file(path) != expected_sha256:
            return {"valid": False, "reason": "checksum-mismatch", "path": path}
        verification = "sha256"
    else:
        verification = "manifest-size"
    return {"valid": True, "reason": verification, "path": path}


def offline_kit_is_verified(kit_path: Path) -> bool:
    manifest_path = kit_path / "manifest.json"
    verification = read_json_file(kit_path / "verification.json") or {}
    if not manifest_path.is_file() or verification.get("status") != "verified":
        return False
    return str(verification.get("manifestSha256") or "").lower() == sha256_file(manifest_path)


def selected_file_usage(paths: list[Path]) -> dict[str, int]:
    unique_files = {path.resolve() for path in paths if path.is_file()}
    return {
        "bytes": sum(path.stat().st_size for path in unique_files),
        "files": len(unique_files),
    }


@app.get("/caches")
def list_caches() -> dict[str, Any]:
    items = cache_inventory()
    return {"items": items, "totalBytes": sum(int(item["bytes"]) for item in items)}


@app.delete("/caches/{cache_id}")
def clear_cache(cache_id: str, confirm: str = Query(default="")) -> dict[str, Any]:
    if confirm != cache_id:
        raise HTTPException(status_code=409, detail="Cache clear confirmation token is missing")
    active_jobs = [job for job in maintenance_jobs() if job.get("status") in {"queued", "running"}]
    if cache_id == "build-temp" and active_jobs:
        raise HTTPException(status_code=409, detail="Build cache cannot be cleared while maintenance jobs are active")
    if cache_id == "resource-inventory":
        RESOURCE_INVENTORY_CACHE_PATH.unlink(missing_ok=True)
    else:
        roots = {"terrain-tiles": TERRAIN_CACHE_ROOT, "build-temp": BUILD_CACHE_ROOT}
        root = roots.get(cache_id)
        if root is None:
            raise HTTPException(status_code=404, detail="Unknown cache")
        root.mkdir(parents=True, exist_ok=True)
        for child in root.iterdir():
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink(missing_ok=True)
    invalidate_resource_inventory()
    return {"id": cache_id, "cleared": True, "clearedAt": datetime.now().astimezone().isoformat()}


def build_resource_inventory(check_upstream: bool = False) -> dict[str, Any]:
    inventory_revision = resource_inventory_revision()
    catalog = map_catalog()
    packs = map_pack_states(catalog)
    installed_packs = [pack for pack in packs if pack["installed"]]
    enabled_installed_packs = [pack for pack in installed_packs if pack["enabled"]]
    province_packs = [pack for pack in packs if pack["kind"] == "province"]
    current_state = current_osm_state()
    capability = capability_manifest() or {}
    capability_ids = {
        str(item.get("id"))
        for item in capability.get("inputs", [])
        if isinstance(item, dict) and item.get("id")
    }
    datasets_by_id = {str(item.get("id")): item for item in catalog["datasets"]}
    installed_ids = {str(pack["id"]) for pack in enabled_installed_packs}
    upstream_cache = upstream_source_states(catalog, installed_ids, check_upstream, MAINTENANCE_ROOT / "upstream-state.json")
    upstream_sources = upstream_cache.get("sources") or {}
    for pack in installed_packs:
        dataset = datasets_by_id.get(str(pack["id"]), {})
        profile = dataset.get("sourceProfile", {}) if isinstance(dataset.get("sourceProfile"), dict) else {}
        state_url = str(profile.get("stateUrl") or "")
        remote_state = upstream_sources.get(state_url, {}) if state_url else {}
        remote_sequence = str(remote_state.get("sequenceNumber") or "")
        local_sequence = str(pack.get("sourceSequence") or "")
        sequence_relation = source_sequence_relation(remote_sequence, local_sequence)
        checked_at = remote_state.get("checkedAt") or upstream_cache.get("checkedAt")
        if sequence_relation is not None:
            pack["updateAvailable"] = sequence_relation > 0
            pack["updateStatus"] = "upstream" if sequence_relation > 0 else "current" if sequence_relation == 0 else "local-newer"
            pack["upstreamSourceSequence"] = remote_sequence
            pack["upstreamSourceUpdatedAt"] = remote_state.get("timestamp")
        else:
            pack["updateAvailable"] = False
            pack["updateStatus"] = "unknown"
        pack["lastCheckedAt"] = checked_at
        pack["updateError"] = remote_state.get("error")
    installed_source_hashes = {
        str(pack["id"]): str(pack.get("sourceSha256") or "")
        for pack in enabled_installed_packs
    }
    capability_source_hashes = {
        str(item.get("id")): str(item.get("sha256") or "")
        for item in capability.get("inputs", [])
        if isinstance(item, dict) and item.get("id")
    }
    capability_pack_ids: set[str] = set()
    for capability_id in capability_ids:
        source_matches = (
            installed_source_hashes.get(capability_id) == capability_source_hashes.get(capability_id)
            if capability_source_hashes
            else capability_id in installed_ids
        )
        if not source_matches:
            continue
        capability_pack_ids.add(capability_id)
        dataset = datasets_by_id.get(capability_id, {})
        capability_pack_ids.update(
            str(member.get("id"))
            for member in dataset.get("members", [])
            if isinstance(member, dict) and member.get("id")
        )

    usage_paths = {
        "map": MAP_PACK_ROOT, "osm": OSM_RESOURCE_ROOT, "routing": ROUTING_RESOURCE_ROOT,
        "elevation": ELEVATION_ROOT, "encyclopedia": ENCYCLOPEDIA_RESOURCE_ROOT, "web": WEB_RESOURCE_ROOT,
        "weather": WEATHER_RESOURCE_ROOT, "nautical": NAUTICAL_RESOURCE_ROOT, "overview": OVERVIEW_RESOURCE_ROOT,
        "terrain_cache": TERRAIN_CACHE_ROOT, "osm_carto_cache": OSM_CARTO_CACHE_ROOT,
        "media": MEDIA_ROOT, "backup": BACKUP_ROOT,
        "build_cache": BUILD_CACHE_ROOT, "offline": OFFLINE_KIT_ROOT,
    }
    with ThreadPoolExecutor(max_workers=8, thread_name_prefix="resource-usage") as executor:
        usage_values = dict(zip(usage_paths, executor.map(directory_usage, usage_paths.values()), strict=True))
    map_usage = usage_values["map"]
    osm_usage = usage_values["osm"]
    routing_usage = usage_values["routing"]
    elevation_usage = usage_values["elevation"]
    encyclopedia_usage = usage_values["encyclopedia"]
    web_usage = usage_values["web"]
    weather_usage = usage_values["weather"]
    nautical_usage = usage_values["nautical"]
    overview_usage = usage_values["overview"]
    terrain_cache_usage = usage_values["terrain_cache"]
    osm_carto_cache_usage = usage_values["osm_carto_cache"]
    build_cache_usage = usage_values["build_cache"]
    media_usage = usage_values["media"]
    backup_usage = usage_values["backup"]
    offline_kit_usage_value = usage_values["offline"]
    current_map_paths: list[Path] = []
    for pack in installed_packs:
        current_map_paths.extend((
            MAP_PACK_ROOT / f"{pack['id']}.pmtiles",
            MAP_PACK_ROOT / f"{pack['id']}.manifest.json",
        ))
        if pack.get("detailsUrl"):
            current_map_paths.append(pack_file(str(pack["detailsUrl"])))
    current_map_usage = selected_file_usage(current_map_paths)
    rollback_map_paths: list[Path] = []
    pending_version_metadata_paths: list[Path] = []
    for previous_manifest_path in MAP_PACK_ROOT.glob("*.previous.manifest.json"):
        pack_id = previous_manifest_path.name.removesuffix(".previous.manifest.json")
        previous_product_path = MAP_PACK_ROOT / f"{pack_id}.previous.pmtiles"
        if previous_product_path.is_file():
            rollback_map_paths.extend((previous_product_path, previous_manifest_path))
            previous_manifest = read_json_file(previous_manifest_path) or {}
            previous_details = previous_manifest.get("details", {}) if isinstance(previous_manifest.get("details"), dict) else {}
            if previous_details:
                previous_details_path = pack_file(str(previous_details.get("url") or previous_details.get("file") or ""))
                if previous_details_path.is_file():
                    rollback_map_paths.append(previous_details_path)
        else:
            pending_version_metadata_paths.append(previous_manifest_path)
    rollback_map_usage = selected_file_usage(rollback_map_paths)
    staged_map_usage = selected_file_usage(
        list(MAP_PACK_ROOT.glob("*.staged.pmtiles"))
        + list(MAP_PACK_ROOT.glob("*.swap-*.pmtiles"))
        + list(MAP_PACK_ROOT.glob("*.swap-*.manifest.json"))
    )
    version_history_usage = selected_file_usage(
        (
            [path for path in (MAP_PACK_ROOT / "history").rglob("*") if path.is_file()]
            if (MAP_PACK_ROOT / "history").is_dir()
            else []
        )
        + pending_version_metadata_paths
    )
    other_map_usage = {
        "bytes": max(
            0,
            map_usage["bytes"]
            - current_map_usage["bytes"]
            - rollback_map_usage["bytes"]
            - staged_map_usage["bytes"]
            - version_history_usage["bytes"],
        ),
        "files": max(
            0,
            map_usage["files"]
            - current_map_usage["files"]
            - rollback_map_usage["files"]
            - staged_map_usage["files"]
            - version_history_usage["files"],
        ),
    }
    staged_source_paths = [
        path
        for path in OSM_RESOURCE_ROOT.rglob("*")
        if path.is_file()
        and (
            path.name.endswith(".download.osm.pbf")
            or path.name.endswith(".osm.pbf.part")
            or path.name.endswith(".state.txt.refresh.part")
        )
    ]
    staged_source_usage = selected_file_usage(staged_source_paths)
    legacy_directories = (
        OSM_RESOURCE_ROOT / "china" / "jiangsu",
        OSM_RESOURCE_ROOT / "china" / "anhui",
    )
    legacy_source_paths = [
        path
        for legacy_directory in legacy_directories
        if legacy_directory.is_dir()
        for path in legacy_directory.rglob("*")
        if path.is_file()
    ]
    legacy_source_usage = selected_file_usage(legacy_source_paths)
    legacy_source_path_set = {path.resolve() for path in legacy_source_paths}
    rollback_source_usage = selected_file_usage(
        [
            path
            for path in OSM_RESOURCE_ROOT.rglob("*.previous")
            if path.is_file() and path.resolve() not in legacy_source_path_set
        ]
    )
    owned_osm_usage = {
        "bytes": max(
            0,
            osm_usage["bytes"]
            - staged_source_usage["bytes"]
            - rollback_source_usage["bytes"]
            - legacy_source_usage["bytes"],
        ),
        "files": max(
            0,
            osm_usage["files"]
            - staged_source_usage["files"]
            - rollback_source_usage["files"]
            - legacy_source_usage["files"],
        ),
    }
    offline_kit_directories = [path for path in OFFLINE_KIT_ROOT.iterdir() if path.is_dir()] if OFFLINE_KIT_ROOT.is_dir() else []
    verified_offline_kits = sum(1 for path in offline_kit_directories if not path.name.endswith(".failed") and offline_kit_is_verified(path))
    failed_offline_kits = sum(1 for path in offline_kit_directories if path.name.endswith(".failed"))
    unverified_offline_kits = max(0, len(offline_kit_directories) - verified_offline_kits - failed_offline_kits)
    routing_core_bytes = routing_usage["bytes"]

    with pool.connection() as conn:
        database = conn.execute(
            """
            SELECT
              pg_database_size(current_database()) AS bytes,
              (SELECT count(*) FROM app.places) AS places,
              (SELECT count(*) FROM app.tracks) AS tracks,
              (SELECT count(*) FROM app.media) AS media
            """
        ).fetchone()
    database_bytes = int(database["bytes"] or 0)

    encyclopedia_manifest = read_json_file(ENCYCLOPEDIA_RESOURCE_ROOT / "encyclopedia.manifest.json") or {}
    travel_manifest = read_json_file(ENCYCLOPEDIA_RESOURCE_ROOT / "travel-guide.manifest.json") or {}
    weather_manifest = read_json_file(WEATHER_RESOURCE_ROOT / "weather.manifest.json") or {}
    nautical_manifest = read_json_file(NAUTICAL_RESOURCE_ROOT / "nautical.manifest.json") or {}
    overview_manifest = read_json_file(OVERVIEW_RESOURCE_ROOT / "overview.manifest.json") or {}
    osm_carto_manifest = read_json_file(OSM_CARTO_MANIFEST_PATH) or {}
    osm_carto_database_bytes = int((osm_carto_manifest.get("storage") or {}).get("databaseBytes", 0) or 0)
    osm_carto_source = osm_carto_manifest.get("source") if isinstance(osm_carto_manifest.get("source"), dict) else {}
    osm_carto_source_hashes = {
        str(item.get("id")): str(item.get("sha256") or "")
        for item in osm_carto_source.get("inputs", [])
        if isinstance(item, dict) and item.get("id")
    }
    osm_carto_region_ids = {
        str(item) for item in osm_carto_source.get("regions", []) if item
    }
    osm_carto_inputs_current = (
        osm_carto_source_hashes == installed_source_hashes
        if osm_carto_source_hashes
        else osm_carto_region_ids == installed_ids and bool(osm_carto_region_ids)
    )
    osm_carto_current_region_ids = {
        pack_id
        for pack_id, source_hash in osm_carto_source_hashes.items()
        if installed_source_hashes.get(pack_id) == source_hash
    } if osm_carto_source_hashes else (osm_carto_region_ids & installed_ids)
    world_catalog = read_json_file(WORLD_REGION_CATALOG_PATH) or {}
    encyclopedia_state = declared_file_state(
        ENCYCLOPEDIA_RESOURCE_ROOT,
        encyclopedia_manifest,
        str(encyclopedia_manifest.get("file") or ""),
    )
    travel_state = declared_file_state(
        ENCYCLOPEDIA_RESOURCE_ROOT,
        travel_manifest,
        str(travel_manifest.get("file") or ""),
    )
    weather_state = declared_file_state(
        WEATHER_RESOURCE_ROOT,
        weather_manifest,
        "latest.geojson",
        hash_small_files=True,
    )
    weather_source_hashes = {
        str(item.get("id")): str(item.get("sha256") or "")
        for item in weather_manifest.get("inputs", [])
        if isinstance(item, dict) and item.get("id")
    }
    weather_inputs_current = weather_source_hashes == installed_source_hashes
    nautical_state = declared_file_state(
        NAUTICAL_RESOURCE_ROOT,
        nautical_manifest,
        "seamarks.geojson",
        hash_small_files=True,
    )
    nautical_source_hashes = {
        str(item.get("id")): str(item.get("sha256") or "")
        for item in nautical_manifest.get("inputs", [])
        if isinstance(item, dict) and item.get("id")
    }
    nautical_inputs_current = nautical_source_hashes == installed_source_hashes
    overview_files = overview_manifest.get("files") if isinstance(overview_manifest.get("files"), list) else []
    overview_valid = bool(overview_files) and all(
        isinstance(entry, dict)
        and declared_file_state(
            OVERVIEW_RESOURCE_ROOT,
            {"bytes": entry.get("bytes"), "sha256": entry.get("sha256")},
            str(entry.get("name") or ""),
            hash_small_files=True,
        )["valid"]
        for entry in overview_files
    )
    elevation_files = [path for path in ELEVATION_ROOT.rglob("*.hgt")] if ELEVATION_ROOT.is_dir() else []
    elevation_valid = bool(elevation_files) and all(
        re.fullmatch(r"[NS]\d{2}[EW]\d{3}\.hgt", path.name, re.IGNORECASE)
        and path.stat().st_size in {2 * 1201 * 1201, 2 * 3601 * 3601}
        for path in elevation_files
    )
    encyclopedia_usage_value = selected_file_usage(
        [
            ENCYCLOPEDIA_RESOURCE_ROOT / "encyclopedia.manifest.json",
            encyclopedia_state["path"],
        ]
    )
    travel_usage_value = selected_file_usage(
        [
            ENCYCLOPEDIA_RESOURCE_ROOT / "travel-guide.manifest.json",
            travel_state["path"],
        ]
    )
    shared_scope = shared_index_scope_state()
    with ThreadPoolExecutor(max_workers=4, thread_name_prefix="resource-service") as executor:
        service_futures = {
            "geocoder": executor.submit(upstream_available, NOMINATIM_URL, "/status"),
            "routing": executor.submit(upstream_available, VALHALLA_URL, "/status"),
            "encyclopedia": executor.submit(upstream_available, KIWIX_URL, "/wiki/"),
            "osm-carto": executor.submit(upstream_available, OSM_CARTO_URL, "/"),
        }
        services_available = {name: future.result() for name, future in service_futures.items()}
    disk = shutil.disk_usage(MEDIA_ROOT)
    managed_bytes = sum(
        (
            map_usage["bytes"],
            osm_usage["bytes"],
            routing_core_bytes,
            elevation_usage["bytes"],
            encyclopedia_usage["bytes"],
            web_usage["bytes"],
            terrain_cache_usage["bytes"],
            build_cache_usage["bytes"],
            weather_usage["bytes"],
            nautical_usage["bytes"],
            overview_usage["bytes"],
            osm_carto_database_bytes,
            osm_carto_cache_usage["bytes"],
            media_usage["bytes"],
            backup_usage["bytes"],
            offline_kit_usage_value["bytes"],
            database_bytes,
        )
    )

    local_groups = [
        {
            "id": "resources",
            "name": "资源",
            "items": [
                {"id": "standard-maps", "name": "当前标准地图", "icon": "map", "bytes": current_map_usage["bytes"], "files": current_map_usage["files"], "status": "warning" if any(not pack["sizeMatches"] for pack in installed_packs) else "ready", "subtitle": f"{len(enabled_installed_packs)} 个启用 · {len(installed_packs) - len(enabled_installed_packs)} 个停用 · 清单尺寸已核对"},
                {"id": "map-rollbacks", "name": "地图回退副本", "icon": "history", "bytes": rollback_map_usage["bytes"], "files": rollback_map_usage["files"], "status": "warning" if any(pack["rollbackArtifacts"] and (not pack["rollbackReady"] or not pack["rollbackSizeMatches"]) for pack in installed_packs) else ("ready" if rollback_map_usage["files"] else "missing"), "subtitle": "当前与上一版均含标准地图和丰富详情时才可回退"},
                {"id": "map-build-staging", "name": "正在生成的地图", "icon": "loader-circle", "bytes": staged_map_usage["bytes"], "files": staged_map_usage["files"], "status": "warning" if staged_map_usage["files"] else "missing", "subtitle": "构建成功后原子替换，失败时可清理"},
                {"id": "map-version-history", "name": "地图版本清单", "icon": "notebook-tabs", "bytes": version_history_usage["bytes"], "files": version_history_usage["files"], "status": "ready" if version_history_usage["files"] else "missing", "subtitle": "只保存来源、时间与哈希，不复制地图大文件"},
                {"id": "other-map-products", "name": "未归类地图产物", "icon": "file-question", "bytes": other_map_usage["bytes"], "files": other_map_usage["files"], "status": "warning" if other_map_usage["files"] else "missing", "subtitle": "暂存、旧目录或没有有效清单的文件"},
                {"id": "osm-sources", "name": "已接管 OSM 构建源", "icon": "database", "bytes": owned_osm_usage["bytes"], "files": owned_osm_usage["files"], "status": "ready" if owned_osm_usage["files"] and current_state.get("sequenceNumber") else ("warning" if owned_osm_usage["files"] else "missing"), "subtitle": f"共享中国快照仅计一次 · {current_state.get('timestamp', '缺少可信状态')}"},
                {"id": "source-rollbacks", "name": "源快照回退副本", "icon": "history", "bytes": rollback_source_usage["bytes"], "files": rollback_source_usage["files"], "status": "ready" if rollback_source_usage["files"] else "missing", "subtitle": "更新失败时可恢复的上一份完整源"},
                {"id": "legacy-source-comparisons", "name": "旧版省级对照源", "icon": "archive", "bytes": legacy_source_usage["bytes"], "files": legacy_source_usage["files"], "status": "archive" if legacy_source_usage["files"] else "missing", "subtitle": "不参与当前构建，仅用于来源对照"},
                {"id": "staged-source-downloads", "name": "待验证源下载", "icon": "download", "bytes": staged_source_usage["bytes"], "files": staged_source_usage["files"], "status": "warning" if staged_source_usage["files"] else "missing", "subtitle": "可续用的下载暂存，不是已安装资源"},
                {"id": "geocoder", "name": "地址检索索引", "icon": "search", "bytes": None, "files": None, "status": "warning" if not shared_scope["current"] or not shared_scope["verified"] or not services_available["geocoder"] else "external", "subtitle": "Nominatim Docker 卷 · " + ("等待共享索引重建" if not shared_scope["current"] else ("服务不可用" if not services_available["geocoder"] else ("服务在线，尚未通过新版完整验证" if not shared_scope["verified"] else "蓝绿候选验证通过，服务在线")))},
                {"id": "routing", "name": "路线规划", "icon": "route", "bytes": routing_core_bytes, "files": routing_usage["files"], "status": "missing" if routing_core_bytes == 0 else ("warning" if not shared_scope["current"] or not shared_scope["verified"] or not services_available["routing"] else "ready"), "subtitle": "Valhalla · " + ("等待共享索引重建" if not shared_scope["current"] else ("服务不可用" if not services_available["routing"] else ("服务在线，尚未通过新版完整验证" if not shared_scope["verified"] else "蓝绿候选验证通过，服务在线")))},
                {"id": "terrain", "name": "地形与等高线", "icon": "mountain-snow", "bytes": elevation_usage["bytes"], "files": elevation_usage["files"], "status": "ready" if elevation_valid else ("warning" if elevation_files else "missing"), "subtitle": f"{elevation_usage['files']} 个 HGT 格网 · " + ("尺寸有效" if elevation_valid else "需要校验")},
                {"id": "encyclopedia", "name": "离线百科", "icon": "book-open", "bytes": encyclopedia_usage_value["bytes"], "files": encyclopedia_usage_value["files"], "status": "ready" if encyclopedia_state["valid"] and services_available["encyclopedia"] else ("warning" if encyclopedia_manifest else "missing"), "subtitle": f"中文维基百科 {encyclopedia_manifest.get('snapshot', '--')} · " + ("清单有效，服务在线" if encyclopedia_state["valid"] and services_available["encyclopedia"] else "资源或服务需检查")},
                {"id": "overview-map", "name": "全球概览地图", "icon": "globe-2", "bytes": overview_usage["bytes"], "files": overview_usage["files"], "status": "ready" if overview_valid else ("warning" if overview_usage["files"] else "missing"), "subtitle": f"{overview_manifest.get('snapshot', 'Natural Earth')} · " + ("校验通过" if overview_valid else "需要校验")},
                {"id": "osm-carto-renderer", "name": "本地 OSM 原版渲染", "icon": "map", "bytes": osm_carto_database_bytes + osm_carto_cache_usage["bytes"], "files": osm_carto_cache_usage["files"] + (1 if osm_carto_manifest else 0), "status": "ready" if osm_carto_manifest and osm_carto_inputs_current and services_available["osm-carto"] else ("warning" if osm_carto_manifest else "missing"), "subtitle": f"{len(osm_carto_region_ids)} 个区域 · OpenStreetMap Carto · " + ("来源一致，服务在线" if osm_carto_inputs_current and services_available["osm-carto"] else "需要同步已安装区域")},
                {"id": "weather", "name": "天气快照", "icon": "cloud-sun", "bytes": weather_usage["bytes"], "files": weather_usage["files"], "status": "ready" if weather_state["valid"] and weather_inputs_current else ("warning" if weather_manifest else "missing"), "subtitle": f"{len(weather_source_hashes)} 个区域 · Open-Meteo · {weather_manifest.get('generatedAt', '--')} · " + ("来源一致，校验通过" if weather_state["valid"] and weather_inputs_current else "需要同步已安装区域")},
                {"id": "travel-guide", "name": "旅行指南", "icon": "landmark", "bytes": travel_usage_value["bytes"], "files": travel_usage_value["files"], "status": "ready" if travel_state["valid"] and services_available["encyclopedia"] else ("warning" if travel_manifest else "missing"), "subtitle": f"中文维基导游 {travel_manifest.get('snapshot', '--')} · " + ("清单有效，服务在线" if travel_state["valid"] and services_available["encyclopedia"] else "资源或服务需检查")},
                {"id": "nautical", "name": "航海参考", "icon": "anchor", "bytes": nautical_usage["bytes"], "files": nautical_usage["files"], "status": "ready" if nautical_state["valid"] and nautical_inputs_current else ("warning" if nautical_manifest else "missing"), "subtitle": f"{len(nautical_source_hashes)} 个区域 · {nautical_manifest.get('features', 0)} 个本地 OSM 航海地物 · " + ("来源一致，校验通过" if nautical_state["valid"] and nautical_inputs_current else "需要同步已安装区域")},
                {"id": "tts", "name": "语音提示（TTS）", "icon": "volume-2", "bytes": 0, "files": 0, "status": "external", "subtitle": "Windows/浏览器运行时能力 · 不计入离线资源占用"},
            ],
        },
        {
            "id": "personal",
            "name": "我的数据",
            "items": [
                {"id": "personal-database", "name": "点位与轨迹数据库", "icon": "map-pin", "bytes": database_bytes, "files": None, "status": "ready", "subtitle": f"{database['places']} 点位 · {database['tracks']} 轨迹"},
                {"id": "personal-media", "name": "照片与附件", "icon": "images", "bytes": media_usage["bytes"], "files": media_usage["files"], "status": "ready", "subtitle": f"{database['media']} 个媒体记录"},
            ],
        },
        {
            "id": "settings",
            "name": "设置与维护",
            "items": [
                {"id": "backups", "name": "本地备份", "icon": "archive", "bytes": backup_usage["bytes"], "files": backup_usage["files"], "status": "ready", "subtitle": "数据库、媒体与校验清单"},
                {"id": "offline-kits", "name": "完整恢复包", "icon": "hard-drive-download", "bytes": offline_kit_usage_value["bytes"], "files": offline_kit_usage_value["files"], "status": "warning" if failed_offline_kits or unverified_offline_kits else "ready", "subtitle": f"{len(offline_kit_directories)} 个恢复包 · {verified_offline_kits} 个已验证 · {unverified_offline_kits} 个未验证 · {failed_offline_kits} 个失败"},
                {"id": "web-assets", "name": "地图字体与界面资源", "icon": "languages", "bytes": web_usage["bytes"], "files": web_usage["files"], "status": "ready", "subtitle": "字形、图标、脚本与样式"},
                {"id": "regenerable-caches", "name": "可再生缓存", "icon": "layers", "bytes": terrain_cache_usage["bytes"] + build_cache_usage["bytes"], "files": terrain_cache_usage["files"] + build_cache_usage["files"], "status": "cache", "subtitle": "地形瓦片、构建临时文件与资源盘点缓存"},
            ],
        },
    ]
    for group in local_groups:
        for item in group["items"]:
            item.update(RESOURCE_CLASSIFICATIONS.get(str(item["id"]), {}))
            item.update(RESOURCE_MANAGEMENT.get(str(item["id"]), {
                "managementMode": "system",
                "managementLabel": "系统托管",
            }))

    update_checks = [
        {
            "id": str(pack["id"]),
            "name": str(pack["name"]),
            "type": "standard-map",
            "bytes": int(pack["bytes"] or 0),
            "installedVersion": pack.get("sourceUpdatedAt"),
            "availableVersion": pack.get("upstreamSourceUpdatedAt") or pack.get("currentSourceUpdatedAt") or current_state.get("timestamp"),
            "updateAvailable": bool(pack["updateAvailable"] or not pack["sizeMatches"]),
            "statusKind": "repair" if not pack["sizeMatches"] else pack.get("updateStatus", "unknown"),
            "reason": ("丰富地图详情包缺失或校验不一致，需要重新生成" if not pack.get("richDetailsReady") else "本地地图文件与清单尺寸不一致，需要重新生成") if not pack["sizeMatches"] else ("上游快照序列已变化" if pack.get("updateAvailable") else (
                pack.get("updateError") or ("已与最近上游检查一致" if pack.get("updateStatus") == "current" else "本地序列较新或尚无法安全比较上游")
            )),
            "action": "update" if pack.get("updateAvailable") else "rebuild" if not pack["sizeMatches"] else None,
            "lastCheckedAt": pack.get("lastCheckedAt"),
            "sourceUpdatedAt": pack.get("sourceUpdatedAt"),
            "builtAt": pack.get("generatedAt"),
            "nextCheckAt": ((datetime.fromisoformat(str(pack["lastCheckedAt"]).replace("Z", "+00:00")) + timedelta(days=7)).isoformat() if pack.get("lastCheckedAt") else None),
            "heavy": False,
            "command": f"D:\\TerraSys\\region-pack.cmd Update -PackId {pack['id']}",
        }
        for pack in installed_packs
    ]
    update_checks.append(
        {
            "id": "shared-capabilities",
            "name": "搜索与路线共享索引",
            "type": "capability-index",
            "bytes": int(capability.get("product", {}).get("bytes", 0) or 0),
            "installedVersion": capability.get("generatedAt"),
            "availableVersion": current_state.get("timestamp"),
            "updateAvailable": capability_ids != installed_ids or capability_source_hashes != installed_source_hashes or not shared_scope["verified"],
            "statusKind": "rebuild" if capability_ids != installed_ids or capability_source_hashes != installed_source_hashes or not shared_scope["verified"] else "current",
            "reason": "地图包集合或源数据摘要已变化，需要重建本地派生索引" if capability_ids != installed_ids or capability_source_hashes != installed_source_hashes else ("当前服务可用，但缺少蓝绿候选版本的完整验证凭据" if not shared_scope["verified"] else "共享索引与已安装地图包一致并已完整验证"),
            "lastCheckedAt": upstream_cache.get("checkedAt"),
            "sourceUpdatedAt": current_state.get("timestamp"),
            "builtAt": capability.get("generatedAt"),
            "nextCheckAt": None,
            "heavy": True,
            "command": "D:\\TerraSys\\rebuild-shared-indexes.cmd -ConfirmRebuild",
        }
    )

    def manifest_is_older_than(manifest: dict[str, Any], hours: int) -> bool:
        value = manifest.get("generatedAt")
        if not value:
            return True
        try:
            generated = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            return (datetime.now().astimezone() - generated.astimezone()).total_seconds() > hours * 3600
        except ValueError:
            return True

    def file_is_older_than(path: Path, hours: int) -> bool:
        try:
            age = datetime.now().astimezone() - datetime.fromtimestamp(path.stat().st_mtime).astimezone()
            return age.total_seconds() > hours * 3600
        except OSError:
            return True

    static_updates = [
        {
            "id": "world-region-catalog",
            "name": "全球区域目录",
            "type": "catalog",
            "bytes": WORLD_REGION_CATALOG_PATH.stat().st_size if WORLD_REGION_CATALOG_PATH.is_file() else 0,
            "installedVersion": world_catalog.get("version"),
            "availableVersion": world_catalog.get("version"),
            "updateAvailable": file_is_older_than(WORLD_REGION_CATALOG_PATH, 24 * 7),
            "statusKind": "refresh" if file_is_older_than(WORLD_REGION_CATALOG_PATH, 24 * 7) else "current",
            "reason": "目录已到定期刷新时间" if file_is_older_than(WORLD_REGION_CATALOG_PATH, 24 * 7) else "目录仍在刷新周期内",
            "heavy": False,
            "command": "D:\\TerraSys\\sync-world-catalog.cmd",
        },
        {
            "id": "overview-map",
            "name": "全球概览地图",
            "type": "overview-map",
            "bytes": overview_usage["bytes"],
            "installedVersion": overview_manifest.get("generatedAt"),
            "availableVersion": overview_manifest.get("generatedAt"),
            "updateAvailable": not overview_valid,
            "statusKind": "missing" if not overview_manifest else "repair" if not overview_valid else "current",
            "reason": "资源尚未安装" if not overview_manifest else "资源文件或清单校验失败，需要修复" if not overview_valid else "资源已安装并通过校验",
            "action": "update" if not overview_valid else None,
            "heavy": False,
            "command": "D:\\TerraSys\\sync-overview-resources.cmd",
        },
        {
            "id": "osm-carto",
            "name": "本地 OSM 原版渲染",
            "type": "osm-carto",
            "bytes": osm_carto_database_bytes + osm_carto_cache_usage["bytes"],
            "installedVersion": osm_carto_manifest.get("generatedAt"),
            "availableVersion": capability.get("generatedAt"),
            "updateAvailable": not bool(osm_carto_manifest) or not osm_carto_inputs_current or not services_available["osm-carto"],
            "statusKind": "missing" if not osm_carto_manifest else "rebuild" if not osm_carto_inputs_current else "repair" if not services_available["osm-carto"] else "current",
            "reason": "OSM 原版渲染尚未安装" if not osm_carto_manifest else "已启用地图包集合或源数据摘要已变化，需要后台重建并切换" if not osm_carto_inputs_current else "渲染服务未就绪，需要修复" if not services_available["osm-carto"] else "OSM 原版渲染与已启用地图包来源一致",
            "action": "update" if not bool(osm_carto_manifest) or not osm_carto_inputs_current or not services_available["osm-carto"] else None,
            "heavy": True,
            "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\\TerraSys\\scripts\\build-osm-carto.ps1",
        },
        {
            "id": "weather",
            "name": "天气快照",
            "type": "weather",
            "bytes": weather_usage["bytes"],
            "installedVersion": weather_manifest.get("generatedAt"),
            "availableVersion": datetime.now().astimezone().isoformat(),
            "updateAvailable": not weather_state["valid"] or not weather_inputs_current or manifest_is_older_than(weather_manifest, 6),
            "statusKind": "missing" if not weather_manifest else "repair" if not weather_state["valid"] else "rebuild" if not weather_inputs_current else "refresh" if manifest_is_older_than(weather_manifest, 6) else "current",
            "reason": "天气资源尚未安装" if not weather_manifest else "天气资源校验失败，需要重新获取" if not weather_state["valid"] else "已启用地图包集合或源数据摘要已变化，需要同步天气点" if not weather_inputs_current else "天气快照已到刷新时间" if manifest_is_older_than(weather_manifest, 6) else "天气快照仍在有效期内",
            "action": "update" if not weather_state["valid"] or not weather_inputs_current or manifest_is_older_than(weather_manifest, 6) else None,
            "heavy": False,
            "command": "D:\\TerraSys\\sync-weather.cmd",
        },
        {
            "id": "nautical",
            "name": "航海参考",
            "type": "nautical",
            "bytes": nautical_usage["bytes"],
            "installedVersion": nautical_manifest.get("generatedAt"),
            "availableVersion": capability.get("generatedAt"),
            "updateAvailable": not nautical_state["valid"] or not nautical_inputs_current,
            "statusKind": "repair" if nautical_manifest and not nautical_state["valid"] else "rebuild" if not bool(nautical_manifest) or not nautical_inputs_current else "current",
            "reason": "航海资源校验失败，需要重建" if nautical_manifest and not nautical_state["valid"] else "已启用地图包集合或源数据摘要已变化，需要增量重建" if not bool(nautical_manifest) or not nautical_inputs_current else "航海参考与已启用地图包来源一致",
            "action": "update" if not nautical_state["valid"] or not nautical_inputs_current else None,
            "heavy": False,
            "command": "D:\\TerraSys\\build-nautical.cmd",
        },
        {
            "id": "encyclopedia",
            "name": "离线百科",
            "type": "encyclopedia",
            "bytes": int(encyclopedia_manifest.get("bytes", 0) or 0),
            "installedVersion": encyclopedia_manifest.get("generatedAt"),
            "availableVersion": encyclopedia_manifest.get("generatedAt"),
            "updateAvailable": not encyclopedia_state["valid"],
            "statusKind": "missing" if not encyclopedia_manifest else "repair" if not encyclopedia_state["valid"] else "current",
            "reason": "资源尚未安装" if not encyclopedia_manifest else "本地归档校验失败，需要重新获取" if not encyclopedia_state["valid"] else "本地归档已安装；新版本需显式检查上游",
            "action": "update" if not encyclopedia_state["valid"] else None,
            "heavy": True,
            "command": "D:\\TerraSys\\download-encyclopedia.cmd",
        },
        {
            "id": "travel-guide",
            "name": "旅行指南",
            "type": "travel-guide",
            "bytes": int(travel_manifest.get("bytes", 0) or 0),
            "installedVersion": travel_manifest.get("generatedAt"),
            "availableVersion": travel_manifest.get("generatedAt"),
            "updateAvailable": not travel_state["valid"],
            "statusKind": "missing" if not travel_manifest else "repair" if not travel_state["valid"] else "current",
            "reason": "资源尚未安装" if not travel_manifest else "本地归档校验失败，需要重新获取" if not travel_state["valid"] else "本地归档已安装；新版本需显式检查上游",
            "action": "update" if not travel_state["valid"] else None,
            "heavy": True,
            "command": "D:\\TerraSys\\download-travel-guide.cmd",
        },
    ]
    update_checks.extend(static_updates)

    schedule_hours = {"world-region-catalog": 168, "overview-map": 720, "weather": 6, "nautical": 168, "encyclopedia": 720, "travel-guide": 720}
    scheduler = read_json_file(MAINTENANCE_ROOT / "scheduler.json") or {}
    scheduler_resources = scheduler.get("resources", {}) if isinstance(scheduler.get("resources"), dict) else {}
    for item in update_checks:
        item.setdefault("sourceUpdatedAt", item.get("availableVersion"))
        item.setdefault("builtAt", item.get("installedVersion"))
        schedule_entry = scheduler_resources.get(str(item["id"]), {}) if isinstance(scheduler_resources, dict) else {}
        item.setdefault("lastCheckedAt", schedule_entry.get("lastAttempted") or upstream_cache.get("checkedAt"))
        if "nextCheckAt" not in item:
            base_value = schedule_entry.get("lastSucceeded") or item.get("lastCheckedAt") or item.get("builtAt")
            hours = schedule_hours.get(str(item["id"]))
            try:
                item["nextCheckAt"] = (datetime.fromisoformat(str(base_value).replace("Z", "+00:00")) + timedelta(hours=hours)).isoformat() if base_value and hours else None
            except ValueError:
                item["nextCheckAt"] = None

    terrain_tiles: list[tuple[float, float, float, float]] = []
    if ELEVATION_ROOT.is_dir():
        for path in ELEVATION_ROOT.rglob("*.hgt"):
            match = re.fullmatch(r"([NS])(\d{2})([EW])(\d{3})\.hgt", path.name, flags=re.IGNORECASE)
            if not match:
                continue
            latitude = int(match.group(2)) * (-1 if match.group(1).upper() == "S" else 1)
            longitude = int(match.group(4)) * (-1 if match.group(3).upper() == "W" else 1)
            terrain_tiles.append((longitude, latitude, longitude + 1, latitude + 1))
    terrain_tile_origins = {(int(west), int(south)) for west, south, _, _ in terrain_tiles}
    terrain_coverage = {}
    for pack in enabled_installed_packs:
        dataset = datasets_by_id.get(str(pack["id"]), {})
        bounds = dataset.get("bounds", [])
        if len(bounds) != 4:
            continue
        center_longitude = (float(bounds[0]) + float(bounds[2])) / 2
        center_latitude = (float(bounds[1]) + float(bounds[3])) / 2
        center_tile = (math.floor(center_longitude), math.floor(center_latitude))
        terrain_coverage[str(pack["id"])] = {
            "centerReady": center_tile in terrain_tile_origins,
            "centerTile": f"{'N' if center_tile[1] >= 0 else 'S'}{abs(center_tile[1]):02d}{'E' if center_tile[0] >= 0 else 'W'}{abs(center_tile[0]):03d}",
        }
    terrain_pack_ids = sorted(
        pack_id for pack_id, coverage in terrain_coverage.items() if coverage["centerReady"]
    )

    legacy_packages = legacy_map_packages(catalog, packs)
    caches = cache_inventory({"terrain-tiles": terrain_cache_usage, "build-temp": build_cache_usage})

    payload = {
        "generatedAt": datetime.now().astimezone().isoformat(),
        "resourceRevision": inventory_revision,
        "catalogVersion": catalog.get("version"),
        "storage": {
            "diskTotalBytes": disk.total,
            "diskUsedBytes": disk.used,
            "diskFreeBytes": disk.free,
            "managedBytes": managed_bytes,
            "externalBytesKnown": False,
        },
        "summary": {
            "installedPacks": len(installed_packs),
            "enabledPacks": len(enabled_installed_packs),
            "disabledPacks": len(installed_packs) - len(enabled_installed_packs),
            "availablePacks": sum(1 for pack in packs if not pack["installed"]),
            "mapPackCount": len(packs),
            "provinceCount": len(province_packs),
            "independentProvinces": sum(1 for pack in province_packs if pack["installed"]),
            "coveredProvinces": sum(1 for pack in province_packs if pack["covered"]),
            "updates": sum(1 for item in update_checks if item["updateAvailable"]),
            "obsoletePackages": len(legacy_packages),
            "regenerableCacheBytes": sum(int(item["bytes"]) for item in caches),
            "currentMapBytes": current_map_usage["bytes"],
            "rollbackMapBytes": rollback_map_usage["bytes"],
            "stagedMapBytes": staged_map_usage["bytes"],
            "versionHistoryBytes": version_history_usage["bytes"],
            "otherMapBytes": other_map_usage["bytes"],
            "stagedSourceBytes": staged_source_usage["bytes"],
            "rollbackSourceBytes": rollback_source_usage["bytes"],
            "legacySourceBytes": legacy_source_usage["bytes"],
        },
        "capabilityPackIds": sorted(capability_pack_ids),
        "osmCartoPackIds": sorted(osm_carto_current_region_ids) if osm_carto_manifest and services_available["osm-carto"] else [],
        "weatherPackIds": sorted(
            pack_id for pack_id, source_hash in weather_source_hashes.items()
            if weather_state["valid"] and installed_source_hashes.get(pack_id) == source_hash
        ),
        "nauticalPackIds": sorted(
            pack_id for pack_id, source_hash in nautical_source_hashes.items()
            if nautical_state["valid"] and installed_source_hashes.get(pack_id) == source_hash
        ),
        "terrainPackIds": terrain_pack_ids,
        "terrainCoverage": terrain_coverage,
        "localGroups": local_groups,
        "caches": caches,
        "legacyPackages": legacy_packages,
        "updateChecks": update_checks,
        "upstream": {"checkedAt": upstream_cache.get("checkedAt"), "refreshed": check_upstream},
        "cache": {"state": "fresh", "cachedAt": None},
    }
    if resource_inventory_revision() == inventory_revision:
        write_json_file(RESOURCE_INVENTORY_CACHE_PATH, payload)
    return payload


def refresh_resource_inventory(check_upstream: bool = False) -> None:
    try:
        payload = build_resource_inventory(check_upstream=check_upstream)
        if payload.get("resourceRevision") != resource_inventory_revision():
            build_resource_inventory(check_upstream=check_upstream)
    finally:
        RESOURCE_INVENTORY_REFRESH_LOCK.release()


def schedule_resource_inventory_refresh(check_upstream: bool = False) -> bool:
    if not RESOURCE_INVENTORY_REFRESH_LOCK.acquire(blocking=False):
        return False
    Thread(
        target=refresh_resource_inventory,
        args=(check_upstream,),
        name="resource-inventory-refresh",
        daemon=True,
    ).start()
    return True


@app.get("/resources")
def resource_inventory(
    check_upstream: bool = Query(default=False),
    cached: bool = Query(default=False),
) -> dict[str, Any]:
    stored = read_json_file(RESOURCE_INVENTORY_CACHE_PATH)
    if stored:
        stale = stored.get("resourceRevision") != resource_inventory_revision()
        if stale or not cached or check_upstream:
            schedule_resource_inventory_refresh(check_upstream)
        state = "stale-refreshing" if stale else "refreshing" if (not cached or check_upstream or RESOURCE_INVENTORY_REFRESH_LOCK.locked()) else "cached"
        if stale:
            installed = installed_map_pack_states(map_catalog())
            installed_ids = {str(pack["id"]) for pack in installed}
            checks = [
                item for item in stored.get("updateChecks", [])
                if item.get("type") != "standard-map" or str(item.get("id")) in installed_ids
            ]
            summary = {
                **stored.get("summary", {}),
                "installedPacks": len(installed),
                "enabledPacks": sum(1 for pack in installed if pack["enabled"]),
                "disabledPacks": sum(1 for pack in installed if not pack["enabled"]),
                "updates": sum(1 for item in checks if item.get("updateAvailable")),
            }
            return {**stored, "summary": summary, "updateChecks": checks, "cache": {"state": state, "cachedAt": stored.get("generatedAt")}}
        return {**stored, "cache": {"state": state, "cachedAt": stored.get("generatedAt")}}

    schedule_resource_inventory_refresh(check_upstream)
    catalog = map_catalog()
    installed = installed_map_pack_states(catalog)
    disk = shutil.disk_usage(MEDIA_ROOT)
    return {
        "generatedAt": None,
        "resourceRevision": resource_inventory_revision(),
        "storage": {
            "diskTotalBytes": disk.total, "diskUsedBytes": disk.used, "diskFreeBytes": disk.free,
            "managedBytes": None, "externalBytesKnown": False,
        },
        "summary": {
            "installedPacks": len(installed),
            "enabledPacks": sum(1 for pack in installed if pack["enabled"]),
            "disabledPacks": sum(1 for pack in installed if not pack["enabled"]),
            "availablePacks": len(catalog["datasets"]) - len(installed),
            "mapPackCount": len(catalog["datasets"]),
            "provinceCount": sum(1 for item in catalog["datasets"] if item.get("kind") == "province"),
            "independentProvinces": sum(1 for pack in installed if pack.get("kind") == "province"),
            "updates": 0,
        },
        "localGroups": [], "caches": [], "legacyPackages": [], "updateChecks": [],
        "cache": {"state": "building", "cachedAt": None},
    }


@app.get("/maintenance")
def get_maintenance() -> dict[str, Any]:
    return maintenance_snapshot()


@app.put("/maintenance/settings")
def update_maintenance_settings(payload: MaintenanceSettingsInput) -> dict[str, Any]:
    settings = maintenance_settings()
    settings["enabled"] = payload.enabled
    for resource_id, enabled in payload.resources.items():
        settings["resources"][resource_id]["enabled"] = enabled
    write_json_file(MAINTENANCE_ROOT / "settings.json", settings)
    return maintenance_snapshot()


@app.post("/maintenance/jobs", status_code=202)
def create_maintenance_job(payload: MaintenanceJobInput) -> dict[str, Any]:
    resource_id = payload.resourceId
    action = payload.action
    catalog = map_catalog()
    pack = map_pack_state_for_id(catalog, resource_id)

    if pack is not None:
        if action == "build" and pack["installed"]:
            raise HTTPException(status_code=409, detail="Map pack is already installed; use rebuild instead")
        if action == "remove" and not pack.get("hasLocalArtifacts"):
            raise HTTPException(status_code=409, detail="Map pack is already absent")
        if action not in {"build", "remove"} and not pack["installed"]:
            raise HTTPException(status_code=409, detail="Map pack is not installed")
        if action in {"rollback", "verify"}:
            worker = maintenance_worker_state()
            if not worker.get("online") or int(worker.get("schemaVersion") or 0) < 2:
                raise HTTPException(status_code=409, detail="Maintenance worker must be restarted before this action is available")
        if action == "rollback" and not pack.get("rollbackReady"):
            raise HTTPException(status_code=409, detail="No complete rollback version is available")
        if action == "update":
            dataset = next((item for item in catalog["datasets"] if str(item.get("id")) == resource_id), {})
            profile = dataset.get("sourceProfile", {}) if isinstance(dataset.get("sourceProfile"), dict) else {}
            state_url = str(profile.get("stateUrl") or "")
            upstream = read_json_file(MAINTENANCE_ROOT / "upstream-state.json") or {}
            remote = (upstream.get("sources") or {}).get(state_url, {}) if state_url else {}
            remote_sequence = str(remote.get("sequenceNumber") or "")
            installed_sequence = str(pack.get("sourceSequence") or "")
            local_snapshot_sequence = str(pack.get("currentSourceSequence") or "")
            remote_relation = source_sequence_relation(remote_sequence, installed_sequence)
            is_current = (
                bool(remote_relation is not None and remote_relation <= 0)
                or bool(not remote_sequence and installed_sequence and local_snapshot_sequence == installed_sequence)
            )
            if is_current:
                raise HTTPException(status_code=409, detail="上游序列不比本地版本新；如需重新生成，请使用“重建”")
            if remote_sequence and installed_sequence and remote_relation is None:
                raise HTTPException(status_code=409, detail="无法安全比较上游与本地序列，请重新检查上游状态")
        if action == "remove" and payload.confirmToken != resource_id:
            raise HTTPException(status_code=409, detail="Protected removal requires the map pack id as confirmation")
        label = f"{pack.get('shortName') or pack.get('name')}地图包"
        operation = "region-pack"
        heavy = action != "remove"
    else:
        specification = STATIC_MAINTENANCE_RESOURCES.get(resource_id)
        if not specification or action != "update":
            raise HTTPException(status_code=404, detail="Maintenance resource or action is not allowed")
        label = str(specification["label"])
        operation = resource_id
        heavy = bool(specification["heavy"])

    for existing in maintenance_jobs():
        if existing.get("resourceId") != resource_id or existing.get("status") not in {"queued", "running"}:
            continue
        if existing.get("action") == action:
            return existing
        raise HTTPException(status_code=409, detail="该资源已有其他维护任务，完成或取消后才能执行新操作")

    now = datetime.now().astimezone().isoformat()
    job_id = uuid.uuid4().hex
    job = {
        "id": job_id,
        "resourceId": resource_id,
        "action": action,
        "operation": operation,
        "label": label,
        "heavy": heavy,
        "priority": 100 if heavy else 20,
        "automatic": False,
        "attempts": 0,
        "maxAttempts": 1 if heavy else 2,
        "nextAttemptAt": now,
        "cancelRequested": False,
        "status": "queued",
        "message": "等待本机维护服务处理",
        "requestedAt": now,
        "startedAt": None,
        "finishedAt": None,
        "exitCode": None,
        "logFile": f"logs/{job_id}.log",
    }
    write_json_file(MAINTENANCE_ROOT / "jobs" / f"{job_id}.json", job)
    return job


@app.delete("/maintenance/jobs/{job_id}")
def cancel_maintenance_job(job_id: str) -> dict[str, Any]:
    path = MAINTENANCE_ROOT / "jobs" / f"{job_id}.json"
    job = read_json_file(path)
    if not job:
        raise HTTPException(status_code=404, detail="Maintenance job not found")
    if job.get("status") not in {"queued", "running"}:
        raise HTTPException(status_code=409, detail="Only queued or running jobs can be cancelled")
    job["cancelRequested"] = True
    if job.get("status") == "queued":
        job["status"] = "cancelled"
        job["message"] = "任务已取消"
        job["finishedAt"] = datetime.now().astimezone().isoformat()
    else:
        job["message"] = "正在取消任务"
    write_json_file(path, job)
    return job


@app.post("/maintenance/jobs/{job_id}/retry", status_code=202)
def retry_maintenance_job(job_id: str) -> dict[str, Any]:
    path = MAINTENANCE_ROOT / "jobs" / f"{job_id}.json"
    job = read_json_file(path)
    if not job:
        raise HTTPException(status_code=404, detail="Maintenance job not found")
    if job.get("status") not in {"failed", "cancelled"}:
        raise HTTPException(status_code=409, detail="Only failed or cancelled jobs can be retried")
    resource_id = str(job.get("resourceId") or "")
    action = str(job.get("action") or "")
    return create_maintenance_job(MaintenanceJobInput(
        resourceId=resource_id,
        action=action,
        confirmToken=resource_id if action == "remove" else None,
    ))


@app.post("/map-packs/{pack_id}/verify", status_code=202)
def verify_map_pack(pack_id: str) -> dict[str, Any]:
    # Hashing a large PMTiles archive can take minutes. Keep this compatibility
    # route asynchronous so map browsing and the reverse proxy remain responsive.
    return create_maintenance_job(MaintenanceJobInput(resourceId=pack_id, action="verify"))


@app.get("/status")
def status() -> dict[str, Any]:
    with pool.connection() as conn:
        counts = conn.execute(
            """
            SELECT
              (SELECT count(*) FROM app.places) AS places,
              (SELECT count(*) FROM app.tracks) AS tracks,
              (SELECT count(*) FROM app.media) AS media,
              (SELECT count(*) FROM app.change_log) AS changes,
              (SELECT count(*) FROM app.reference_places) AS reference_places
            """
        ).fetchone()
        dataset = conn.execute(
            """
            SELECT id, source_updated_at, imported_at, record_count, sha256, details
            FROM app.dataset_state
            WHERE id='osm_reference_search'
            """
        ).fetchone()
    backup = None
    if BACKUP_ROOT.is_dir():
        directories = sorted((path for path in BACKUP_ROOT.iterdir() if path.is_dir()), reverse=True)
        if directories:
            latest = directories[0]
            manifest = latest / "manifest.json"
            backup = {
                "id": latest.name,
                "created_at": datetime.fromtimestamp(latest.stat().st_mtime).astimezone().isoformat(),
                "verified_manifest": manifest.is_file(),
            }
    backup_policy = read_json_file(MAINTENANCE_ROOT / "backup-policy.json")
    return {"status": "ok", **counts, "reference_dataset": dataset, "latest_backup": backup, "backup_policy": backup_policy}


@app.get("/collections")
def list_collections() -> list[dict[str, Any]]:
    with pool.connection() as conn:
        return conn.execute(
            """
            SELECT collection.id, collection.name, collection.color, collection.note,
                   collection.created_at, collection.updated_at, count(membership.place_id) AS place_count
            FROM app.collections AS collection
            LEFT JOIN app.place_collections AS membership ON membership.collection_id=collection.id
            GROUP BY collection.id
            ORDER BY collection.created_at, collection.name
            """
        ).fetchall()


@app.post("/collections", status_code=201)
def create_collection(payload: CollectionInput) -> dict[str, Any]:
    collection_id = payload.id or str(uuid.uuid4())
    with pool.connection() as conn:
        try:
            return conn.execute(
                """
                INSERT INTO app.collections (id, name, color, note)
                VALUES (%s, %s, %s, %s)
                RETURNING id, name, color, note, created_at, updated_at
                """,
                [collection_id, payload.name, payload.color, payload.note],
            ).fetchone()
        except Exception as exc:
            raise HTTPException(status_code=409, detail="Collection could not be created") from exc


@app.put("/collections/{collection_id}")
def update_collection(collection_id: str, payload: CollectionInput) -> dict[str, Any]:
    with pool.connection() as conn:
        row = conn.execute(
            """
            UPDATE app.collections SET name=%s, color=%s, note=%s
            WHERE id=%s
            RETURNING id, name, color, note, created_at, updated_at
            """,
            [payload.name, payload.color, payload.note, collection_id],
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Collection not found")
    return row


@app.delete("/collections/{collection_id}")
def delete_collection(collection_id: str) -> dict[str, str]:
    with pool.connection() as conn:
        row = conn.execute(
            "DELETE FROM app.collections WHERE id=%s RETURNING id", [collection_id]
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Collection not found")
    return {"status": "deleted", "id": collection_id}


@app.get("/search")
def search(
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(default=24, ge=1, le=50),
) -> dict[str, Any]:
    query = q.strip()
    if not query:
        return {"query": q, "results": []}
    contains = f"%{query}%"
    prefix = f"{query}%"
    with pool.connection() as conn:
        rows = conn.execute(
            """
            WITH matches AS (
              SELECT 'personal_place'::text AS kind, id, name,
                     concat_ws(' · ', nullif(province, ''), nullif(category, '')) AS subtitle,
                     category, ''::text AS subtype, 0 AS source_priority,
                     CASE WHEN lower(name)=lower(%s) THEN 120
                          WHEN name ILIKE %s THEN 100 ELSE 80 END::double precision AS score,
                     ST_X(geom) AS longitude, ST_Y(geom) AS latitude,
                     jsonb_build_object('rating', rating, 'note', note, 'media_count',
                       (SELECT count(*) FROM app.media WHERE place_id=app.places.id)) AS details
              FROM app.places
              WHERE name ILIKE %s OR note ILIKE %s OR province ILIKE %s OR tags::text ILIKE %s

              UNION ALL

              SELECT 'personal_track', id, name,
                     concat_ws(' · ', nullif(activity, ''), round((distance_m / 1000.0)::numeric, 1)::text || ' km'),
                     activity, '', 0,
                     CASE WHEN lower(name)=lower(%s) THEN 120
                          WHEN name ILIKE %s THEN 100 ELSE 80 END::double precision,
                     ST_X(ST_Centroid(geom)), ST_Y(ST_Centroid(geom)),
                     jsonb_build_object('distance_m', distance_m, 'note', note)
              FROM app.tracks
              WHERE name ILIKE %s OR note ILIKE %s OR tags::text ILIKE %s

              UNION ALL

              SELECT 'reference', id, name,
                     concat_ws(' · ', nullif(category, ''), nullif(subtype, '')),
                     category, subtype, 1,
                     (CASE WHEN lower(name)=lower(%s) THEN 120
                           WHEN name ILIKE %s THEN 100 ELSE 60 END
                      + similarity(search_text, lower(%s)) * 25
                      + CASE category WHEN 'place' THEN 8 WHEN 'railway' THEN 6
                                      WHEN 'tourism' THEN 5 WHEN 'amenity' THEN 4 ELSE 0 END)::double precision,
                     ST_X(geom), ST_Y(geom),
                     jsonb_build_object('tags', tags)
              FROM app.reference_places
              WHERE search_text ILIKE %s
            )
            SELECT kind, id, name, subtitle, category, subtype, longitude, latitude, details
            FROM matches
            ORDER BY source_priority, score DESC, name
            LIMIT %s
            """,
            [
                query, prefix, contains, contains, contains, contains,
                query, prefix, contains, contains, contains,
                query, prefix, query, contains,
                limit,
            ],
        ).fetchall()
    results = list(rows)
    if len(results) < limit:
        try:
            address_results = nominatim_search(query, min(10, limit - len(results)))
            seen = {(round(float(row["longitude"]), 5), round(float(row["latitude"]), 5)) for row in results}
            for item in address_results:
                coordinate = (round(item["longitude"], 5), round(item["latitude"], 5))
                if coordinate not in seen:
                    results.append(item)
                    seen.add(coordinate)
        except UpstreamUnavailable:
            pass
    return {"query": query, "results": results[:limit]}


@app.get("/reference/nearby")
def nearby_reference_places(
    longitude: float = Query(ge=-180, le=180),
    latitude: float = Query(ge=-90, le=90),
    radius_m: int = Query(default=500, ge=25, le=50_000),
    category: str = Query(default="", max_length=120),
    limit: int = Query(default=24, ge=1, le=100),
) -> dict[str, Any]:
    category_filter = category.strip()
    with pool.connection() as conn:
        rows = conn.execute(
            """
            WITH point AS (
              SELECT ST_SetSRID(ST_MakePoint(%s, %s), 4326) AS geom
            )
            SELECT 'reference'::text AS kind, reference.id, name,
                   concat_ws(' · ', nullif(reference.category, ''), nullif(subtype, '')) AS subtitle,
                   reference.category, subtype,
                   ST_X(reference.geom) AS longitude, ST_Y(reference.geom) AS latitude,
                   jsonb_build_object(
                     'tags', tags,
                     'distance_m', round(ST_Distance(reference.geom::geography, point.geom::geography)::numeric)
                   ) AS details
            FROM app.reference_places AS reference
            CROSS JOIN point
            WHERE reference.geom && ST_Expand(point.geom, %s / 111000.0)
              AND ST_DWithin(reference.geom::geography, point.geom::geography, %s)
              AND (%s = '' OR reference.category = %s OR subtype = %s)
            ORDER BY ST_Distance(reference.geom::geography, point.geom::geography), name
            LIMIT %s
            """,
            [longitude, latitude, radius_m, radius_m,
             category_filter, category_filter, category_filter, limit],
        ).fetchall()
    return {
        "center": [longitude, latitude],
        "radius_m": radius_m,
        "category": category_filter,
        "results": rows,
    }


@app.get("/places.geojson")
def places_geojson(q: str = Query(default="", max_length=200)) -> dict[str, Any]:
    params: list[Any] = []
    where = ""
    if q.strip():
        term = f"%{q.strip()}%"
        where = " WHERE name ILIKE %s OR note ILIKE %s OR province ILIKE %s OR tags::text ILIKE %s"
        params = [term, term, term, term]
    with pool.connection() as conn:
        rows = conn.execute(PLACE_SELECT + where + " ORDER BY updated_at DESC", params).fetchall()
    return {"type": "FeatureCollection", "features": [place_feature(row) for row in rows]}


@app.post("/places", status_code=201)
def create_place(payload: PlaceInput) -> dict[str, Any]:
    place_id = payload.id or str(uuid.uuid4())
    with pool.connection() as conn:
        try:
            row = conn.execute(
                """
                INSERT INTO app.places
                  (id, name, province, category, note, tags, rating, source, geom)
                VALUES
                  (%s, %s, %s, %s, %s, %s, %s, 'manual', ST_SetSRID(ST_MakePoint(%s, %s), 4326))
                RETURNING id, version
                """,
                [place_id, payload.name, payload.province, payload.category, payload.note,
                 Jsonb(payload.tags), payload.rating, payload.longitude, payload.latitude],
            ).fetchone()
            replace_place_collections(conn, place_id, payload.collection_ids)
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=409, detail="Place could not be created") from exc
    return row


@app.put("/places/{place_id}")
def update_place(place_id: str, payload: PlaceInput) -> dict[str, Any]:
    if payload.version is None:
        raise HTTPException(status_code=428, detail="The current place version is required")
    with pool.connection() as conn:
        row = conn.execute(
            """
            UPDATE app.places
            SET name=%s, province=%s, category=%s, note=%s, tags=%s, rating=%s,
                geom=ST_SetSRID(ST_MakePoint(%s, %s), 4326), sync_state='local'
            WHERE id=%s AND version=%s
            RETURNING id, version
            """,
            [payload.name, payload.province, payload.category, payload.note, Jsonb(payload.tags),
             payload.rating, payload.longitude, payload.latitude, place_id, payload.version],
        ).fetchone()
        if row:
            replace_place_collections(conn, place_id, payload.collection_ids)
        if not row:
            current = conn.execute("SELECT version FROM app.places WHERE id=%s", [place_id]).fetchone()
            if not current:
                raise HTTPException(status_code=404, detail="Place not found")
            raise HTTPException(
                status_code=409,
                detail={"message": "Place changed since it was opened", "current_version": current["version"]},
            )
    return row


@app.delete("/places/{place_id}")
def delete_place(place_id: str) -> dict[str, str]:
    delete_linked_media("place_id", place_id)
    with pool.connection() as conn:
        row = conn.execute("DELETE FROM app.places WHERE id=%s RETURNING id", [place_id]).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Place not found")
    return {"deleted": row["id"]}


@app.get("/tracks.geojson")
def tracks_geojson(q: str = Query(default="", max_length=200)) -> dict[str, Any]:
    params: list[Any] = []
    where = ""
    if q.strip():
        term = f"%{q.strip()}%"
        where = " WHERE name ILIKE %s OR note ILIKE %s OR tags::text ILIKE %s"
        params = [term, term, term]
    with pool.connection() as conn:
        rows = conn.execute(TRACK_SELECT + where + " ORDER BY updated_at DESC", params).fetchall()
    return {"type": "FeatureCollection", "features": [track_feature(row) for row in rows]}


def insert_track(payload: TrackInput, source: str = "manual") -> str:
    track_id = payload.id or str(uuid.uuid4())
    geometry_json = json.dumps(payload.geometry, ensure_ascii=False)
    with pool.connection() as conn:
        row = conn.execute(
            """
            INSERT INTO app.tracks
              (id, name, activity, note, tags, color, distance_m, source, geom)
            VALUES
              (%s, %s, %s, %s, %s, %s,
               ST_Length(ST_Transform(ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)), 3857)),
               %s, ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)))
            RETURNING id
            """,
            [track_id, payload.name, payload.activity, payload.note, Jsonb(payload.tags),
             payload.color, geometry_json, source, geometry_json],
        ).fetchone()
    return row["id"]


@app.post("/tracks", status_code=201)
def create_track(payload: TrackInput) -> dict[str, str]:
    try:
        return {"id": insert_track(payload)}
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Track geometry could not be stored") from exc


@app.put("/tracks/{track_id}")
def update_track(track_id: str, payload: TrackInput) -> dict[str, Any]:
    if payload.version is None:
        raise HTTPException(status_code=428, detail="The current track version is required")
    geometry_json = json.dumps(payload.geometry, ensure_ascii=False)
    with pool.connection() as conn:
        row = conn.execute(
            """
            UPDATE app.tracks
            SET name=%s, activity=%s, note=%s, tags=%s, color=%s,
                distance_m=ST_Length(ST_Transform(ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)), 3857)),
                geom=ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)), sync_state='local'
            WHERE id=%s AND version=%s
            RETURNING id, version
            """,
            [payload.name, payload.activity, payload.note, Jsonb(payload.tags), payload.color,
             geometry_json, geometry_json, track_id, payload.version],
        ).fetchone()
        if not row:
            current = conn.execute("SELECT version FROM app.tracks WHERE id=%s", [track_id]).fetchone()
            if not current:
                raise HTTPException(status_code=404, detail="Track not found")
            raise HTTPException(
                status_code=409,
                detail={"message": "Track changed since it was opened", "current_version": current["version"]},
            )
    return row


def remove_media_files(rows: list[dict[str, Any]]) -> None:
    for row in rows:
        with pool.connection() as conn:
            duplicate = conn.execute(
                "SELECT 1 FROM app.media WHERE sha256=%s LIMIT 1", [row["sha256"]]
            ).fetchone()
        if duplicate:
            continue
        path = (MEDIA_ROOT / row["stored_path"]).resolve()
        if MEDIA_ROOT.resolve() in path.parents and path.is_file():
            path.unlink()


def delete_linked_media(column: str, record_id: str) -> list[dict[str, Any]]:
    if column not in {"place_id", "track_id"}:
        raise ValueError("unsupported media relationship")
    with pool.connection() as conn:
        rows = conn.execute(
            f"DELETE FROM app.media WHERE {column}=%s RETURNING stored_path, sha256", [record_id]
        ).fetchall()
    removed = list(rows)
    remove_media_files(removed)
    return removed


@app.delete("/tracks/{track_id}")
def delete_track(track_id: str) -> dict[str, str]:
    delete_linked_media("track_id", track_id)
    with pool.connection() as conn:
        row = conn.execute("DELETE FROM app.tracks WHERE id=%s RETURNING id", [track_id]).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Track not found")
    return {"deleted": row["id"]}


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


@app.post("/imports/gpx", status_code=201)
async def import_gpx(file: UploadFile = File(...)) -> dict[str, Any]:
    content = await file.read(16 * 1024 * 1024 + 1)
    if len(content) > 16 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="GPX file is too large")
    try:
        root = ElementTree.fromstring(content)
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Invalid GPX document") from exc

    created: list[str] = []
    for track_index, track in enumerate(element for element in root.iter() if local_name(element.tag) == "trk"):
        name_node = next((node for node in track if local_name(node.tag) == "name"), None)
        name = (name_node.text or "").strip() if name_node is not None else ""
        segments: list[list[list[float]]] = []
        for segment in (node for node in track.iter() if local_name(node.tag) == "trkseg"):
            points: list[list[float]] = []
            for point in (node for node in segment if local_name(node.tag) == "trkpt"):
                try:
                    points.append([float(point.attrib["lon"]), float(point.attrib["lat"])])
                except (KeyError, ValueError):
                    continue
            if len(points) >= 2:
                segments.append(points)
        if not segments:
            continue
        geometry = {"type": "MultiLineString", "coordinates": segments}
        payload = TrackInput(
            name=name or f"{Path(file.filename or 'track.gpx').stem} {track_index + 1}",
            activity="other",
            tags=["gpx"],
            geometry=geometry,
        )
        created.append(insert_track(payload, source="gpx"))

    if not created:
        raise HTTPException(status_code=422, detail="No valid GPX tracks were found")
    return {"created": created, "count": len(created)}


def image_captured_at(content: bytes) -> datetime | None:
    try:
        with Image.open(BytesIO(content)) as image:
            image.verify()
        with Image.open(BytesIO(content)) as image:
            exif = image.getexif()
            value = exif.get(36867) or exif.get(306)
            return datetime.strptime(value, "%Y:%m:%d %H:%M:%S") if value else None
    except Exception as exc:
        raise HTTPException(status_code=422, detail="The uploaded file is not a valid image") from exc


@app.post("/media", status_code=201)
async def upload_media(
    file: UploadFile = File(...),
    place_id: str | None = None,
    track_id: str | None = None,
    note: str = "",
) -> dict[str, Any]:
    if not place_id and not track_id:
        raise HTTPException(status_code=422, detail="place_id or track_id is required")
    content = await file.read(MAX_MEDIA_BYTES + 1)
    if len(content) > MAX_MEDIA_BYTES:
        raise HTTPException(status_code=413, detail="Image is too large")

    captured_at = image_captured_at(content)
    digest = hashlib.sha256(content).hexdigest()
    suffix = Path(file.filename or "image").suffix.lower()
    if suffix not in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".tif", ".tiff"}:
        suffix = mimetypes.guess_extension(file.content_type or "") or ".img"
    relative_path = Path(digest[:2]) / f"{digest}{suffix}"
    destination = MEDIA_ROOT / relative_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    created_file = not destination.exists()
    if not destination.exists():
        destination.write_bytes(content)

    media_id = str(uuid.uuid4())
    with pool.connection() as conn:
        try:
            row = conn.execute(
                """
                INSERT INTO app.media
                  (id, place_id, track_id, original_name, stored_path, mime_type,
                   byte_size, sha256, captured_at, note)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                [media_id, place_id, track_id, file.filename or "image", relative_path.as_posix(),
                 file.content_type or "application/octet-stream", len(content), digest, captured_at, note[:10000]],
            ).fetchone()
        except Exception as exc:
            if created_file and destination.is_file():
                destination.unlink()
            raise HTTPException(status_code=422, detail="Media link target was not found") from exc
    return {"id": row["id"], "sha256": digest, "captured_at": captured_at}


@app.get("/media")
def list_media(place_id: str | None = None, track_id: str | None = None) -> list[dict[str, Any]]:
    clauses = []
    params: list[Any] = []
    if place_id:
        clauses.append("place_id=%s")
        params.append(place_id)
    if track_id:
        clauses.append("track_id=%s")
        params.append(track_id)
    where = " WHERE " + " AND ".join(clauses) if clauses else ""
    with pool.connection() as conn:
        rows = conn.execute(
            "SELECT id, place_id, track_id, original_name, mime_type, byte_size, sha256, captured_at, note, created_at "
            "FROM app.media" + where + " ORDER BY created_at DESC",
            params,
        ).fetchall()
    for row in rows:
        row["content_url"] = f"/api/media/{row['id']}/content"
    return rows


@app.get("/media/{media_id}/content")
def media_content(media_id: str) -> FileResponse:
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT stored_path, original_name, mime_type FROM app.media WHERE id=%s", [media_id]
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Media not found")
    path = (MEDIA_ROOT / row["stored_path"]).resolve()
    if MEDIA_ROOT.resolve() not in path.parents or not path.is_file():
        raise HTTPException(status_code=404, detail="Media file not found")
    return FileResponse(path, media_type=row["mime_type"], filename=row["original_name"])


@app.delete("/media/orphans")
def delete_orphan_media() -> dict[str, int]:
    with pool.connection() as conn:
        rows = conn.execute(
            "DELETE FROM app.media WHERE place_id IS NULL AND track_id IS NULL RETURNING stored_path, sha256"
        ).fetchall()
    removed = list(rows)
    remove_media_files(removed)
    return {"deleted": len(removed)}


@app.delete("/media/{media_id}")
def delete_media(media_id: str) -> dict[str, str]:
    with pool.connection() as conn:
        row = conn.execute(
            "DELETE FROM app.media WHERE id=%s RETURNING stored_path, sha256", [media_id]
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Media not found")
        duplicate = conn.execute(
            "SELECT 1 FROM app.media WHERE sha256=%s LIMIT 1", [row["sha256"]]
        ).fetchone()
    if not duplicate:
        path = (MEDIA_ROOT / row["stored_path"]).resolve()
        if MEDIA_ROOT.resolve() in path.parents and path.is_file():
            path.unlink()
    return {"deleted": media_id}


@app.get("/tracks/{track_id}.gpx")
def export_track_gpx(track_id: str) -> Response:
    with pool.connection() as conn:
        row = conn.execute(TRACK_SELECT + " WHERE id=%s", [track_id]).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Track not found")
    feature = track_feature(row)
    filename = f"{track_id}.gpx"
    return Response(
        content=gpx_document([feature]), media_type="application/gpx+xml",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@app.get("/export/gpx")
def export_all_gpx() -> Response:
    features = tracks_geojson(q="")["features"]
    return Response(
        content=gpx_document(features), media_type="application/gpx+xml",
        headers={"Content-Disposition": 'attachment; filename="TerraSys-tracks.gpx"'},
    )


@app.get("/export/geojson")
def export_geojson() -> dict[str, Any]:
    places = places_geojson(q="")
    tracks = tracks_geojson(q="")
    return {
        "type": "FeatureCollection",
        "generated_at": datetime.now().astimezone().isoformat(),
        "features": places["features"] + tracks["features"],
    }


@app.get("/export/archive")
def export_personal_archive() -> FileResponse:
    generated_at = datetime.now().astimezone()
    archive_name = f"TerraSys-personal-{generated_at.strftime('%Y%m%d-%H%M%S')}.zip"
    target = EXPORT_ROOT / archive_name
    geojson_bytes = json.dumps(export_geojson(), ensure_ascii=False, indent=2, default=str).encode("utf-8")
    with pool.connection() as conn:
        collections = conn.execute(
            "SELECT id, name, color, note, created_at, updated_at FROM app.collections ORDER BY name"
        ).fetchall()
        media = conn.execute(
            "SELECT id, place_id, track_id, original_name, stored_path, mime_type, byte_size, sha256, captured_at, note, created_at FROM app.media ORDER BY created_at"
        ).fetchall()
    collections_bytes = json.dumps(list(collections), ensure_ascii=False, indent=2, default=str).encode("utf-8")
    media_bytes = json.dumps(list(media), ensure_ascii=False, indent=2, default=str).encode("utf-8")
    gpx_bytes = gpx_document(tracks_geojson(q="")["features"]).encode("utf-8")
    manifest_entries: list[dict[str, Any]] = []
    payloads = {
        "personal.geojson": geojson_bytes,
        "collections.json": collections_bytes,
        "media.json": media_bytes,
        "tracks.gpx": gpx_bytes,
    }
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, content in payloads.items():
            archive.writestr(name, content)
            manifest_entries.append({"path": name, "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()})
        archived_paths: set[str] = set()
        for item in media:
            relative = str(item["stored_path"])
            if relative in archived_paths:
                continue
            path = (MEDIA_ROOT / relative).resolve()
            if MEDIA_ROOT.resolve() not in path.parents or not path.is_file():
                continue
            archive_path = f"media/{relative.replace(os.sep, '/')}"
            archive.write(path, archive_path)
            manifest_entries.append({"path": archive_path, "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
            archived_paths.add(relative)
        manifest = {
            "schemaVersion": 1,
            "generatedAt": generated_at.isoformat(),
            "counts": {"features": len(export_geojson()["features"]), "collections": len(collections), "media": len(media)},
            "files": manifest_entries,
        }
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"))
    for pattern in ("TerraSys-personal-*.zip", "terrasys-personal-*.zip"):
        for path in EXPORT_ROOT.glob(pattern):
            if path != target and generated_at.timestamp() - path.stat().st_mtime > 7 * 86400:
                path.unlink(missing_ok=True)
    return FileResponse(target, media_type="application/zip", filename=archive_name)
