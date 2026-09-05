from __future__ import annotations

import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Event
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

    def test_cache_expires_and_evicts_least_recently_used_entries(self) -> None:
        cache = TtlCache(max_entries=2)
        with patch("app.live_layers.monotonic", return_value=0):
            cache.get("a", 10, lambda: "a")
            cache.get("b", 10, lambda: "b")
            cache.get("a", 10, lambda: self.fail("a should be cached"))
            cache.get("c", 10, lambda: "c")
            self.assertEqual(list(cache._values), ["a", "c"])
        with patch("app.live_layers.monotonic", return_value=11):
            cache.get("d", 10, lambda: "d")
            self.assertEqual(list(cache._values), ["d"])
        self.assertFalse(cache._inflight)

    def test_cache_shares_slow_load_and_releases_failed_flights(self) -> None:
        cache = TtlCache()
        entered, release = Event(), Event()
        calls = []

        def loader():
            calls.append(1)
            entered.set()
            self.assertTrue(release.wait(3))
            return "loaded"

        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(cache.get, "same", 60, loader)
            self.assertTrue(entered.wait(3))
            second = executor.submit(cache.get, "same", 60, loader)
            release.set()
            self.assertEqual(first.result(timeout=3), second.result(timeout=3))
        self.assertEqual(len(calls), 1)
        with self.assertRaisesRegex(RuntimeError, "down"):
            cache.get("failure", 60, lambda: (_ for _ in ()).throw(RuntimeError("down")))
        self.assertFalse(cache._inflight)
        self.assertEqual(cache.get("failure", 60, lambda: "retry")[0], "retry")

    def test_cache_ttl_starts_after_loader_finishes(self) -> None:
        cache = TtlCache()
        with patch("app.live_layers.monotonic", side_effect=[0, 20, 21]):
            cache.get("slow", 10, lambda: "result")
            value, _ = cache.get("slow", 10, lambda: self.fail("Fresh response expired too early"))
        self.assertEqual(value, "result")

    def test_ais_starts_on_demand_and_disabled_setting_stops_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict("os.environ", {
            "LIVE_LAYER_SETTINGS_PATH": str(Path(directory) / "settings.json"), "AIS_TCP_ENABLED": "true",
        }):
            service = LiveLayerService()
            with patch.object(service.ais, "start") as start, patch.object(service.ais, "stop") as stop:
                service.start()
                service.runtime_status()
                start.assert_not_called()
                service.vessels((-30, 45, 50, 85), 10)
                start.assert_called_once_with(lease_seconds=30)
                service.update_setting("vessels", enabled=False)
                stop.assert_called_once()
                result = service.vessels((-30, 45, 50, 85), 10)
                self.assertEqual(result["properties"]["status"], "disabled")
                self.assertEqual(start.call_count, 1)
                service.update_setting("vessels", enabled=True)
                self.assertEqual(start.call_count, 1)
                service.vessels((-30, 45, 50, 85), 10)
                self.assertEqual(start.call_count, 2)

    def test_disabled_source_does_not_invoke_upstream_loader(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict("os.environ", {
            "LIVE_LAYER_SETTINGS_PATH": str(Path(directory) / "settings.json"),
        }):
            service = LiveLayerService()
            service.update_setting("earthquakes", enabled=False)
            result = service.safe("earthquakes", lambda: self.fail("Disabled source queried upstream"))
            self.assertEqual(result["properties"]["status"], "disabled")

    def test_ais_stop_interrupts_socket_and_idle_receiver_never_connects(self) -> None:
        receiver = AisTcpReceiver("127.0.0.1", 1)
        with patch("app.live_layers.socket.create_connection") as connect:
            receiver._run()
            connect.assert_not_called()
        with patch("app.live_layers.socket.socket") as socket_type:
            connection = socket_type.return_value
            receiver._connection = connection
            receiver.connected = True
            receiver.stop()
            connection.shutdown.assert_called_once()
            connection.close.assert_called_once()
            self.assertFalse(receiver.connected)

    def test_ais_request_during_stop_restarts_after_old_thread_exits(self) -> None:
        receiver = AisTcpReceiver("127.0.0.1", 1)
        with patch("app.live_layers.threading.Thread") as thread_type:
            thread_type.return_value.is_alive.return_value = True
            receiver._thread = thread_type.return_value
            receiver.stop()
            receiver.start()
            thread_type.assert_not_called()
            self.assertTrue(receiver._restart_requested)
            # The stopped receive loop unwinds without opening a socket, then
            # transfers the new lease to a new (mocked) thread.
            with patch("app.live_layers.socket.create_connection") as connect:
                receiver._run()
                connect.assert_not_called()
            thread_type.assert_called_once()
            thread_type.return_value.start.assert_called_once()
            self.assertFalse(receiver._stop.is_set())

    def test_ais_runtime_reflects_idle_connection_instead_of_old_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict("os.environ", {
            "LIVE_LAYER_SETTINGS_PATH": str(Path(directory) / "settings.json"), "AIS_TCP_ENABLED": "true",
        }):
            service = LiveLayerService()
            service.safe("vessels", lambda: {"type": "FeatureCollection", "features": [], "properties": {"status": "ok"}})
            vessel = next(item for item in service.runtime_status()["layers"] if item["id"] == "vessels")
            self.assertEqual(vessel["status"], "idle")
            self.assertIsNotNone(vessel["lastSuccessAt"])
            service.update_setting("vessels", enabled=False)
            vessel = next(item for item in service.runtime_status()["layers"] if item["id"] == "vessels")
            self.assertEqual(vessel["status"], "disabled")
            self.assertFalse(vessel["stream"]["enabled"])

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
