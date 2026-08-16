# Keyed Data Source Decision Catalog

> [简体中文](KEYED_DATA_SOURCES.zh-CN.md) | English · Updated 2026-08-10

This catalog records evaluated sources that are intentionally excluded from the current runtime under the “no sources requiring keys yet” decision. Recheck official quotas and terms immediately before enabling one.

## Candidates and published limits

| Source | Possible overlay | Authentication and cost | Published limit | Main constraints | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [NASA FIRMS](https://firms.modaps.eosdis.nasa.gov/api/map_key/) | Satellite active-fire/hotspot detections | Free email-issued `MAP_KEY` | **5,000 transactions per 10 minutes**; broad or multi-day requests can count as multiple transactions | Preserve FIRMS, satellite, and product attribution; hotspots are not confirmed fires | **High priority** when finer data than EONET events is wanted |
| [OpenAQ v3](https://docs.openaq.org/using-the-api/api-key) | Ground-monitor observations | Free account and `X-API-Key` | **60/minute, 2,000/hour**; 100 records/page by default, maximum 1,000 | Attribute OpenAQ and comply with each original provider's license | Optional complement to the current CAMS model samples |
| [AISStream.io](https://aisstream.io/documentation) | Global live AIS | Login-generated key; currently free beta with no SLA | No fixed daily quota published; per-user/key throttling; subscription changes at most **1/second**; at most **50 MMSIs** in a filter; subscribe within **3 seconds**; global streams can reach about **300 messages/second** | No direct browser CORS; keep the key on the backend; beta API is unstable | **Best first option for global AIS** beyond current Norway coverage |
| [Global Fishing Watch API v3](https://globalfishingwatch.org/our-apis/documentation) | Fishing effort, vessel identity, encounters, loitering, port visits, AIS gaps | Account and Bearer token; non-commercial API use only | No single numeric QPS published; generally **one concurrent 4Wings report per user**; tile zoom up to 12; short date ranges recommended | Attribution required; apparent fishing effort is algorithmic and about **96 hours delayed** | Add only as a delayed analytical overlay, not as live AIS |
| [BarentsWatch AIS API](https://developer.barentswatch.no/docs/AIS/live-ais-api/) | Rich Norway AIS fields and up to 14 days of tracks | Account plus OAuth client ID/secret; open under NLOD | [No formal numeric quota](https://developer.barentswatch.no/docs/intro/); long batch downloads must be sequential in one thread | Norway/Svalbard/Jan Mayen scope; excludes small fishing and leisure vessels; history no older than 14 days | Defer until history or richer vessel details are needed |

## Proposed secret directory

Keep every credential in API-server environment variables or local `services/.env`. Never put one in browser code, Git, screenshots, logs, or GeoJSON responses.

| Variable | Purpose | Sensitive |
| --- | --- | --- |
| `FIRMS_MAP_KEY` | NASA FIRMS API/WMS | Yes |
| `OPENAQ_API_KEY` | OpenAQ v3 | Yes |
| `AISSTREAM_API_KEY` | AISStream WebSocket | Yes |
| `GFW_ACCESS_TOKEN` | Global Fishing Watch API | Yes |
| `BARENTSWATCH_CLIENT_ID` | BarentsWatch OAuth client identifier | Identifier |
| `BARENTSWATCH_CLIENT_SECRET` | BarentsWatch OAuth client secret | Yes |

## Suggested decision order

1. FIRMS for fine-grained active-fire detections.
2. AISStream.io for global live AIS, using viewport and message-type filters.
3. OpenAQ for ground-station observations alongside model data.
4. Global Fishing Watch for delayed fisheries analysis.
5. BarentsWatch OAuth for richer Norway history and metadata.

Any enabled source must remain behind the independent additional-information-layer adapter, declare provenance/latency/coverage, use backend caching and 429 backoff, and preserve source time, attribution, and safety disclaimers in the UI.
