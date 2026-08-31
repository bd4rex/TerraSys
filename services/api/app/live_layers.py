from __future__ import annotations

import json
import math
import os
import socket
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path
from time import monotonic
from typing import Any, Callable
from urllib.parse import urlencode
from urllib.request import Request, urlopen


USER_AGENT = "TerraSys/1.1 (+local personal GIS)"

LIVE_LAYER_CATALOG: tuple[dict[str, Any], ...] = (
    {"id": "earthquakes", "label": "地震", "description": "近 7 日全球自动地震目录", "priority": "P0", "source": "USGS", "sourceUrl": "https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php", "refreshSeconds": 60, "minRefreshSeconds": 30, "maxRefreshSeconds": 3600, "license": "US public domain", "coverage": "全球", "dataLatency": "通常数分钟", "decisionUse": "态势参考"},
    {"id": "wildfires", "label": "山火事件", "description": "经过整理的开放山火事件", "priority": "P0", "source": "NASA EONET", "sourceUrl": "https://eonet.gsfc.nasa.gov/docs/v3", "refreshSeconds": 600, "minRefreshSeconds": 300, "maxRefreshSeconds": 86400, "license": "NASA open data; upstream attribution retained", "coverage": "全球", "dataLatency": "事件源决定", "decisionUse": "事件参考，非逐像元火点"},
    {"id": "disasters", "label": "灾害预警", "description": "洪水、火山、干旱与山火通报", "priority": "P0", "source": "GDACS", "sourceUrl": "https://www.gdacs.org/gdacsapi/", "refreshSeconds": 300, "minRefreshSeconds": 120, "maxRefreshSeconds": 21600, "license": "GDACS terms; attribution required", "coverage": "全球", "dataLatency": "通常数分钟至数小时", "decisionUse": "不能替代当地正式预警"},
    {"id": "air-quality", "label": "空气质量", "description": "CAMS 模型的 3×3 视口采样", "priority": "P0", "source": "Open-Meteo", "sourceUrl": "https://open-meteo.com/en/docs/air-quality-api", "refreshSeconds": 900, "minRefreshSeconds": 300, "maxRefreshSeconds": 86400, "license": "CC BY 4.0; non-commercial free API", "coverage": "全球模型", "dataLatency": "逐小时模型", "decisionUse": "模型参考，非地面站实测"},
    {"id": "floods", "label": "河流流量", "description": "GloFAS 河流流量模式采样", "priority": "P0", "source": "Open-Meteo Flood / GloFAS", "sourceUrl": "https://open-meteo.com/en/docs/flood-api", "refreshSeconds": 21600, "minRefreshSeconds": 3600, "maxRefreshSeconds": 172800, "license": "Copernicus / Open-Meteo attribution", "coverage": "全球模型河网", "dataLatency": "每日模型", "decisionUse": "流量参考，非洪水预警"},
    {"id": "aircraft", "label": "ADS-B 飞机", "description": "当前视口众包飞机位置", "priority": "P0", "source": "ADSB.lol", "sourceUrl": "https://www.adsb.lol/", "refreshSeconds": 8, "minRefreshSeconds": 5, "maxRefreshSeconds": 300, "license": "ODbL", "coverage": "取决于接收站；单次 250 海里", "dataLatency": "近实时", "decisionUse": "不能用于航空安全决策"},
    {"id": "vessels", "label": "AIS 船舶", "description": "挪威沿岸开放 AIS 实时流", "priority": "P0", "source": "Norwegian Coastal Administration TCP", "sourceUrl": "https://www.kystverket.no/en/sea-transport-and-ports/ais/access-to-ais-data/", "refreshSeconds": 8, "minRefreshSeconds": 5, "maxRefreshSeconds": 300, "license": "NLOD", "coverage": "挪威、斯瓦尔巴与扬马延附近", "dataLatency": "近实时", "decisionUse": "不能用于航行安全决策"},
    {"id": "ocean-buoys", "label": "海洋浮标", "description": "海洋浮标与沿岸站最新观测", "priority": "P1", "source": "NOAA NDBC", "sourceUrl": "https://www.ndbc.noaa.gov/", "refreshSeconds": 600, "minRefreshSeconds": 300, "maxRefreshSeconds": 86400, "license": "US public data", "coverage": "以美国及合作站为主", "dataLatency": "站点上报决定", "decisionUse": "观测参考"},
    {"id": "cyclones", "label": "热带气旋", "description": "近 30 日全球热带气旋通报", "priority": "P1", "source": "GDACS", "sourceUrl": "https://www.gdacs.org/gdacsapi/", "refreshSeconds": 300, "minRefreshSeconds": 120, "maxRefreshSeconds": 21600, "license": "GDACS terms; attribution required", "coverage": "全球", "dataLatency": "通常数分钟至数小时", "decisionUse": "不能替代气象机构正式路径"},
)

KEYED_SOURCE_CANDIDATES: tuple[dict[str, Any], ...] = (
    {"id": "nasa-firms", "label": "NASA FIRMS", "layer": "卫星活跃火点", "status": "candidate", "authentication": "免费 MAP_KEY", "callLimit": "5,000 transactions / 10 分钟", "sourceUrl": "https://firms.modaps.eosdis.nasa.gov/api/map_key/", "recommendation": "优先考虑"},
    {"id": "openaq", "label": "OpenAQ v3", "layer": "地面空气质量实测", "status": "candidate", "authentication": "免费 API key", "callLimit": "60 次/分钟；2,000 次/小时", "sourceUrl": "https://docs.openaq.org/using-the-api/rate-limits", "recommendation": "可选增强"},
    {"id": "aisstream", "label": "AISStream.io", "layer": "全球实时 AIS", "status": "candidate", "authentication": "登录生成 API key", "callLimit": "未公布日额度；订阅更新 1 次/秒", "sourceUrl": "https://aisstream.io/documentation", "recommendation": "全球 AIS 首选候选"},
    {"id": "global-fishing-watch", "label": "Global Fishing Watch", "layer": "渔业行为与船舶事件", "status": "candidate", "authentication": "账号与 Bearer token", "callLimit": "通常每用户 1 个并发报告", "sourceUrl": "https://globalfishingwatch.org/our-apis/documentation", "recommendation": "专题分析时接入"},
    {"id": "barentswatch", "label": "BarentsWatch AIS API", "layer": "挪威 AIS 详情与历史", "status": "candidate", "authentication": "OAuth client ID/secret", "callLimit": "无固定数字；批量下载单线程", "sourceUrl": "https://developer.barentswatch.no/docs/AIS/live-ais-api/", "recommendation": "需要历史轨迹时接入"},
)


def utc_now() -> datetime:
    return datetime.now(UTC)


def iso_utc(value: datetime | None = None) -> str:
    return (value or utc_now()).astimezone(UTC).isoformat().replace("+00:00", "Z")


def number(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def integer(value: Any) -> int | None:
    parsed = number(value)
    return int(parsed) if parsed is not None else None


def feature_collection(
    features: list[dict[str, Any]],
    *,
    source: str,
    fetched_at: str | None = None,
    status: str = "ok",
    message: str | None = None,
    **metadata: Any,
) -> dict[str, Any]:
    properties: dict[str, Any] = {
        "source": source,
        "status": status,
        "fetchedAt": fetched_at or iso_utc(),
        "count": len(features),
        **metadata,
    }
    if message:
        properties["message"] = message
    return {"type": "FeatureCollection", "features": features, "properties": properties}


def json_request(url: str, timeout: float = 15.0) -> Any:
    request = Request(url, headers={"Accept": "application/json, application/geo+json", "User-Agent": USER_AGENT})
    with urlopen(request, timeout=timeout) as response:
        return json.load(response)


def text_request(url: str, timeout: float = 15.0) -> str:
    request = Request(url, headers={"Accept": "text/plain", "User-Agent": USER_AGENT})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


class TtlCache:
    def __init__(self) -> None:
        self._values: dict[str, tuple[float, Any, str]] = {}
        self._lock = threading.Lock()
        self._load_locks: dict[str, threading.Lock] = {}

    def get(self, key: str, ttl_seconds: float, loader: Callable[[], Any]) -> tuple[Any, str]:
        now = monotonic()
        with self._lock:
            cached = self._values.get(key)
            if cached and cached[0] > now:
                return cached[1], cached[2]
        with self._lock:
            load_lock = self._load_locks.setdefault(key, threading.Lock())
        with load_lock:
            now = monotonic()
            with self._lock:
                cached = self._values.get(key)
                if cached and cached[0] > now:
                    return cached[1], cached[2]
            value = loader()
            fetched_at = iso_utc()
            with self._lock:
                self._values[key] = (now + ttl_seconds, value, fetched_at)
            return value, fetched_at


def longitude_in_bounds(longitude: float, west: float, east: float) -> bool:
    return west <= longitude <= east if west <= east else longitude >= west or longitude <= east


def point_in_bounds(longitude: float, latitude: float, bounds: tuple[float, float, float, float]) -> bool:
    west, south, east, north = bounds
    return south <= latitude <= north and longitude_in_bounds(longitude, west, east)


def geometry_point(geometry: dict[str, Any] | None) -> tuple[float, float] | None:
    if not geometry:
        return None
    coordinates = geometry.get("coordinates")
    while isinstance(coordinates, list) and coordinates and isinstance(coordinates[0], list):
        coordinates = coordinates[0]
    if not isinstance(coordinates, list) or len(coordinates) < 2:
        return None
    longitude, latitude = number(coordinates[0]), number(coordinates[1])
    return (longitude, latitude) if longitude is not None and latitude is not None else None


def geometry_in_bounds(geometry: dict[str, Any] | None, bounds: tuple[float, float, float, float]) -> bool:
    point = geometry_point(geometry)
    return bool(point and point_in_bounds(point[0], point[1], bounds))


def clean_text(value: Any, fallback: str = "") -> str:
    return " ".join(str(value or fallback).replace("@", " ").split())


def normalized_feature(
    *,
    identifier: str,
    longitude: float,
    latitude: float,
    kind: str,
    title: str,
    subtitle: str,
    observed_at: str | None,
    source_label: str,
    source_url: str,
    license_label: str,
    detail: str = "",
    properties: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "type": "Feature",
        "id": identifier,
        "geometry": {"type": "Point", "coordinates": [longitude, latitude]},
        "properties": {
            "kind": kind,
            "title": title,
            "subtitle": subtitle,
            "observedAt": observed_at,
            "sourceLabel": source_label,
            "sourceUrl": source_url,
            "license": license_label,
            "detail": detail,
            **(properties or {}),
        },
    }


def sample_grid(bounds: tuple[float, float, float, float], side: int = 3) -> list[tuple[float, float]]:
    west, south, east, north = bounds
    span = (east - west) if west <= east else (180 - west) + (east + 180)
    points: list[tuple[float, float]] = []
    for row in range(side):
        latitude = south + (north - south) * ((row + 0.5) / side)
        for column in range(side):
            longitude = west + span * ((column + 0.5) / side)
            if longitude > 180:
                longitude -= 360
            points.append((round(longitude, 3), round(latitude, 3)))
    return points


def response_items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    return [payload] if isinstance(payload, dict) else []


class AisTcpReceiver:
    """Small NMEA AIS receiver for an open TCP feed or a user-owned local receiver."""

    def __init__(self, host: str, port: int, enabled: bool = True) -> None:
        self.host = host
        self.port = port
        self.enabled = enabled
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._positions: dict[int, dict[str, Any]] = {}
        self._static: dict[int, dict[str, Any]] = {}
        self._fragments: dict[tuple[str, str], dict[str, Any]] = {}
        self.connected = False
        self.received_count = 0
        self.last_message_at: str | None = None
        self.last_error: str | None = None

    def start(self) -> None:
        if not self.enabled or (self._thread and self._thread.is_alive()):
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="open-ais-receiver", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                with socket.create_connection((self.host, self.port), timeout=15) as connection:
                    connection.settimeout(20)
                    self.connected = True
                    self.last_error = None
                    buffer = b""
                    while not self._stop.is_set():
                        chunk = connection.recv(65536)
                        if not chunk:
                            raise ConnectionError("AIS stream closed")
                        buffer += chunk
                        while b"\n" in buffer:
                            raw_line, buffer = buffer.split(b"\n", 1)
                            self._consume_line(raw_line.decode("ascii", errors="ignore").strip())
            except Exception as exc:
                self.connected = False
                self.last_error = clean_text(exc, exc.__class__.__name__)[:240]
                self._stop.wait(5)
        self.connected = False

    @staticmethod
    def _payload_bits(payload: str, fill_bits: int) -> str:
        bits = "".join(f"{ord(character) - 48 - (8 if ord(character) - 48 > 40 else 0):06b}" for character in payload)
        return bits[:-fill_bits] if fill_bits else bits

    @staticmethod
    def _unsigned(bits: str, start: int, end: int) -> int:
        return int(bits[start:end] or "0", 2)

    @classmethod
    def _signed(cls, bits: str, start: int, end: int) -> int:
        value = cls._unsigned(bits, start, end)
        size = end - start
        return value - (1 << size) if value & (1 << (size - 1)) else value

    @classmethod
    def _ais_text(cls, bits: str, start: int, end: int) -> str:
        alphabet = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?"
        return clean_text("".join(alphabet[cls._unsigned(bits, offset, offset + 6)] for offset in range(start, min(end, len(bits)), 6)))

    def _consume_line(self, line: str) -> None:
        if "!AIVDM" not in line and "!BSVDM" not in line:
            return
        received_at = iso_utc()
        if line.startswith("\\") and "\\!" in line:
            tag, line = line.split("\\!", 1)
            line = "!" + line
            for token in tag.strip("\\").split(","):
                if token.startswith("c:"):
                    try:
                        received_at = iso_utc(datetime.fromtimestamp(float(token[2:].split("*")[0]), UTC))
                    except ValueError:
                        pass
        sentence = line.split("!", 1)[-1].split("*")[0]
        fields = sentence.split(",")
        if len(fields) < 7:
            return
        try:
            total, part = int(fields[1]), int(fields[2])
            sequence, channel, payload = fields[3], fields[4], fields[5]
            fill_bits = int(fields[6])
        except ValueError:
            return
        if total > 1:
            if len(self._fragments) > 500:
                cutoff = monotonic() - 30
                self._fragments = {key: value for key, value in self._fragments.items() if value["seen"] >= cutoff}
            key = (sequence or payload[:6], channel)
            fragment = self._fragments.setdefault(key, {"total": total, "parts": {}, "seen": monotonic()})
            fragment["parts"][part] = payload
            fragment["seen"] = monotonic()
            if len(fragment["parts"]) < total:
                return
            payload = "".join(fragment["parts"].get(index, "") for index in range(1, total + 1))
            del self._fragments[key]
        try:
            self._decode_payload(self._payload_bits(payload, fill_bits), received_at)
        except (IndexError, ValueError):
            return

    def _decode_payload(self, bits: str, received_at: str) -> None:
        message_type = self._unsigned(bits, 0, 6)
        mmsi = self._unsigned(bits, 8, 38)
        if not mmsi:
            return
        if message_type in {1, 2, 3} and len(bits) >= 137:
            position = {
                "navigationStatus": self._unsigned(bits, 38, 42),
                "speedKnots": self._unsigned(bits, 50, 60) / 10,
                "longitude": self._signed(bits, 61, 89) / 600000,
                "latitude": self._signed(bits, 89, 116) / 600000,
                "course": self._unsigned(bits, 116, 128) / 10,
                "heading": self._unsigned(bits, 128, 137),
            }
        elif message_type in {18, 19} and len(bits) >= 133:
            position = {
                "speedKnots": self._unsigned(bits, 46, 56) / 10,
                "longitude": self._signed(bits, 57, 85) / 600000,
                "latitude": self._signed(bits, 85, 112) / 600000,
                "course": self._unsigned(bits, 112, 124) / 10,
                "heading": self._unsigned(bits, 124, 133),
            }
            if message_type == 19 and len(bits) >= 271:
                self._static[mmsi] = {"name": self._ais_text(bits, 143, 263), "shipType": self._unsigned(bits, 263, 271)}
        elif message_type == 5 and len(bits) >= 240:
            self._static[mmsi] = {"name": self._ais_text(bits, 112, 232), "shipType": self._unsigned(bits, 232, 240)}
            return
        elif message_type == 24 and len(bits) >= 160:
            part = self._unsigned(bits, 38, 40)
            current = self._static.get(mmsi, {})
            if part == 0:
                current["name"] = self._ais_text(bits, 40, 160)
            elif len(bits) >= 168:
                current["shipType"] = self._unsigned(bits, 40, 48)
            self._static[mmsi] = current
            return
        else:
            return
        longitude, latitude = position["longitude"], position["latitude"]
        if abs(longitude) > 180 or abs(latitude) > 90:
            return
        position.update({"mmsi": mmsi, "observedAt": received_at, "updatedMonotonic": monotonic()})
        with self._lock:
            self._positions[mmsi] = position
            self.received_count += 1
            self.last_message_at = received_at

    def features(self, bounds: tuple[float, float, float, float], limit: int) -> dict[str, Any]:
        cutoff = monotonic() - 15 * 60
        with self._lock:
            for mmsi in [key for key, value in self._positions.items() if value["updatedMonotonic"] < cutoff]:
                self._positions.pop(mmsi, None)
                self._static.pop(mmsi, None)
            positions = list(self._positions.values())
            static = dict(self._static)
        features: list[dict[str, Any]] = []
        for position in sorted(positions, key=lambda item: item["updatedMonotonic"], reverse=True):
            if position["updatedMonotonic"] < cutoff or not point_in_bounds(position["longitude"], position["latitude"], bounds):
                continue
            vessel = static.get(position["mmsi"], {})
            name = clean_text(vessel.get("name")) or f"MMSI {position['mmsi']}"
            features.append(normalized_feature(
                identifier=f"ais-{position['mmsi']}", longitude=position["longitude"], latitude=position["latitude"],
                kind="vessel", title=name, subtitle=f"{position.get('speedKnots', 0):.1f} kn · MMSI {position['mmsi']}",
                observed_at=position["observedAt"], source_label="Norwegian Coastal Administration open AIS",
                source_url="https://www.kystverket.no/en/sea-transport-and-ports/ais/access-to-ais-data/",
                license_label="Norwegian Licence for Open Government Data (NLOD)",
                detail="挪威沿岸开放 AIS；小型渔船和休闲船等存在公开范围限制。",
                properties={
                    "mmsi": position["mmsi"], "speedKnots": position.get("speedKnots"),
                    "course": position.get("course"), "heading": position.get("heading"),
                    "navigationStatus": position.get("navigationStatus"), **vessel,
                },
            ))
            if len(features) >= limit:
                break
        return feature_collection(
            features, source="open-ais-norway", status="ok" if self.connected else "connecting",
            message=self.last_error, connected=self.connected, receivedCount=self.received_count,
            lastMessageAt=self.last_message_at, coverage="Norway, Svalbard and Jan Mayen region",
        )


class LiveLayerService:
    def __init__(self) -> None:
        self.cache = TtlCache()
        self.settings_path = Path(os.environ.get("LIVE_LAYER_SETTINGS_PATH", "/data/maintenance/live-layer-settings.json"))
        self._settings_lock = threading.Lock()
        self._metrics_lock = threading.Lock()
        self._metrics: dict[str, dict[str, Any]] = {
            item["id"]: {
                "id": item["id"],
                "status": "idle",
                "lastCheckedAt": None,
                "lastSuccessAt": None,
                "lastError": None,
                "objectCount": None,
                "latencyMs": None,
            }
            for item in LIVE_LAYER_CATALOG
        }
        enabled = os.environ.get("AIS_TCP_ENABLED", "true").strip().lower() in {"1", "true", "yes", "on"}
        try:
            ais_port = int(os.environ.get("AIS_TCP_PORT", "5631"))
        except ValueError:
            ais_port = 5631
        self.ais = AisTcpReceiver(
            os.environ.get("AIS_TCP_HOST", "153.44.253.27").strip(),
            ais_port,
            enabled,
        )

    def start(self) -> None:
        self.ais.start()

    def stop(self) -> None:
        self.ais.stop()

    def _read_settings_unlocked(self) -> dict[str, Any]:
        try:
            payload = json.loads(self.settings_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return {"schemaVersion": 1, "layers": {}}
        layers = payload.get("layers") if isinstance(payload, dict) else None
        return {
            "schemaVersion": 1,
            "updatedAt": payload.get("updatedAt") if isinstance(payload, dict) else None,
            "layers": layers if isinstance(layers, dict) else {},
        }

    def _write_settings_unlocked(self, payload: dict[str, Any]) -> None:
        self.settings_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = self.settings_path.with_suffix(f".{os.getpid()}.{threading.get_ident()}.tmp")
        temporary_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary_path.replace(self.settings_path)

    def catalog(self) -> dict[str, Any]:
        with self._settings_lock:
            settings = self._read_settings_unlocked()
        layers: list[dict[str, Any]] = []
        overrides = settings.get("layers", {})
        for definition in LIVE_LAYER_CATALOG:
            item = dict(definition)
            override = overrides.get(item["id"], {}) if isinstance(overrides, dict) else {}
            default_refresh = int(item["refreshSeconds"])
            refresh_seconds = integer(override.get("refreshSeconds")) if isinstance(override, dict) else None
            if refresh_seconds is None:
                refresh_seconds = default_refresh
            refresh_seconds = max(int(item["minRefreshSeconds"]), min(int(item["maxRefreshSeconds"]), refresh_seconds))
            item["defaultRefreshSeconds"] = default_refresh
            item["refreshSeconds"] = refresh_seconds
            item["enabled"] = bool(override.get("enabled", True)) if isinstance(override, dict) else True
            layers.append(item)
        return {
            "schemaVersion": 2,
            "keyPolicy": "no-key-only",
            "updatedAt": settings.get("updatedAt"),
            "enabledCount": sum(1 for item in layers if item["enabled"]),
            "layers": layers,
            "candidates": [dict(item) for item in KEYED_SOURCE_CANDIDATES],
        }

    def update_setting(self, layer_id: str, *, enabled: bool | None = None, refresh_seconds: int | None = None) -> dict[str, Any]:
        definition = next((item for item in LIVE_LAYER_CATALOG if item["id"] == layer_id), None)
        if definition is None:
            raise KeyError(layer_id)
        if enabled is None and refresh_seconds is None:
            raise ValueError("No setting was supplied")
        if refresh_seconds is not None and not int(definition["minRefreshSeconds"]) <= refresh_seconds <= int(definition["maxRefreshSeconds"]):
            raise ValueError(
                f"refreshSeconds must be between {definition['minRefreshSeconds']} and {definition['maxRefreshSeconds']}"
            )
        with self._settings_lock:
            payload = self._read_settings_unlocked()
            layer_settings = payload.setdefault("layers", {}).setdefault(layer_id, {})
            if enabled is not None:
                layer_settings["enabled"] = enabled
            if refresh_seconds is not None:
                layer_settings["refreshSeconds"] = refresh_seconds
            payload["updatedAt"] = iso_utc()
            self._write_settings_unlocked(payload)
        return next(item for item in self.catalog()["layers"] if item["id"] == layer_id)

    def runtime_status(self) -> dict[str, Any]:
        with self._metrics_lock:
            layers = [dict(self._metrics[item["id"]]) for item in LIVE_LAYER_CATALOG]
        vessel = next(item for item in layers if item["id"] == "vessels")
        vessel["stream"] = {
            "enabled": self.ais.enabled,
            "connected": self.ais.connected,
            "receivedCount": self.ais.received_count,
            "lastMessageAt": self.ais.last_message_at,
            "lastError": self.ais.last_error,
            "host": self.ais.host,
            "port": self.ais.port,
        }
        if vessel["status"] == "idle":
            vessel["status"] = "ready" if self.ais.connected else ("unavailable" if self.ais.last_error else "connecting")
            vessel["lastSuccessAt"] = self.ais.last_message_at
            vessel["lastError"] = self.ais.last_error
        return {
            "schemaVersion": 1,
            "generatedAt": iso_utc(),
            "readyCount": sum(1 for item in layers if item["status"] == "ready"),
            "layers": layers,
        }

    def safe(self, layer_id: str, loader: Callable[[], dict[str, Any]]) -> dict[str, Any]:
        started = monotonic()
        checked_at = iso_utc()
        error: str | None = None
        try:
            result = loader()
        except Exception as exc:
            error = clean_text(exc, exc.__class__.__name__)[:300]
            result = feature_collection([], source=layer_id, status="unavailable", message=error)
        properties = result.get("properties", {}) if isinstance(result, dict) else {}
        reported_status = properties.get("status")
        status = reported_status if reported_status in {"unavailable", "connecting"} else "ready"
        metric = {
            "id": layer_id,
            "status": status,
            "lastCheckedAt": checked_at,
            "lastSuccessAt": checked_at if status == "ready" else None,
            "lastError": (error or properties.get("message")) if status in {"unavailable", "connecting"} else None,
            "objectCount": len(result.get("features", [])) if isinstance(result, dict) else 0,
            "latencyMs": round((monotonic() - started) * 1000),
        }
        with self._metrics_lock:
            previous = self._metrics.get(layer_id, {})
            if metric["lastSuccessAt"] is None:
                metric["lastSuccessAt"] = previous.get("lastSuccessAt")
            self._metrics[layer_id] = metric
        return result

    def earthquakes(self, bounds: tuple[float, float, float, float], min_magnitude: float = 1.0) -> dict[str, Any]:
        url = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_week.geojson"
        payload, fetched_at = self.cache.get("usgs-earthquakes-week", 60, lambda: json_request(url))
        features: list[dict[str, Any]] = []
        for item in payload.get("features", []):
            coordinates = item.get("geometry", {}).get("coordinates", [])
            if len(coordinates) < 2:
                continue
            longitude, latitude = number(coordinates[0]), number(coordinates[1])
            magnitude = number(item.get("properties", {}).get("mag"))
            if longitude is None or latitude is None or magnitude is None or magnitude < min_magnitude or not point_in_bounds(longitude, latitude, bounds):
                continue
            properties = item.get("properties", {})
            observed = datetime.fromtimestamp(properties.get("time", 0) / 1000, UTC) if properties.get("time") else None
            depth = number(coordinates[2]) if len(coordinates) > 2 else None
            features.append(normalized_feature(
                identifier=f"usgs-{item.get('id', len(features))}", longitude=longitude, latitude=latitude,
                kind="earthquake", title=clean_text(properties.get("place"), "地震"),
                subtitle=f"M {magnitude:.1f}" + (f" · 深度 {depth:.0f} km" if depth is not None else ""),
                observed_at=iso_utc(observed) if observed else None, source_label="USGS Earthquake Hazards Program",
                source_url=properties.get("url") or url, license_label="US public domain",
                detail="自动地震目录，可能在复核后更新震级与位置。",
                properties={"magnitude": magnitude, "depthKm": depth, "significance": properties.get("sig"), "alert": properties.get("alert"), "tsunami": properties.get("tsunami")},
            ))
        return feature_collection(features, source="usgs", fetched_at=fetched_at)

    def wildfires(self, bounds: tuple[float, float, float, float]) -> dict[str, Any]:
        url = "https://eonet.gsfc.nasa.gov/api/v3/events/geojson?category=wildfires&status=open&days=30&limit=500"
        payload, fetched_at = self.cache.get("eonet-wildfires-30d", 600, lambda: json_request(url))
        features: list[dict[str, Any]] = []
        for item in payload.get("features", []):
            point = geometry_point(item.get("geometry"))
            if not point or not point_in_bounds(point[0], point[1], bounds):
                continue
            properties = item.get("properties", {})
            magnitude = properties.get("magnitudeValue")
            magnitude_text = f"{magnitude:g} {properties.get('magnitudeUnit') or ''}" if isinstance(magnitude, (int, float)) else "开放事件"
            sources = properties.get("sources") or []
            source_url = (sources[0].get("url") if sources and isinstance(sources[0], dict) else None) or properties.get("link") or url
            features.append(normalized_feature(
                identifier=str(properties.get("id") or f"eonet-{len(features)}"), longitude=point[0], latitude=point[1],
                kind="wildfire", title=clean_text(properties.get("title"), "山火事件"), subtitle=magnitude_text.strip(),
                observed_at=properties.get("date"), source_label="NASA EONET", source_url=source_url,
                license_label="NASA open data; event-source attribution retained",
                detail="EONET 是经过整理的开放事件，不等同于卫星逐像元火点。",
                properties={"magnitude": magnitude, "magnitudeUnit": properties.get("magnitudeUnit")},
            ))
        return feature_collection(features, source="nasa-eonet", fetched_at=fetched_at)

    def _gdacs(self) -> tuple[dict[str, Any], str]:
        end = utc_now().date()
        start = end - timedelta(days=30)
        query = urlencode({"eventlist": "EQ;TC;FL;VO;DR;WF", "fromDate": start.isoformat(), "toDate": end.isoformat(), "alertlevel": "green;orange;red"})
        url = f"https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?{query}"
        return self.cache.get(f"gdacs-{start}-{end}", 300, lambda: json_request(url))

    def gdacs(self, bounds: tuple[float, float, float, float], event_types: set[str], source_name: str) -> dict[str, Any]:
        payload, fetched_at = self._gdacs()
        features: list[dict[str, Any]] = []
        names = {"TC": "热带气旋", "FL": "洪水", "VO": "火山", "DR": "干旱", "WF": "山火", "EQ": "地震"}
        for item in payload.get("features", []):
            properties = item.get("properties", {})
            event_type = str(properties.get("eventtype") or "").upper()
            point = geometry_point(item.get("geometry"))
            if event_type not in event_types or not point or not point_in_bounds(point[0], point[1], bounds):
                continue
            severity = properties.get("severitydata") or {}
            report_url = properties.get("url", {}).get("report") if isinstance(properties.get("url"), dict) else "https://www.gdacs.org/"
            alert = clean_text(properties.get("alertlevel"), "Green")
            features.append(normalized_feature(
                identifier=f"gdacs-{event_type}-{properties.get('eventid')}", longitude=point[0], latitude=point[1],
                kind="cyclone" if event_type == "TC" else "disaster",
                title=clean_text(properties.get("name") or properties.get("description"), names.get(event_type, "灾害事件")),
                subtitle=f"{names.get(event_type, event_type)} · {alert} · {clean_text(severity.get('severitytext'))}".strip(" ·"),
                observed_at=properties.get("fromdate"), source_label="GDACS", source_url=report_url,
                license_label="GDACS terms; attribution required", detail="全球灾害通报聚合，不能替代当地主管部门的正式预警。",
                properties={"eventType": event_type, "alertLevel": alert.lower(), "alertScore": properties.get("alertscore"), "country": properties.get("country"), "severity": severity.get("severity")},
            ))
        return feature_collection(features, source=source_name, fetched_at=fetched_at)

    def air_quality(self, bounds: tuple[float, float, float, float]) -> dict[str, Any]:
        samples = sample_grid(bounds)
        latitudes = ",".join(str(point[1]) for point in samples)
        longitudes = ",".join(str(point[0]) for point in samples)
        query = urlencode({"latitude": latitudes, "longitude": longitudes, "current": "pm2_5,pm10,nitrogen_dioxide,ozone,us_aqi,european_aqi", "timezone": "UTC"}, safe=",")
        url = f"https://air-quality-api.open-meteo.com/v1/air-quality?{query}"
        key = f"open-meteo-aq:{latitudes}:{longitudes}"
        payload, fetched_at = self.cache.get(key, 900, lambda: json_request(url))
        features: list[dict[str, Any]] = []
        for index, item in enumerate(response_items(payload)):
            longitude, latitude = number(item.get("longitude")), number(item.get("latitude"))
            current = item.get("current") or {}
            if longitude is None or latitude is None:
                continue
            us_aqi = number(current.get("us_aqi"))
            pm25 = number(current.get("pm2_5"))
            features.append(normalized_feature(
                identifier=f"open-meteo-aq-{index}-{longitude}-{latitude}", longitude=longitude, latitude=latitude,
                kind="air-quality", title=f"空气质量采样 · AQI {us_aqi:.0f}" if us_aqi is not None else "空气质量采样",
                subtitle=f"PM2.5 {pm25:g} μg/m³" if pm25 is not None else "PM2.5 无有效值",
                observed_at=current.get("time"), source_label="Open-Meteo Air Quality API",
                source_url="https://open-meteo.com/en/docs/air-quality-api", license_label="CC BY 4.0; API free for non-commercial use",
                detail="基于 CAMS 模型的视口抽样点，不是当地监测站实测值。",
                properties={"usAqi": us_aqi, "europeanAqi": number(current.get("european_aqi")), "pm25": pm25, "pm10": number(current.get("pm10")), "no2": number(current.get("nitrogen_dioxide")), "ozone": number(current.get("ozone"))},
            ))
        return feature_collection(features, source="open-meteo-air-quality", fetched_at=fetched_at, sampling="3x3 viewport grid")

    def floods(self, bounds: tuple[float, float, float, float]) -> dict[str, Any]:
        samples = sample_grid(bounds)
        latitudes = ",".join(str(point[1]) for point in samples)
        longitudes = ",".join(str(point[0]) for point in samples)
        query = urlencode({"latitude": latitudes, "longitude": longitudes, "daily": "river_discharge,river_discharge_mean,river_discharge_max", "forecast_days": 3}, safe=",")
        url = f"https://flood-api.open-meteo.com/v1/flood?{query}"
        key = f"open-meteo-flood:{latitudes}:{longitudes}"
        payload, fetched_at = self.cache.get(key, 21600, lambda: json_request(url, timeout=20))
        features: list[dict[str, Any]] = []
        for index, item in enumerate(response_items(payload)):
            longitude, latitude = number(item.get("longitude")), number(item.get("latitude"))
            daily = item.get("daily") or {}
            discharge = [number(value) for value in daily.get("river_discharge", [])]
            discharge = [value for value in discharge if value is not None]
            maximum = max(discharge) if discharge else None
            if longitude is None or latitude is None:
                continue
            features.append(normalized_feature(
                identifier=f"glofas-{index}-{longitude}-{latitude}", longitude=longitude, latitude=latitude,
                kind="flood", title="河流流量模式参考", subtitle=f"未来 3 日最大 {maximum:.1f} m³/s" if maximum is not None else "当前位置无有效流量值",
                observed_at=(daily.get("time") or [None])[0], source_label="Open-Meteo Flood API / GloFAS",
                source_url="https://open-meteo.com/en/docs/flood-api", license_label="Copernicus CEMS / Open-Meteo attribution",
                detail="视口抽样的全球河流流量模型值，不代表官方洪水预警，也不宜脱离当地河网解释。",
                properties={"maxDischarge": maximum, "discharge": discharge[:3]},
            ))
        return feature_collection(features, source="open-meteo-flood", fetched_at=fetched_at, sampling="3x3 viewport grid")

    @staticmethod
    def _distance_nm(latitude1: float, longitude1: float, latitude2: float, longitude2: float) -> float:
        phi1, phi2 = math.radians(latitude1), math.radians(latitude2)
        delta_phi, delta_lambda = math.radians(latitude2 - latitude1), math.radians(longitude2 - longitude1)
        value = math.sin(delta_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2
        return 3440.065 * 2 * math.atan2(math.sqrt(value), math.sqrt(max(0, 1 - value)))

    def aircraft(self, bounds: tuple[float, float, float, float], limit: int) -> dict[str, Any]:
        west, south, east, north = bounds
        east_unwrapped = east if west <= east else east + 360
        longitude = (west + east_unwrapped) / 2
        if longitude > 180:
            longitude -= 360
        latitude = (south + north) / 2
        required_radius = max(self._distance_nm(latitude, longitude, corner_lat, corner_lon) for corner_lat in (south, north) for corner_lon in (west, east))
        radius = min(250, max(1, math.ceil(required_radius)))
        url = f"https://api.adsb.lol/v2/lat/{latitude:.4f}/lon/{longitude:.4f}/dist/{radius}"
        key = f"adsb-lol:{latitude:.2f}:{longitude:.2f}:{radius}"
        payload, fetched_at = self.cache.get(key, 5, lambda: json_request(url, timeout=10))
        features: list[dict[str, Any]] = []
        now = utc_now()
        for aircraft in payload.get("ac", []):
            aircraft_longitude, aircraft_latitude = number(aircraft.get("lon")), number(aircraft.get("lat"))
            if aircraft_longitude is None or aircraft_latitude is None or not point_in_bounds(aircraft_longitude, aircraft_latitude, bounds):
                continue
            flight = clean_text(aircraft.get("flight"))
            registration = clean_text(aircraft.get("r"))
            hex_code = clean_text(aircraft.get("hex"))
            seen = number(aircraft.get("seen")) or 0
            altitude = aircraft.get("alt_baro")
            title = flight or registration or f"ICAO {hex_code}"
            features.append(normalized_feature(
                identifier=f"adsb-{hex_code or len(features)}", longitude=aircraft_longitude, latitude=aircraft_latitude,
                kind="aircraft", title=title, subtitle=f"{altitude} ft · {number(aircraft.get('gs')) or 0:g} kt" if altitude is not None else f"{number(aircraft.get('gs')) or 0:g} kt",
                observed_at=iso_utc(now - timedelta(seconds=seen)), source_label="ADSB.lol",
                source_url="https://www.adsb.lol/", license_label="Open Database License (ODbL)",
                detail="众包 ADS-B 接收数据；覆盖取决于接收站，不能用于空中交通安全决策。",
                properties={"icao": hex_code, "flight": flight, "registration": registration, "aircraftType": aircraft.get("t"), "altitude": altitude, "groundSpeed": number(aircraft.get("gs")), "track": number(aircraft.get("track")), "squawk": aircraft.get("squawk"), "operator": aircraft.get("ownOp"), "description": aircraft.get("desc")},
            ))
            if len(features) >= limit:
                break
        return feature_collection(features, source="adsb.lol", fetched_at=fetched_at, partialCoverage=required_radius > 250, queryRadiusNm=radius)

    def ocean_buoys(self, bounds: tuple[float, float, float, float], limit: int) -> dict[str, Any]:
        url = "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt"
        payload, fetched_at = self.cache.get("ndbc-latest-observations", 600, lambda: text_request(url))
        columns = ["station", "latitude", "longitude", "year", "month", "day", "hour", "minute", "windDirection", "windSpeed", "gust", "waveHeight", "dominantPeriod", "averagePeriod", "meanWaveDirection", "pressure", "pressureTendency", "airTemperature", "waterTemperature", "dewPoint", "visibility", "tide"]
        features: list[dict[str, Any]] = []
        for line in payload.splitlines():
            if not line or line.startswith("#"):
                continue
            values = line.split()
            if len(values) < len(columns):
                continue
            row = dict(zip(columns, values))
            longitude, latitude = number(row["longitude"]), number(row["latitude"])
            if longitude is None or latitude is None or not point_in_bounds(longitude, latitude, bounds):
                continue
            try:
                observed_at = iso_utc(datetime(int(row["year"]), int(row["month"]), int(row["day"]), int(row["hour"]), int(row["minute"]), tzinfo=UTC))
            except ValueError:
                observed_at = None
            parsed = {key: (None if value == "MM" else number(value)) for key, value in row.items() if key not in {"station", "year", "month", "day", "hour", "minute"}}
            wind_text = f"{parsed['windSpeed']:g} m/s" if parsed.get("windSpeed") is not None else "缺测"
            wave_text = f"{parsed['waveHeight']:g} m" if parsed.get("waveHeight") is not None else "缺测"
            features.append(normalized_feature(
                identifier=f"ndbc-{row['station']}", longitude=longitude, latitude=latitude, kind="ocean-buoy",
                title=f"NDBC {row['station']}", subtitle=f"风 {wind_text} · 浪高 {wave_text}",
                observed_at=observed_at, source_label="NOAA National Data Buoy Center", source_url=f"https://www.ndbc.noaa.gov/station_page.php?station={row['station'].lower()}",
                license_label="US public data", detail="浮标与沿岸站最新观测；缺测字段会留空。", properties={"station": row["station"], **parsed},
            ))
            if len(features) >= limit:
                break
        return feature_collection(features, source="noaa-ndbc", fetched_at=fetched_at)


live_layers = LiveLayerService()
