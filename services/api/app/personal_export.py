from __future__ import annotations

from typing import Any
from xml.sax.saxutils import escape as xml_escape


def gpx_document(features: list[dict[str, Any]]) -> str:
    tracks: list[str] = []
    for feature in features:
        properties = feature.get("properties", {})
        geometry = feature.get("geometry", {})
        coordinates = geometry.get("coordinates", [])
        segments = [coordinates] if geometry.get("type") == "LineString" else coordinates
        segment_xml = []
        for segment in segments:
            points = "".join(
                f'<trkpt lon="{float(point[0]):.7f}" lat="{float(point[1]):.7f}" />'
                for point in segment
                if isinstance(point, list) and len(point) >= 2
            )
            if points:
                segment_xml.append(f"<trkseg>{points}</trkseg>")
        if segment_xml:
            name = xml_escape(str(properties.get("name") or "未命名轨迹"))
            note = xml_escape(str(properties.get("note") or ""))
            tracks.append(f"<trk><name>{name}</name><desc>{note}</desc>{''.join(segment_xml)}</trk>")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<gpx version="1.1" creator="TerraSys" xmlns="http://www.topografix.com/GPX/1/1">'
        + "".join(tracks)
        + "</gpx>"
    )
