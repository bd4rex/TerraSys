CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
ALTER EXTENSION postgis UPDATE;

CREATE SCHEMA IF NOT EXISTS app;

-- The legacy view depends on app.places.tags and must be recreated after its type migration.
DROP VIEW IF EXISTS app.places_web;

CREATE TABLE IF NOT EXISTS app.places (
  id text PRIMARY KEY,
  name text NOT NULL,
  province text NOT NULL DEFAULT '',
  category text NOT NULL DEFAULT 'todo',
  note text NOT NULL DEFAULT '',
  tags jsonb NOT NULL DEFAULT '[]'::jsonb,
  rating integer NOT NULL DEFAULT 0 CHECK (rating >= 0 AND rating <= 5),
  source text NOT NULL DEFAULT 'manual',
  photo_path text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  sync_state text NOT NULL DEFAULT 'local',
  version integer NOT NULL DEFAULT 1,
  geom geometry(Point, 4326) NOT NULL
);

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'app'
      AND table_name = 'places'
      AND column_name = 'tags'
      AND data_type = 'text'
  ) THEN
    ALTER TABLE app.places
      ALTER COLUMN tags DROP DEFAULT,
      ALTER COLUMN tags TYPE jsonb USING (
        CASE
          WHEN btrim(tags) = '' THEN '[]'::jsonb
          ELSE to_jsonb(string_to_array(tags, ','))
        END
      ),
      ALTER COLUMN tags SET DEFAULT '[]'::jsonb;
  END IF;
END
$migration$;

ALTER TABLE app.places ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS app.tracks (
  id text PRIMARY KEY,
  name text NOT NULL,
  activity text NOT NULL DEFAULT 'other',
  note text NOT NULL DEFAULT '',
  tags jsonb NOT NULL DEFAULT '[]'::jsonb,
  color text NOT NULL DEFAULT '#c94532',
  distance_m double precision NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'manual',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  sync_state text NOT NULL DEFAULT 'local',
  version integer NOT NULL DEFAULT 1,
  geom geometry(MultiLineString, 4326) NOT NULL
);

CREATE TABLE IF NOT EXISTS app.media (
  id text PRIMARY KEY,
  place_id text REFERENCES app.places(id) ON DELETE SET NULL,
  track_id text REFERENCES app.tracks(id) ON DELETE SET NULL,
  original_name text NOT NULL,
  stored_path text NOT NULL UNIQUE,
  mime_type text NOT NULL,
  byte_size bigint NOT NULL CHECK (byte_size >= 0),
  sha256 text NOT NULL,
  captured_at timestamptz,
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  geom geometry(Point, 4326),
  CHECK (place_id IS NOT NULL OR track_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS app.change_log (
  sequence bigserial PRIMARY KEY,
  entity_type text NOT NULL,
  entity_id text NOT NULL,
  operation text NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
  changed_at timestamptz NOT NULL DEFAULT now(),
  snapshot jsonb NOT NULL
);

CREATE OR REPLACE FUNCTION app.touch_record()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  NEW.version = OLD.version + 1;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.capture_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO app.change_log(entity_type, entity_id, operation, snapshot)
    VALUES (TG_TABLE_NAME, OLD.id, TG_OP, to_jsonb(OLD));
    RETURN OLD;
  END IF;

  INSERT INTO app.change_log(entity_type, entity_id, operation, snapshot)
  VALUES (TG_TABLE_NAME, NEW.id, TG_OP, to_jsonb(NEW));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS places_touch_record ON app.places;
CREATE TRIGGER places_touch_record
BEFORE UPDATE ON app.places
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

DROP TRIGGER IF EXISTS tracks_touch_record ON app.tracks;
CREATE TRIGGER tracks_touch_record
BEFORE UPDATE ON app.tracks
FOR EACH ROW EXECUTE FUNCTION app.touch_record();

DROP TRIGGER IF EXISTS places_capture_change ON app.places;
CREATE TRIGGER places_capture_change
AFTER INSERT OR UPDATE OR DELETE ON app.places
FOR EACH ROW EXECUTE FUNCTION app.capture_change();

DROP TRIGGER IF EXISTS tracks_capture_change ON app.tracks;
CREATE TRIGGER tracks_capture_change
AFTER INSERT OR UPDATE OR DELETE ON app.tracks
FOR EACH ROW EXECUTE FUNCTION app.capture_change();

DROP TRIGGER IF EXISTS media_capture_change ON app.media;
CREATE TRIGGER media_capture_change
AFTER INSERT OR UPDATE OR DELETE ON app.media
FOR EACH ROW EXECUTE FUNCTION app.capture_change();

CREATE INDEX IF NOT EXISTS places_geom_idx ON app.places USING gist (geom);
CREATE INDEX IF NOT EXISTS places_province_idx ON app.places (province);
CREATE INDEX IF NOT EXISTS places_category_idx ON app.places (category);
CREATE INDEX IF NOT EXISTS places_updated_at_idx ON app.places (updated_at);
CREATE INDEX IF NOT EXISTS places_name_search_idx ON app.places USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS tracks_geom_idx ON app.tracks USING gist (geom);
CREATE INDEX IF NOT EXISTS tracks_updated_at_idx ON app.tracks (updated_at);
CREATE INDEX IF NOT EXISTS tracks_name_search_idx ON app.tracks USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS media_place_idx ON app.media (place_id);
CREATE INDEX IF NOT EXISTS media_track_idx ON app.media (track_id);
CREATE INDEX IF NOT EXISTS media_sha256_idx ON app.media (sha256);
CREATE INDEX IF NOT EXISTS change_log_entity_idx ON app.change_log (entity_type, entity_id, sequence DESC);

INSERT INTO app.places (
  id, name, province, category, note, tags, rating, source, photo_path,
  created_at, updated_at, sync_state, geom
) VALUES
  (
    'demo-001', '南京示例点', '江苏省', 'todo',
    '江苏 MVP 种子点：后续可替换为真实标记。',
    '["jiangsu", "demo", "mvp"]'::jsonb, 3, 'manual', '',
    '2026-07-03T00:00:00+08:00', '2026-07-03T00:00:00+08:00', 'local',
    ST_SetSRID(ST_MakePoint(118.7969, 32.0603), 4326)
  ),
  (
    'demo-002', '合肥示例点', '安徽省', 'field',
    '安徽 MVP 种子点：用于验证分类、弹窗和矢量瓦片发布。',
    '["anhui", "field", "qfield"]'::jsonb, 4, 'manual', '',
    '2026-07-03T00:00:00+08:00', '2026-07-03T00:00:00+08:00', 'local',
    ST_SetSRID(ST_MakePoint(117.2272, 31.8206), 4326)
  )
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE VIEW app.places_web AS
SELECT
  id, name, province, category, note, tags::text AS tags, rating, source,
  created_at, updated_at, sync_state, version, geom
FROM app.places;

CREATE OR REPLACE VIEW app.tracks_web AS
SELECT
  id, name, activity, note, tags::text AS tags, color, distance_m, source,
  created_at, updated_at, sync_state, version, geom
FROM app.tracks;

COMMENT ON VIEW app.places_web IS '{"attribution":"Map data from OpenStreetMap; personal data owned by the local user"}';
COMMENT ON VIEW app.tracks_web IS '{"attribution":"Personal data owned by the local user"}';
