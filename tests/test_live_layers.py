from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


API_ROOT = Path(__file__).resolve().parents[1] / "services" / "api"
sys.path.insert(0, str(API_ROOT))

from app.live_layers import AisTcpReceiver, LiveLayerService, TtlCache, point_in_bounds  # noqa: E402


class LiveLayerTests(unittest.TestCase):
    def test_catalog_contains_only_keyless_runtime_layers(self) -> None:
        service = LiveLayerService()
        catalog = service.catalog()
        self.assertEqual(catalog["keyPolicy"], "no-key-only")
        self.assertEqual(len(catalog["layers"]), 9)
        self.assertEqual({item["priority"] for item in catalog["layers"]}, {"P0", "P1"})
        self.assertNotIn("apiKey", str(catalog))
        self.assertEqual(len(catalog["candidates"]), 5)

    def test_layer_settings_are_persisted_and_merged_into_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings_path = Path(directory) / "live-layer-settings.json"
            with patch.dict("os.environ", {"LIVE_LAYER_SETTINGS_PATH": str(settings_path)}):
                service = LiveLayerService()
                updated = service.update_setting("aircraft", enabled=False, refresh_seconds=15)
                self.assertFalse(updated["enabled"])
                self.assertEqual(updated["refreshSeconds"], 15)
                restored = LiveLayerService().catalog()
            aircraft = next(item for item in restored["layers"] if item["id"] == "aircraft")
            self.assertFalse(aircraft["enabled"])
            self.assertEqual(aircraft["refreshSeconds"], 15)

    def test_runtime_status_tracks_successful_and_failed_checks(self) -> None:
        service = LiveLayerService()
        service.safe("earthquakes", lambda: {"type": "FeatureCollection", "features": [{"id": "one"}], "properties": {"status": "ok"}})
        service.safe("wildfires", lambda: (_ for _ in ()).throw(RuntimeError("source down")))
        status = {item["id"]: item for item in service.runtime_status()["layers"]}
        self.assertEqual(status["earthquakes"]["status"], "ready")
        self.assertEqual(status["earthquakes"]["objectCount"], 1)
        self.assertEqual(status["wildfires"]["status"], "unavailable")
        self.assertIn("source down", status["wildfires"]["lastError"])

    def test_ttl_cache_reuses_loaded_value(self) -> None:
        cache = TtlCache()
        calls = 0

        def loader() -> dict[str, int]:
            nonlocal calls
            calls += 1
            return {"value": calls}

        first, _ = cache.get("sample", 60, loader)
        second, _ = cache.get("sample", 60, loader)
        self.assertEqual(first, second)
        self.assertEqual(calls, 1)

    def test_dateline_bounds(self) -> None:
        bounds = (170, -20, -170, 20)
        self.assertTrue(point_in_bounds(179, 0, bounds))
        self.assertTrue(point_in_bounds(-179, 0, bounds))
        self.assertFalse(point_in_bounds(0, 0, bounds))

    def test_earthquake_adapter_normalizes_geojson(self) -> None:
        payload = {
            "features": [{
                "id": "test-1",
                "geometry": {"type": "Point", "coordinates": [121.5, 31.2, 12.0]},
                "properties": {"mag": 4.2, "place": "Test region", "time": 1_700_000_000_000, "url": "https://example.test/event", "sig": 300},
            }]
        }
        service = LiveLayerService()
        with patch("app.live_layers.json_request", return_value=payload):
            result = service.earthquakes((120, 30, 123, 33), 1)
        self.assertEqual(len(result["features"]), 1)
        feature = result["features"][0]
        self.assertEqual(feature["properties"]["kind"], "earthquake")
        self.assertEqual(feature["properties"]["magnitude"], 4.2)
        self.assertEqual(feature["properties"]["depthKm"], 12.0)

    def test_open_ais_nmea_position_is_decoded(self) -> None:
        receiver = AisTcpReceiver("127.0.0.1", 1, enabled=False)
        receiver._consume_line(r"\s:2573255,c:1786339093*06\!BSVDM,1,1,,A,13mKwE0P00PFJ3tS0?g>4?vJ2<0M,0*13")
        result = receiver.features((-30, 45, 50, 85), 100)
        self.assertEqual(len(result["features"]), 1)
        feature = result["features"][0]
        self.assertEqual(feature["properties"]["kind"], "vessel")
        self.assertTrue(45 <= feature["geometry"]["coordinates"][1] <= 85)


if __name__ == "__main__":
    unittest.main()
