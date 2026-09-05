from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient


PROJECT_ROOT = Path(__file__).resolve().parents[1]
API_ROOT = PROJECT_ROOT / "services" / "api"
sys.path.insert(0, str(API_ROOT))


class TransactionPool:
    """A transaction boundary fixture, with no database or SQL execution."""

    def __init__(self, fail_on: int | None = None) -> None:
        self.committed: list[str] = []
        self.transactions = 0
        self.attempts = 0
        self.fail_on = fail_on

    @contextmanager
    def connection(self):
        self.transactions += 1
        pending: list[str] = []
        pool = self

        class Connection:
            def execute(self, sql, params):
                pool.attempts += 1
                if pool.attempts == pool.fail_on:
                    raise RuntimeError("simulated database failure")
                pending.append(params[1])

                class Result:
                    def fetchone(self):
                        return {"id": params[0]}

                return Result()

        yield Connection()
        self.committed.extend(pending)


class IsolatedApiModule(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        environment = {"DATABASE_URL": "postgresql://unused:unused@127.0.0.1:1/unused"}
        for name in ("MEDIA_ROOT", "EXPORT_ROOT", "TERRAIN_CACHE_ROOT", "MAINTENANCE_ROOT", "MAP_PACK_ROOT", "OSM_ROOT"):
            environment[name] = str(root / name.lower())
        module_name = "terrasys_backend_reliability_test_app"
        spec = importlib.util.spec_from_file_location(module_name, API_ROOT / "app" / "main.py")
        cls.api = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = cls.api
        cls.addClassCleanup(sys.modules.pop, module_name, None)
        # Patch before module import: no real ConnectionPool is ever constructed.
        with patch.dict(os.environ, environment), patch("psycopg_pool.ConnectionPool"):
            spec.loader.exec_module(cls.api)


class IsolatedApiTests(IsolatedApiModule):
    def setUp(self) -> None:
        self.pool = TransactionPool()
        self.pool_patch = patch.object(self.api, "pool", self.pool)
        self.pool_patch.start()
        self.addCleanup(self.pool_patch.stop)
        # Do not enter the lifespan: it warms production catalogs in a background thread.
        self.client = TestClient(self.api.app, raise_server_exceptions=False)
        self.addCleanup(self.client.close)

    @staticmethod
    def gpx(second_latitude: str = "32", second_name: str = "second") -> bytes:
        return (
            '<gpx xmlns="http://www.topografix.com/GPX/1/1">'
            '<trk><name>first</name><trkseg><trkpt lon="118" lat="32"/>'
            '<trkpt lon="118.005" lat="32"/></trkseg></trk>'
            f'<trk><name>{second_name}</name><trkseg><trkpt lon="118" lat="{second_latitude}"/>'
            '<trkpt lon="118.005" lat="32"/></trkseg></trk></gpx>'
        ).encode()

    def import_gpx(self, content: bytes):
        return self.client.post("/imports/gpx", files={"file": ("tracks.gpx", content, "application/gpx+xml")})

    def test_invalid_later_track_has_no_partial_commit_on_retry(self) -> None:
        for _ in range(2):
            response = self.import_gpx(self.gpx(second_latitude="91"))
            self.assertEqual(response.status_code, 422)
            self.assertIn("track 2", response.json()["detail"])
        self.assertEqual(self.pool.transactions, 0)
        self.assertEqual(self.pool.committed, [])

    def test_non_numeric_coordinate_and_long_name_reject_before_writing(self) -> None:
        for content in (self.gpx(second_latitude="invalid"), self.gpx(second_name="x" * 201)):
            self.assertEqual(self.import_gpx(content).status_code, 422)
        self.assertEqual(self.pool.transactions, 0)

    def test_valid_tracks_commit_together(self) -> None:
        response = self.import_gpx(self.gpx())
        self.assertEqual(response.status_code, 201, response.text)
        self.assertEqual(response.json()["count"], 2)
        self.assertEqual(len(set(response.json()["created"])), 2)
        self.assertEqual(self.pool.committed, ["first", "second"])
        self.assertEqual(self.pool.transactions, 1)

    def test_database_failure_rolls_back_the_entire_import(self) -> None:
        self.pool.fail_on = 2
        self.assertEqual(self.import_gpx(self.gpx()).status_code, 500)
        self.assertEqual(self.pool.transactions, 1)
        self.assertEqual(self.pool.committed, [])

    def test_invalid_xml_has_no_transaction(self) -> None:
        self.assertEqual(self.import_gpx(b"<gpx>").status_code, 422)
        self.assertEqual(self.pool.transactions, 0)

    def test_activation_journal_hides_current_pack_and_changes_cache_revision(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(self.api, "MAP_PACK_ROOT", Path(directory)):
            root = Path(directory)
            (root / "test.pmtiles").write_bytes(b"base")
            (root / "test.details.pmtiles").write_bytes(b"details")
            (root / "test.manifest.json").write_text(json.dumps({
                "product": {"bytes": 4}, "details": {"file": "test.details.pmtiles", "bytes": 7},
            }), encoding="utf-8")
            dataset = {"id": "test", "url": "/maps/test.pmtiles", "manifestUrl": "/maps/test.manifest.json"}
            before_revision = self.api.resource_inventory_revision()
            before = self.api.map_pack_state(dataset, disabled_pack_ids=set())
            self.assertTrue(before["installed"])
            self.assertTrue(before["richDetailsReady"])
            journal = root / "test.activation.json"
            journal.write_text('{"phase":"committed"}', encoding="utf-8")
            during_revision = self.api.resource_inventory_revision()
            during = self.api.map_pack_state(dataset, disabled_pack_ids=set())
            self.assertNotEqual(during_revision, before_revision)
            self.assertTrue(during["activationPending"])
            self.assertFalse(during["installed"])
            self.assertFalse(during["enabled"])
            self.assertIsNone(during["detailsUrl"])
            with patch.object(self.api, "map_catalog", return_value={"datasets": [dataset]}):
                response = self.client.get("/map-packs/test/manifest")
            self.assertEqual(response.status_code, 409)
            journal.unlink()
            self.assertNotEqual(self.api.resource_inventory_revision(), during_revision)
            self.assertTrue(self.api.map_pack_state(dataset, disabled_pack_ids=set())["installed"])

    def test_pack_changed_during_snapshot_is_not_exposed_as_installed(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(self.api, "MAP_PACK_ROOT", Path(directory)):
            root = Path(directory)
            product = root / "test.pmtiles"
            product.write_bytes(b"old")
            manifest_text = '{"product":{"bytes":3}}'
            (root / "test.manifest.json").write_text(manifest_text, encoding="utf-8")
            decode = json.loads

            def decode_and_activate(text, *args, **kwargs):
                result = decode(text, *args, **kwargs)
                if text == manifest_text:
                    product.write_bytes(b"new version")
                return result

            with patch.object(self.api.json, "loads", side_effect=decode_and_activate):
                state = self.api.map_pack_state({
                    "id": "test", "url": "/maps/test.pmtiles", "manifestUrl": "/maps/test.manifest.json",
                }, disabled_pack_ids=set())
            self.assertTrue(state["activationPending"])
            self.assertFalse(state["installed"])


@unittest.skipUnless(os.environ.get("TERRASYS_TEST_DATABASE_URL"), "Requires an empty, disposable terrasys_reliability_test PostGIS database")
class PostgisReliabilityTests(IsolatedApiModule):
    """Opt-in real SQL checks. Never falls back to the application's DATABASE_URL."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        import psycopg
        from psycopg.conninfo import conninfo_to_dict
        from psycopg.rows import dict_row

        dsn = os.environ["TERRASYS_TEST_DATABASE_URL"]
        if conninfo_to_dict(dsn).get("dbname") != "terrasys_reliability_test":
            raise RuntimeError("Refusing to use any database other than terrasys_reliability_test")
        cls.connection = psycopg.connect(dsn, connect_timeout=5, row_factory=dict_row)
        cls.addClassCleanup(cls.connection.close)
        if cls.connection.execute("SELECT current_database() AS name").fetchone()["name"] != "terrasys_reliability_test":
            raise RuntimeError("Unexpected database; no application tables will be touched")
        if cls.connection.execute("SELECT 1 FROM pg_namespace WHERE nspname='app'").fetchone():
            raise RuntimeError("The test database must be empty: refusing to touch an existing app schema")
        # Everything, including migrations, stays in this uncommitted transaction.
        for migration in sorted((PROJECT_ROOT / "services" / "postgis" / "migrations").glob("*.sql")):
            cls.connection.execute(migration.read_text(encoding="utf-8"))

    def setUp(self) -> None:
        connection = self.connection
        connection.execute("SAVEPOINT reliability_case")

        def rollback_case() -> None:
            connection.execute("ROLLBACK TO SAVEPOINT reliability_case")
            connection.execute("RELEASE SAVEPOINT reliability_case")

        self.addCleanup(rollback_case)

        class Pool:
            @contextmanager
            def connection(self):
                with connection.transaction():
                    yield connection

        patcher = patch.object(self.api, "pool", Pool())
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_create_and_update_track_store_ground_distance(self) -> None:
        track_id = self.api.insert_track(self.api.TrackInput(
            name="distance fixture", geometry={"type": "LineString", "coordinates": [[118, 32], [118.005, 32]]},
        ))
        row = self.connection.execute("SELECT distance_m, version FROM app.tracks WHERE id=%s", [track_id]).fetchone()
        self.assertGreater(row["distance_m"], 470)
        self.assertLess(row["distance_m"], 475)
        self.api.update_track(track_id, self.api.TrackInput(
            name="distance fixture", version=row["version"],
            geometry={"type": "LineString", "coordinates": [[118, 60], [118.005, 60]]},
        ))
        updated = self.connection.execute("SELECT distance_m FROM app.tracks WHERE id=%s", [track_id]).fetchone()
        self.assertGreater(updated["distance_m"], 275)
        self.assertLess(updated["distance_m"], 285)

    def test_nearby_includes_east_west_points_and_crosses_dateline(self) -> None:
        cases = [([118, 32], [118.005, 32]), ([118, 60], [118.008, 60]), ([179.999, 0], [-179.999, 0])]
        for index, (center, candidate) in enumerate(cases):
            identifier = f"nearby-fixture-{index}"
            self.connection.execute(
                "INSERT INTO app.reference_places (id,name,search_text,geom) VALUES (%s,%s,%s,ST_SetSRID(ST_MakePoint(%s,%s),4326))",
                [identifier, identifier, identifier, *candidate],
            )
            result = self.api.nearby_reference_places(
                longitude=center[0], latitude=center[1], radius_m=500, category="", limit=24,
            )
            self.assertIn(identifier, {row["id"] for row in result["results"]})
            self.assertTrue(all(row["details"]["distance_m"] <= 500 for row in result["results"]))

    def test_distance_migration_corrects_existing_tracks_only_once(self) -> None:
        track_id = self.api.insert_track(self.api.TrackInput(
            name="legacy distance fixture", geometry={"type": "LineString", "coordinates": [[118, 32], [118.005, 32]]},
        ))
        self.connection.execute("UPDATE app.tracks SET distance_m=556.59745 WHERE id=%s", [track_id])
        migration = (PROJECT_ROOT / "services" / "postgis" / "migrations" / "008_geography_distances.sql").read_text(encoding="utf-8")
        self.connection.execute(migration)
        corrected = self.connection.execute("SELECT distance_m,version FROM app.tracks WHERE id=%s", [track_id]).fetchone()
        self.assertGreater(corrected["distance_m"], 470)
        self.assertLess(corrected["distance_m"], 475)
        self.connection.execute(migration)
        repeated = self.connection.execute("SELECT distance_m,version FROM app.tracks WHERE id=%s", [track_id]).fetchone()
        self.assertEqual(repeated, corrected)
        index = self.connection.execute("SELECT 1 FROM pg_indexes WHERE schemaname='app' AND indexname='reference_places_geography_idx'").fetchone()
        self.assertIsNotNone(index)


if __name__ == "__main__":
    unittest.main()
