-- Web Mercator lengths are display-space lengths, not ground distances.
-- IS DISTINCT FROM keeps rerunning migrations from touching corrected tracks.
UPDATE app.tracks
SET distance_m = ST_Length(geom::geography)
WHERE distance_m IS DISTINCT FROM ST_Length(geom::geography);

-- The nearby query uses meters and must also find points across the dateline.
CREATE INDEX IF NOT EXISTS reference_places_geography_idx
  ON app.reference_places USING gist ((geom::geography));
