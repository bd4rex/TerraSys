import { escapeHtml, formatBytes, formatDate, formatEstimateRange } from "./format.js";
import { createLiveLayersModule } from "./live-layers.js";

const legacyStorageKeys = [
  "online-provider", "theme", "map-style-schema", "online-map", "poi-density",
  "map-light", "scale-unit", "active-pack", "route-recents", "resource-revision"
];
for (const suffix of legacyStorageKeys) {
  const legacyKey = `giss-${suffix}`;
  const currentKey = `terrasys-${suffix}`;
  if (localStorage.getItem(currentKey) === null && localStorage.getItem(legacyKey) !== null) {
    localStorage.setItem(currentKey, localStorage.getItem(legacyKey));
  }
  localStorage.removeItem(legacyKey);
}

const onlineMapProviders = ["osm", "openfreemap", "esri-imagery", "opentopomap"];
const savedOnlineMapProvider = onlineMapProviders.includes(localStorage.getItem("terrasys-online-provider"))
  ? localStorage.getItem("terrasys-online-provider")
  : "osm";
const previousMapTheme = localStorage.getItem("terrasys-theme");
const mapStyleSchema = "osm-carto-2";
if (localStorage.getItem("terrasys-map-style-schema") !== mapStyleSchema) {
  localStorage.setItem("terrasys-map-style-schema", mapStyleSchema);
  localStorage.setItem("terrasys-theme", ["standard", "explore", "vector"].includes(previousMapTheme) ? "vector" : "osm-carto");
}
const savedMapTheme = localStorage.getItem("terrasys-theme");

const state = {
  catalog: null,
  resourceCatalog: null,
  resourceInventory: null,
  resourceTab: "download",
  resourceRegionId: "world",
  resourceQuery: "",
  resourceLoading: false,
  maintenance: null,
  maintenanceLoading: false,
  maintenanceTimer: null,
  map: null,
  places: { type: "FeatureCollection", features: [] },
  tracks: { type: "FeatureCollection", features: [] },
  collections: [],
  mapPacks: [],
  mapPackBoundaries: {},
  mapCountryBoundaries: {},
  renderedPackIds: [],
  visiblePackIds: new Set(),
  layerPackIds: new Map(),
  activePackId: null,
  viewPackId: "all",
  verifiedPackIds: new Set(),
  selectedResourcePackIds: new Set(),
  resourceMenuPackId: null,
  mapResourceChanged: false,
  onlineMapEnabled: localStorage.getItem("terrasys-online-map") === "true",
  onlineMapStatus: "idle",
  onlineMapProvider: savedOnlineMapProvider,
  onlinePreferredProvider: savedOnlineMapProvider,
  onlineTileErrors: 0,
  onlineVectorLayerIds: [],
  onlineFallbackAnnounced: false,
  onlineStatusTimer: null,
  onlineRetryTimer: null,
  localBaseMapMode: "unknown",
  osmCartoPackIds: null,
  coveragePromptPackId: null,
  coveragePromptDismissedId: null,
  coveragePromptPinnedId: null,
  coveragePromptPinnedUntil: 0,
  terrainDemSource: null,
  liveLayers: null,
  layerGroups: new Map(),
  layerVisibility: {
    land: true,
    roads: true,
    buildings: true,
    poi: true,
    labels: true,
    boundaries: true,
    personal: true,
    personalPoints: true,
    tracks: true,
    photos: true,
    terrain: false,
    contours: false,
    weather: false,
    nautical: false,
    emergency: false
  },
  theme: ["vector", "osm-carto"].includes(savedMapTheme) ? savedMapTheme : "osm-carto",
  mode: null,
  measureKind: "distance",
  measureCoordinates: [],
  poiDensity: ["low", "standard", "high"].includes(localStorage.getItem("terrasys-poi-density")) ? localStorage.getItem("terrasys-poi-density") : "standard",
  mapLight: localStorage.getItem("terrasys-map-light") === "night" ? "night" : "day",
  scaleUnit: ["metric", "imperial", "nautical"].includes(localStorage.getItem("terrasys-scale-unit")) ? localStorage.getItem("terrasys-scale-unit") : "metric",
  scaleControl: null,
  layerMinZoom: new Map(),
  listFilter: "all",
  collectionFilter: "all",
  searchQuery: "",
  resultMode: null,
  resultLabel: "",
  searchResults: [],
  suggestionResults: [],
  searchSuggestionTimer: null,
  searchSuggestionRequestId: 0,
  searchSuggestionController: null,
  serviceStatus: null,
  capabilities: null,
  datasetManifest: null,
  emergencyRequestId: 0,
  route: {
    locations: [null, null],
    costing: "auto",
    result: null,
    resultInput: null,
    requestId: 0,
    controller: null,
    locationSearchIds: [0, 0],
    drafts: [null, null]
  },
  selectedMapFeature: null,
  detailRequestId: 0,
  activePhotoTarget: null,
  legendSignature: "",
  toastTimer: null
};

const elements = {};

function byId(id) {
  return document.getElementById(id);
}

function cacheElements() {
  [
    "panelToggle", "sidePanel", "searchForm", "searchInput", "searchSuggestions", "addPlaceButton",
    "importGpxButton", "routeButton", "measureButton", "systemState", "placeCount", "trackCount",
    "mediaCount", "searchSummary", "personalList", "emptyState", "dbState",
    "martinState", "mapSnapshot", "referenceCount", "geocoderState", "routingState", "elevationState",
    "encyclopediaState", "encyclopediaLink", "backupState", "backupPolicyState",
    "dataVersion", "activePackName", "packSummary", "regionPackList", "availablePackSummary",
    "availablePacksButton", "resourceManagerDialog", "resourceManagerSubtitle", "resourceRefreshButton",
    "resourceDownloadBadge", "resourceLocalBadge", "resourceUpdatesBadge", "resourceDiskFree",
    "resourceStorageTrack", "resourceDiskUsedBar", "resourceManagedUsedBar", "resourceDiskUsed", "resourceManagedSize", "resourceSearchWrap",
    "resourceSearchInput", "resourceManagerBody", "resourceRegionBrowser", "resourceRegionList",
    "resourceManagerContent", "viewSwitcher", "mapShortcuts",
    "layersShortcut", "layersPopover", "layersCloseButton", "liveLayersShortcut", "liveLayersPopover", "liveLayersCloseButton", "liveLayersList", "liveLayersStatus", "legendShortcut", "legendPopover", "legendCloseButton", "legendSourceLabel",
    "legendSourceHint", "legendBaseGrid", "legendDetailGroups", "legendOverlayGrid", "legendOverlayEmpty", "onlineMapShortcut",
    "mapSourcePopover", "mapSourceCloseButton", "mapSourceStatus", "mapCoverageStatus",
    "coveragePrompt", "coveragePromptTitle", "coveragePromptText",
    "coverageDownloadButton", "coverageCloseButton", "modeBanner",
    "modeText", "cancelModeButton", "coordinateReadout", "toast", "placeDialog",
    "placeDialogTitle", "placeCoordinates", "placeForm", "placeId", "placeVersion", "placeName",
    "placeCategory", "placeProvince", "placeTags", "placeRating", "placeNote", "placeCollectionChoices",
    "longitude", "latitude", "gpxInput", "photoInput", "detailPanel",
    "detailEyebrow", "detailTitle", "detailSubtitle", "detailProperties",
    "detailCloseButton", "detailNearbyButton", "detailRouteButton", "detailSaveButton", "detailDeleteButton", "detailMediaSection",
    "detailMediaGrid", "detailAddPhotoButton", "detailSourceText", "detailAvailability", "detailTagsSection", "detailTags",
    "detailKnowledgeSection", "detailKnowledgeLinks", "detailPersonalSection", "detailPersonalLinks", "collectionFilter",
    "manageCollectionsButton", "collectionDialog", "collectionForm", "collectionId",
    "collectionName", "collectionColor", "collectionNote", "collectionManagerList",
    "emergencyFilters", "routePanel", "routeCloseButton", "routeStartLabel", "routeEndLabel", "routeEngineMode", "routeCoverageStatus", "routeRecentSection", "routeRecentList",
    "routeEmpty", "routeResult", "routeDistance", "routeDuration", "routeProfileSection",
    "routeElevationRange", "routeProfileCanvas", "routeManeuvers", "routeClearButton", "routeSpeakButton", "routeSaveButton", "routeSwapButton", "routeLocationButton",
    "trackDialog", "trackForm", "trackSummary", "trackId", "trackVersion", "trackName", "trackActivity", "trackColor", "trackTags", "trackNote"
  ].forEach((id) => {
    elements[id] = byId(id);
  });
}

function icons() {
  if (window.lucide) window.lucide.createIcons({ attrs: { "stroke-width": 1.8 } });
}

function showToast(message, error = false) {
  clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.toggle("error", error);
  elements.toast.hidden = false;
  state.toastTimer = setTimeout(() => {
    elements.toast.hidden = true;
  }, 3600);
}

async function api(path, options = {}) {
  const response = await fetch(`/api${path}`, {
    ...options,
    headers: options.body instanceof FormData
      ? options.headers
      : { "Content-Type": "application/json", ...(options.headers || {}) }
  });
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`;
    try {
      const payload = await response.json();
      const detail = payload.detail;
      message = typeof detail === "string" ? detail : detail?.message || message;
    } catch {
      // Keep the HTTP status when the response has no JSON body.
    }
    throw new Error(message);
  }
  if (response.status === 204) return null;
  return response.json();
}

function activeDataset() {
  return state.catalog?.datasets?.find((dataset) => dataset.id === state.activePackId)
    || state.catalog?.datasets?.[0];
}

function renderingMapCatalog() {
  return { ...state.catalog, datasets: state.catalog?.datasets?.filter((dataset) => dataset.installed !== false && dataset.enabled !== false) || [] };
}

function mapStyleCatalog(datasets) {
  return { ...state.catalog, datasets };
}

function indexRenderedPackLayers(style) {
  const renderedIds = new Set(state.renderedPackIds);
  state.layerPackIds = new Map((style.layers || []).flatMap((layer) => {
    const sourceId = typeof layer.source === "string" ? layer.source : "";
    const packId = state.renderedPackIds.find((id) => sourceId === id || sourceId === `${id}-details`);
    return packId && renderedIds.has(packId) ? [[layer.id, packId]] : [];
  }));
}

function packBoundsIntersectViewport(pack, viewport = state.map?.getBounds()) {
  if (!viewport || !Array.isArray(pack?.bounds) || pack.bounds.length !== 4) return false;
  const packWest = Number(pack.bounds[0]);
  const packSouth = Number(pack.bounds[1]);
  let packEast = Number(pack.bounds[2]);
  const packNorth = Number(pack.bounds[3]);
  const viewportWest = Number(viewport.getWest());
  const viewportSouth = Number(viewport.getSouth());
  let viewportEast = Number(viewport.getEast());
  const viewportNorth = Number(viewport.getNorth());
  if (![packWest, packSouth, packEast, packNorth, viewportWest, viewportSouth, viewportEast, viewportNorth].every(Number.isFinite)) {
    return false;
  }
  if (packNorth < viewportSouth || packSouth > viewportNorth) return false;
  if (packEast < packWest) packEast += 360;
  if (viewportEast < viewportWest) viewportEast += 360;
  if (viewportEast - viewportWest >= 360) return true;
  return [-360, 0, 360].some((offset) => packWest + offset <= viewportEast && packEast + offset >= viewportWest);
}

function viewportMapPackIds() {
  const installed = renderingMapCatalog().datasets;
  if (!state.map) return new Set(installed.map((dataset) => dataset.id));
  const zoom = state.map.getZoom();
  if (zoom < 5) return new Set();
  const viewport = state.map.getBounds();
  return new Set(installed.filter((dataset) => packBoundsIntersectViewport(dataset, viewport)).map((dataset) => dataset.id));
}

function syncMapPackLayerVisibilityForViewport() {
  if (!state.map?.isStyleLoaded()) return;
  const nextIds = viewportMapPackIds();
  const unchanged = nextIds.size === state.visiblePackIds.size
    && [...nextIds].every((id) => state.visiblePackIds.has(id));
  if (unchanged) return;
  state.visiblePackIds = nextIds;
  applyLayerVisibility();
}

function syncMapStyleForInstalledPacks() {
  if (!state.map?.isStyleLoaded()) return false;
  const datasets = renderingMapCatalog().datasets;
  const nextIds = datasets.map((dataset) => dataset.id).sort();
  const currentIds = [...state.renderedPackIds].sort();
  if (nextIds.length === currentIds.length && nextIds.every((id, index) => id === currentIds[index])) return false;
  const generated = window.TerraSysMapStyle.create(mapStyleCatalog(datasets), state.theme);
  state.renderedPackIds = nextIds;
  state.visiblePackIds = new Set(nextIds);
  state.layerGroups = generated.groups;
  indexRenderedPackLayers(generated.style);
  state.map.setStyle(generated.style, { diff: false });
  return true;
}

function createOnlineVectorStyle(theme = state.theme) {
  const onlineVector = state.resourceCatalog?.onlineMaps?.openFreeMapVector;
  if (!onlineVector?.url) return null;
  const attributionUrl = escapeHtml(onlineVector.homepage || "https://openfreemap.org/");
  const attributionText = escapeHtml(onlineVector.attribution || "OpenFreeMap © OpenStreetMap contributors");
  return window.TerraSysMapStyle.create({
    datasets: [{
      id: "online-openfreemap",
      source: {
        type: "vector",
        url: onlineVector.url,
        attribution: `<a href="${attributionUrl}" target="_blank" rel="noreferrer">${attributionText}</a>`
      }
    }]
  }, theme);
}

function combinedInstalledBounds() {
  const datasets = renderingMapCatalog().datasets.filter((dataset) => Array.isArray(dataset.bounds) && dataset.bounds.length === 4);
  if (!datasets.length) return null;
  return [
    Math.min(...datasets.map((dataset) => Number(dataset.bounds[0]))),
    Math.min(...datasets.map((dataset) => Number(dataset.bounds[1]))),
    Math.max(...datasets.map((dataset) => Number(dataset.bounds[2]))),
    Math.max(...datasets.map((dataset) => Number(dataset.bounds[3])))
  ];
}

function installedRegionViews() {
  const datasets = renderingMapCatalog().datasets;
  const combined = combinedInstalledBounds();
  const views = combined ? [{ key: "all", packId: "all", label: "全部", bounds: [[combined[0], combined[1]], [combined[2], combined[3]]] }] : [];
  datasets.forEach((dataset) => {
    const datasetViews = Array.isArray(dataset.views) && dataset.views.length
      ? dataset.views
      : [{ id: "all", label: resourcePackName(dataset), bounds: [[dataset.bounds[0], dataset.bounds[1]], [dataset.bounds[2], dataset.bounds[3]]] }];
    datasetViews.forEach((view) => views.push({
      key: `${dataset.id}:${view.id}`,
      packId: dataset.id,
      label: view.label || resourcePackName(dataset),
      bounds: view.bounds
    }));
  });
  return views;
}

function syncInstalledCatalogDatasets() {
  state.catalog.datasets = state.mapPacks.filter((pack) => pack.installed);
}

function renderViewSwitcher() {
  if (!elements.viewSwitcher) return;
  elements.viewSwitcher.innerHTML = installedRegionViews().map((view) => `
    <button class="${view.packId === state.viewPackId ? "active" : ""}" type="button" data-view="${escapeHtml(view.key)}" data-view-pack="${escapeHtml(view.packId)}">
      ${escapeHtml(view.label)}
    </button>
  `).join("");
}

function renderRegionPacks() {
  const installedPacks = state.mapPacks.filter((pack) => pack.installed);
  const enabledPacks = installedPacks.filter((pack) => pack.enabled !== false);
  const provincePacks = state.mapPacks.filter((pack) => pack.kind === "province");
  const availablePacks = provincePacks.filter((pack) => !pack.installed);
  const coveredProvinces = provincePacks.filter((pack) => pack.covered).length;
  const dataset = activeDataset();
  elements.activePackName.textContent = state.viewPackId === "all" ? "全部已安装区域" : dataset ? resourcePackName(dataset) : "--";
  elements.packSummary.textContent = `${enabledPacks.length} 启用 · ${installedPacks.length - enabledPacks.length} 停用 · ${coveredProvinces} 省已覆盖`;
  const updates = state.resourceInventory?.summary?.updates || state.mapPacks.filter((pack) => pack.updateAvailable).length;
  elements.availablePackSummary.textContent = `${availablePacks.length} 省可独立获取 · ${updates} 可更新`;
  elements.regionPackList.innerHTML = installedPacks.map((pack) => {
    const displayName = resourcePackName(pack);
    const current = pack.id === state.viewPackId;
    const verified = state.verifiedPackIds.has(pack.id) || pack.verification === "verified";
    const warning = pack.updateAvailable || !pack.sizeMatches;
    const stateClass = current ? "current" : warning ? "warning" : "";
    const metadata = pack.installed
      ? `${formatBytes(Number(pack.bytes))} · 数据 ${formatDate(pack.sourceUpdatedAt)}`
      : "未安装";
    const label = pack.enabled === false ? "已停用" : current ? "已聚焦" : verified ? "已校验" : pack.updateAvailable ? "需更新" : "显示中";
    return `
      <div class="region-pack-item ${stateClass}" data-pack-id="${escapeHtml(pack.id)}">
        <span class="region-pack-state"></span>
        <span class="region-pack-copy"><strong>${escapeHtml(displayName)}</strong><span>${escapeHtml(metadata)}</span></span>
        <span class="region-pack-actions">
          <span class="pack-status-label ${verified ? "verified" : ""}">${label}</span>
          ${pack.installed ? `<button class="icon-button compact" type="button" data-pack-verify="${escapeHtml(pack.id)}" title="校验区域包" aria-label="校验 ${escapeHtml(displayName)}"><i data-lucide="shield-check"></i></button>` : ""}
          ${pack.installed && pack.enabled !== false && !current ? `<button class="icon-button compact" type="button" data-pack-open="${escapeHtml(pack.id)}" title="聚焦区域" aria-label="聚焦 ${escapeHtml(displayName)}"><i data-lucide="locate-fixed"></i></button>` : ""}
        </span>
      </div>
    `;
  }).join("");
  if (elements.resourceManagerDialog?.open) renderResourceManager();
  icons();
}

function copyText(text, successMessage) {
  const input = document.createElement("textarea");
  input.value = text;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.opacity = "0";
  document.body.append(input);
  input.select();
  const copied = document.execCommand("copy");
  input.remove();
  if (copied) {
    showToast(successMessage);
    return;
  }
  navigator.clipboard?.writeText(text)
    .then(() => showToast(successMessage))
    .catch(() => showToast(text));
}

function copyRegionPackCommand(packId, action = "Build") {
  const pack = state.mapPacks.find((item) => item.id === packId);
  if (!pack) return;
  const suffix = action === "Remove" ? " -ConfirmRemove" : "";
  const actionLabel = { Build: "构建", Update: "更新", Remove: "移除" }[action] || action;
  copyText(`D:\\TerraSys\\region-pack.cmd ${action} -PackId ${pack.id}${suffix}`, `${pack.shortName || pack.name}${actionLabel}命令已复制`);
}

function mergeResourceCatalog(baseCatalog, worldCatalog) {
  const regions = new Map((baseCatalog.regions || []).map((region) => [region.id, { ...region }]));
  Object.entries(worldCatalog?.regionPatches || {}).forEach(([regionId, patch]) => {
    if (regions.has(regionId)) regions.set(regionId, { ...regions.get(regionId), ...patch });
  });
  (worldCatalog?.regions || []).forEach((region) => regions.set(region.id, region));
  return { ...baseCatalog, worldCatalogVersion: worldCatalog?.version, regions: [...regions.values()] };
}

function resourceRegionName(region) {
  if (!region) return "";
  const fallbackNames = { JP: "日本", TW: "台湾省", HK: "香港特别行政区", MO: "澳门特别行政区" };
  if (fallbackNames[region.isoCode]) return fallbackNames[region.isoCode];
  if (region.isoCode && typeof Intl.DisplayNames === "function") {
    try {
      return new Intl.DisplayNames(["zh-CN"], { type: "region" }).of(region.isoCode) || region.name;
    } catch {
      // Composite regions retain the source catalog label.
    }
  }
  return region.name;
}

function resourcePackName(pack) {
  const regionCode = String(pack?.countryId || "").toUpperCase();
  const fallbackNames = { JP: "日本", TW: "台湾省", HK: "香港特别行政区", MO: "澳门特别行政区" };
  if (fallbackNames[regionCode]) return fallbackNames[regionCode];
  if (pack?.kind === "country" && /^[A-Z]{2}$/.test(regionCode) && typeof Intl.DisplayNames === "function") {
    try {
      return new Intl.DisplayNames(["zh-CN"], { type: "region" }).of(regionCode) || pack.name;
    } catch {
      // Keep the provider name when a code is not recognized by this browser.
    }
  }
  return pack?.name || "未命名区域";
}

function resourceRegion(regionId) {
  return state.resourceCatalog?.regions?.find((region) => region.id === regionId) || null;
}

function resourceType(typeId) {
  return state.resourceCatalog?.resourceTypes?.find((type) => type.id === typeId) || null;
}

function localResourceItem(itemId) {
  return state.resourceInventory?.localGroups
    ?.flatMap((group) => group.items || [])
    .find((item) => item.id === itemId) || null;
}

function resourceStatusLabel(status) {
  return {
    ready: "已安装",
    available: "可获取",
    partial: "部分可用",
    planned: "待接入",
    missing: "未安装",
    external: "卷管理",
    cache: "可重建",
    warning: "需检查",
    online: "需联网"
  }[status] || "待检查";
}

function resourceRegionMeta(region) {
  if (!region) return { label: "目录不可用", tone: "" };
  if (region.id === "world") return { label: "全球目录已接入", tone: "available" };
  if (region.id === "china") {
    const provinces = state.mapPacks.filter((pack) => pack.kind === "province");
    const independent = provinces.filter((pack) => pack.installed).length;
    const covered = provinces.filter((pack) => pack.covered).length;
    return { label: `${provinces.length} 省级单元 · ${independent} 独立安装 · ${covered} 已覆盖`, tone: "ready" };
  }
  return region.status === "ready"
    ? { label: "可获取", tone: "ready" }
    : region.status === "available"
      ? { label: "可获取", tone: "available" }
    : region.status === "partial"
      ? { label: "部分可用", tone: "partial" }
      : { label: "数据源待接入", tone: "" };
}

function renderResourceBreadcrumb(items) {
  return `<nav class="resource-breadcrumb" aria-label="资源路径">${items.map((item, index) => `
    ${index ? '<i data-lucide="chevron-right"></i>' : ""}
    <button type="button" data-resource-region="${escapeHtml(item.id)}">${escapeHtml(item.name)}</button>
  `).join("")}</nav>`;
}

function resourceRegionPath(regionId) {
  const packId = regionId.startsWith("pack:") ? regionId.slice(5) : null;
  const packRegion = packId
    ? state.resourceCatalog?.regions?.find((region) => (region.datasetIds || []).includes(packId))
    : null;
  let current = resourceRegion(packRegion?.id || (packId ? "china" : regionId));
  const path = [];
  while (current) {
    path.unshift({ id: current.id, name: resourceRegionName(current) });
    current = current.parent ? resourceRegion(current.parent) : null;
  }
  if (packId) {
    const pack = state.mapPacks.find((item) => item.id === packId);
    if (pack) path.push({ id: `pack:${pack.id}`, name: resourcePackName(pack) });
  }
  return path;
}

function renderResourceRegionRow(region) {
  const meta = resourceRegionMeta(region);
  const childCount = region.children?.length || region.datasetIds?.length || 0;
  const description = childCount
    ? `${childCount} 个${region.level === "world" ? "洲级目录" : "区域或地图包"}`
    : region.status === "available" ? "Geofabrik 独立离线来源" : "离线资源目录";
  return `
    <button class="resource-region-row" type="button" data-resource-region="${escapeHtml(region.id)}">
      <span class="resource-row-icon"><i data-lucide="${escapeHtml(region.icon || "map")}"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(resourceRegionName(region))}</strong><span>${escapeHtml(description)}</span></span>
      <span class="resource-row-status ${meta.tone}">${escapeHtml(meta.label)}</span>
      <i data-lucide="chevron-right"></i>
    </button>`;
}

function renderResourcePackRow(pack) {
  const job = maintenanceJobFor(pack.id);
  const size = pack.installed ? formatBytes(Number(pack.bytes)) : formatEstimateRange(pack.estimatedInstallGiB, " GB");
  const status = job
    ? { label: maintenanceCompactText(job), tone: job.status === "running" ? "available" : "partial" }
    : pack.installed
    ? { label: "独立安装", tone: "ready" }
    : pack.partialInstall
      ? { label: "待重建清单", tone: "partial" }
      : pack.buildReady
        ? { label: "可构建", tone: "partial" }
        : { label: pack.sourceMode === "direct" ? "需下载源" : "源数据缺失", tone: "" };
  const subtitle = `${pack.groupName || "中国"} · ${pack.abbreviation || pack.shortName || ""} · ${size}${pack.partialInstall ? " · 发现历史文件" : ""}`;
  return `
    <button class="resource-region-row" type="button" data-resource-region="pack:${escapeHtml(pack.id)}" data-resource-pack="${escapeHtml(pack.id)}">
      <span class="resource-row-icon"><i data-lucide="map"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(resourcePackName(pack))}</strong><span>${escapeHtml(subtitle)}</span></span>
      <span class="resource-row-status ${status.tone}">${escapeHtml(status.label)}</span>
      <i data-lucide="chevron-right"></i>
    </button>`;
}

function resourceSelectedPathIds() {
  return new Set(resourceRegionPath(state.resourceRegionId).map((item) => item.id));
}

function renderResourceTreeRegionRow(region, depth, pathIds) {
  const selected = state.resourceRegionId === region.id;
  const ancestor = !selected && pathIds.has(region.id);
  const childCount = (region.children?.length || 0) + (region.datasetIds?.length || 0);
  const meta = resourceRegionMeta(region);
  return `<button class="resource-tree-row ${selected ? "selected" : ancestor ? "ancestor" : ""}" style="--resource-depth:${depth}" type="button" data-resource-region="${escapeHtml(region.id)}" ${selected ? 'aria-current="page"' : ""}>
    <span class="resource-tree-icon"><i data-lucide="${escapeHtml(region.icon || "map")}"></i></span>
    <span class="resource-tree-copy"><strong>${escapeHtml(resourceRegionName(region))}</strong><span>${childCount ? `${childCount} 个区域` : "独立离线来源"}</span></span>
    <span class="resource-tree-state ${meta.tone}">${selected ? "当前" : ancestor ? "展开" : ""}</span>
  </button>`;
}

function renderResourceTreePackRow(pack, depth) {
  const selected = state.resourceRegionId === `pack:${pack.id}`;
  const job = maintenanceJobFor(pack.id);
  const status = job ? maintenanceCompactText(job) : pack.installed ? "已安装" : pack.buildReady ? "可构建" : "需准备";
  return `<button class="resource-tree-row ${selected ? "selected" : ""}" style="--resource-depth:${depth}" type="button" data-resource-region="pack:${escapeHtml(pack.id)}" ${selected ? 'aria-current="page"' : ""}>
    <span class="resource-tree-icon"><i data-lucide="map"></i></span>
    <span class="resource-tree-copy"><strong>${escapeHtml(resourcePackName(pack))}</strong><span>${escapeHtml(pack.groupName || pack.countryId || "区域地图")}</span></span>
    <span class="resource-tree-state ${pack.installed ? "ready" : ""}">${status}</span>
  </button>`;
}

function renderResourceBrowser() {
  if (!elements.resourceRegionList || !state.resourceCatalog) return;
  const query = state.resourceQuery.trim().toLocaleLowerCase("zh-CN");
  if (query) {
    const packs = state.mapPacks.filter((pack) => `${resourcePackName(pack)} ${pack.name} ${pack.shortName || ""} ${pack.abbreviation || ""} ${pack.countryId || ""}`.toLocaleLowerCase("zh-CN").includes(query));
    const packIds = new Set(packs.map((pack) => pack.id));
    const regions = state.resourceCatalog.regions.filter((region) => region.id !== "world" && `${resourceRegionName(region)} ${region.name} ${region.sourceName || ""} ${region.isoCode || ""}`.toLocaleLowerCase("zh-CN").includes(query)
      && !(region.datasetIds || []).some((id) => packIds.has(id)));
    const pathIds = resourceSelectedPathIds();
    elements.resourceRegionList.innerHTML = regions.length || packs.length
      ? `${regions.map((region) => renderResourceTreeRegionRow(region, 0, pathIds)).join("")}${packs.map((pack) => renderResourceTreePackRow(pack, 0)).join("")}`
      : '<div class="resource-tree-empty">没有匹配的区域</div>';
    return;
  }

  const root = resourceRegion(state.resourceCatalog.rootRegion || "world") || resourceRegion("world");
  const pathIds = resourceSelectedPathIds();
  const rows = [`<button class="resource-tree-home ${state.resourceRegionId === root.id ? "selected" : ""}" type="button" data-resource-region="${escapeHtml(root.id)}"><i data-lucide="globe-2"></i><span>${escapeHtml(resourceRegionName(root))}</span></button>`];
  const appendLevel = (region, depth, includeHeading) => {
    const children = (region.children || []).map(resourceRegion).filter(Boolean);
    const packs = (region.datasetIds || []).map((id) => state.mapPacks.find((pack) => pack.id === id)).filter(Boolean)
      .sort((a, b) => Number(a.groupOrder) - Number(b.groupOrder) || Number(a.order) - Number(b.order));
    if (includeHeading && (children.length || packs.length)) rows.push(`<div class="resource-tree-section">${escapeHtml(resourceRegionName(region))}<span>${children.length + packs.length} 项</span></div>`);
    children.forEach((child) => rows.push(renderResourceTreeRegionRow(child, depth, pathIds)));
    packs.forEach((pack) => rows.push(renderResourceTreePackRow(pack, depth)));
  };
  appendLevel(root, 0, false);
  resourceRegionPath(state.resourceRegionId)
    .map((item) => resourceRegion(item.id))
    .filter((region) => region && region.id !== root.id)
    .forEach((region, index) => appendLevel(region, index + 1, true));
  elements.resourceRegionList.innerHTML = rows.join("");
}

function administrativeTypeLabel(value) {
  return {
    province: "省",
    municipality: "直辖市",
    "autonomous-region": "自治区",
    sar: "特别行政区",
    country: "国家或地区",
    region: "区域"
  }[value] || "省级行政区";
}

function resourceTypeState(type) {
  const inventoryItems = {
    "standard-map": "standard-maps",
    contours: "terrain",
    encyclopedia: "encyclopedia",
    fonts: "web-assets",
    styles: "web-assets"
  };
  const localItem = localResourceItem(type.inventoryId || inventoryItems[type.id]);
  if (localItem) {
    if (localItem.status === "ready") {
      const bytes = Number(localItem.bytes);
      const label = Number.isFinite(bytes) && bytes > 0 && !["fonts", "styles"].includes(type.id) ? formatBytes(bytes) : "已就绪";
      return { label, tone: "ready" };
    }
    return { label: resourceStatusLabel(localItem.status), tone: localItem.status === "missing" ? "" : "partial" };
  }
  return { label: resourceStatusLabel(type.support), tone: type.support === "ready" ? "ready" : type.support === "partial" ? "partial" : "" };
}

function renderResourceTypeRow(type, override = null, actionEnabled = true, forceInstall = false) {
  const status = override || resourceTypeState(type);
  const localItem = type.inventoryId ? localResourceItem(type.inventoryId) : null;
  const job = type.installResourceId ? maintenanceJobFor(type.installResourceId) : null;
  const installed = !type.inventoryId || localItem?.status === "ready";
  const actionIcons = { overview: "globe-2", "online-map": "wifi", "standard-mode": "map", "road-mode": "route", contours: "mountain-snow", weather: "cloud-sun", nautical: "anchor", encyclopedia: "book-open", "travel-guide": "landmark", labels: "languages", styles: "palette", tts: "volume-2" };
  if (job) {
    return `
      <div class="resource-type-row resource-download-row has-job ${escapeHtml(job.status)}" data-resource-download-job="${escapeHtml(type.installResourceId)}">
        <span class="resource-row-icon"><i data-lucide="${escapeHtml(type.icon)}"></i></span>
        <span class="resource-row-copy"><strong>${escapeHtml(type.name)}</strong><span>正在安装本地资源</span></span>
        ${renderMaintenanceProgress(job, { id: type.installResourceId, name: type.name, bytes: localItem?.bytes || 0 })}
        <button class="command-button resource-task-action" type="button" data-maintenance-cancel="${escapeHtml(job.id)}" ${job.cancelRequested ? "disabled" : ""}><i data-lucide="circle-x"></i><span>${job.cancelRequested ? "停止中" : "取消"}</span></button>
      </div>`;
  }
  let action = "";
  if ((!installed || forceInstall) && type.installResourceId) {
    action = `<button class="command-button" type="button" data-resource-install="${escapeHtml(type.installResourceId)}"><i data-lucide="download"></i><span>${forceInstall ? "同步" : "安装"}</span></button>`;
  } else if (type.action && actionEnabled && installed) {
    const verb = type.delivery === "library" ? "打开" : type.delivery === "layer" ? "显示" : "使用";
    action = `<button class="icon-button resource-row-action" type="button" data-resource-action="${escapeHtml(type.action)}" title="${verb}${escapeHtml(type.name)}" aria-label="${verb}${escapeHtml(type.name)}"><i data-lucide="${actionIcons[type.action] || "arrow-right"}"></i></button>`;
  }
  return `
    <div class="resource-type-row" data-resource-type="${escapeHtml(type.id)}">
      <span class="resource-row-icon ${type.id === "contours" ? "terrain" : type.id === "encyclopedia" ? "knowledge" : ""}"><i data-lucide="${escapeHtml(type.icon)}"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(type.name)}</strong><span>${escapeHtml(type.description)}</span></span>
      <span class="resource-row-controls"><span class="resource-row-status ${status.tone || ""}">${escapeHtml(status.label)}</span>${action}</span>
    </div>`;
}

function renderPackResources(pack) {
  const job = maintenanceJobFor(pack.id);
  const covered = new Set(state.resourceInventory?.capabilityPackIds || []);
  const capabilityReady = covered.has(pack.id);
  const osmCartoReady = new Set(state.resourceInventory?.osmCartoPackIds || []).has(pack.id);
  const weatherReady = new Set(state.resourceInventory?.weatherPackIds || []).has(pack.id);
  const nauticalReady = new Set(state.resourceInventory?.nauticalPackIds || []).has(pack.id);
  const terrainReady = new Set(state.resourceInventory?.terrainPackIds || []).has(pack.id);
  const standardSize = pack.installed ? formatBytes(Number(pack.bytes)) : formatEstimateRange(pack.estimatedInstallGiB, " GB");
  const standardStatus = pack.installed
    ? { label: `独立安装 · ${standardSize}`, tone: "ready" }
    : { label: standardSize, tone: "partial" };
  const buildTime = formatEstimateRange(pack.estimatedBuildMinutes, " 分钟");
  const temporarySize = pack.estimatedTemporaryGiB !== null && pack.estimatedTemporaryGiB !== undefined && Number.isFinite(Number(pack.estimatedTemporaryGiB))
    ? `临时空间约 ${pack.estimatedTemporaryGiB} GB`
    : "临时空间待测算";
  const controls = job ? "" : [
    `<button class="icon-button resource-row-action" type="button" data-resource-pack-locate="${escapeHtml(pack.id)}" title="在世界地图定位" aria-label="在世界地图定位 ${escapeHtml(resourcePackName(pack))}"><i data-lucide="scan-search"></i></button>`,
    pack.browsePackId ? `<button class="icon-button resource-row-action" type="button" data-resource-pack-open="${escapeHtml(pack.browsePackId)}" title="浏览现有覆盖" aria-label="浏览现有覆盖 ${escapeHtml(pack.name)}"><i data-lucide="map"></i></button>` : "",
    !pack.installed ? `<button class="command-button" type="button" data-resource-pack-job="${escapeHtml(pack.id)}" data-resource-pack-action="build"><i data-lucide="download"></i><span>构建</span></button>` : "",
    pack.installed && pack.updateAvailable ? `<button class="command-button" type="button" data-resource-pack-job="${escapeHtml(pack.id)}" data-resource-pack-action="update"><i data-lucide="refresh-cw"></i><span>更新</span></button>` : ""
  ].join("");
  const sourceState = pack.sourceReady
    ? `${pack.sourceProvider || "OSM"} · 源快照已就绪`
    : Number(pack.sourceSizeMiB) > 0
      ? `${pack.sourceProvider || "OSM"} · 构建时下载约 ${pack.sourceSizeMiB} MB`
      : `${pack.sourceProvider || "OSM"} · 构建时按来源下载`;
  const coverageText = pack.installed ? "省级文件与清单均独立" : "尚无本地地图覆盖";
  const facts = `
    <dl class="resource-pack-facts">
      <div><dt>区域级别</dt><dd>${escapeHtml(administrativeTypeLabel(pack.administrativeType || pack.kind))}</dd></div>
      <div><dt>所属大区</dt><dd>${escapeHtml(pack.groupName || "--")}</dd></div>
      <div><dt>源数据</dt><dd>${escapeHtml(sourceState)}</dd></div>
      <div><dt>边界方式</dt><dd>${pack.sourceMode === "direct" ? "来源已独立裁切" : pack.boundariesReady ? "已缓存" : "构建时下载"}</dd></div>
      <div><dt>长期占用</dt><dd>${escapeHtml(standardSize)}</dd></div>
      <div><dt>构建资源</dt><dd>${escapeHtml(`${buildTime} · ${temporarySize}`)}</dd></div>
      <div class="wide"><dt>当前覆盖</dt><dd>${escapeHtml(coverageText)}</dd></div>
      ${pack.partialInstall ? '<div class="wide warning"><dt>历史文件</dt><dd>检测到无 manifest 的旧单省 PMTiles；重新构建后将转为可校验的独立资源。</dd></div>' : ""}
    </dl>`;
  const standardMapRow = job ? `<div class="resource-type-row resource-download-row has-job ${escapeHtml(job.status)}" data-resource-download-job="${escapeHtml(pack.id)}">
      <span class="resource-row-icon"><i data-lucide="map"></i></span>
      <span class="resource-row-copy"><strong>标准地图</strong><span>${job.action === "build" ? "正在获取并构建本地区域包" : "正在更新本地区域包"}</span></span>
      ${renderMaintenanceProgress(job, { id: pack.id, name: resourcePackName(pack), bytes: pack.bytes })}
      <button class="command-button resource-task-action" type="button" data-maintenance-cancel="${escapeHtml(job.id)}" ${job.cancelRequested ? "disabled" : ""} title="取消${escapeHtml(resourcePackName(pack))}任务"><i data-lucide="circle-x"></i><span>${job.cancelRequested ? "停止中" : "取消"}</span></button>
    </div>` : `<div class="resource-type-row">
      <span class="resource-row-icon"><i data-lucide="map"></i></span>
      <span class="resource-row-copy"><strong>标准地图</strong><span>${pack.installed ? `数据 ${formatDate(pack.sourceUpdatedAt)}` : `${buildTime} · ${temporarySize}`}</span></span>
      <span class="resource-row-controls"><span class="resource-row-status ${standardStatus.tone}">${escapeHtml(standardStatus.label)}</span>${pack.installed ? '<button class="icon-button resource-row-action" type="button" data-resource-action="standard-mode" title="使用标准地图模式" aria-label="使用标准地图模式"><i data-lucide="map"></i></button>' : ""}${controls}</span>
    </div>`;
  const rows = [
    standardMapRow,
    `<div class="resource-type-row">
      <span class="resource-row-icon"><i data-lucide="map"></i></span>
      <span class="resource-row-copy"><strong>本地 OSM 原版</strong><span>OpenStreetMap Carto 栅格渲染数据库</span></span>
      <span class="resource-row-status ${osmCartoReady ? "ready" : "partial"}">${osmCartoReady ? "已覆盖" : "待同步"}</span>
    </div>`,
    renderResourceTypeRow(resourceType("road-map"), pack.installed ? { label: "样式就绪", tone: "ready" } : { label: "需先安装地图", tone: "partial" }, pack.installed),
    renderResourceTypeRow(resourceType("contours"), terrainReady ? { label: "本地 HGT 已覆盖", tone: "ready" } : { label: "该区域尚无高程数据", tone: "partial" }, terrainReady, !terrainReady),
    `<div class="resource-type-row">
      <span class="resource-row-icon"><i data-lucide="search"></i></span>
      <span class="resource-row-copy"><strong>搜索与路线</strong><span>共享地址检索和 Valhalla 路线索引</span></span>
      <span class="resource-row-status ${capabilityReady ? "ready" : "partial"}">${capabilityReady ? "已覆盖" : "添加后重建"}</span>
    </div>`,
    renderResourceTypeRow(resourceType("encyclopedia")),
    `<div class="resource-type-row">
      <span class="resource-row-icon"><i data-lucide="cloud-sun"></i></span>
      <span class="resource-row-copy"><strong>天气预报</strong><span>本区域代表城市的 Open-Meteo 七日快照</span></span>
      <span class="resource-row-status ${weatherReady ? "ready" : "partial"}">${weatherReady ? "已覆盖" : "待同步"}</span>
    </div>`,
    `<div class="resource-type-row">
      <span class="resource-row-icon"><i data-lucide="anchor"></i></span>
      <span class="resource-row-copy"><strong>航海地图</strong><span>本区域 OSM 航标与航海参考要素</span></span>
      <span class="resource-row-status ${nauticalReady ? "ready" : "partial"}">${nauticalReady ? "已覆盖" : "待同步"}</span>
    </div>`
  ];
  return `${renderResourceBreadcrumb(resourceRegionPath(`pack:${pack.id}`))}
    <div class="resource-section-title">${escapeHtml(resourcePackName(pack))}<span>${escapeHtml(pack.description || "区域离线资源")}</span></div>
    ${facts}
    ${rows.join("")}
    <p class="resource-command-note">标准地图与丰富详情会随区域安装一起生成；OSM 原版、搜索路线、高程、天气和航海资源按已启用区域统一同步。</p>`;
}

function renderResourceSearchResults(query) {
  const normalized = query.toLocaleLowerCase("zh-CN");
  const packs = state.mapPacks.filter((pack) => `${resourcePackName(pack)} ${pack.name} ${pack.shortName || ""} ${pack.abbreviation || ""} ${pack.countryId || ""} ${(pack.members || []).map((member) => member.name).join(" ")}`.toLocaleLowerCase("zh-CN").includes(normalized));
  const packIds = new Set(packs.map((pack) => pack.id));
  const regions = (state.resourceCatalog?.regions || []).filter((region) => region.id !== "world" && `${resourceRegionName(region)} ${region.name} ${region.sourceName || ""} ${region.isoCode || ""} ${region.id}`.toLocaleLowerCase("zh-CN").includes(normalized)
    && !(region.datasetIds || []).some((id) => packIds.has(id)));
  const types = (state.resourceCatalog?.resourceTypes || []).filter((type) => `${type.name} ${type.description}`.toLocaleLowerCase("zh-CN").includes(normalized));
  if (!regions.length && !packs.length && !types.length) {
    return '<div class="resource-empty"><div><i data-lucide="search-x"></i><strong>没有匹配资源</strong><span>可搜索国家、地区、地图或等高线</span></div></div>';
  }
  return `${renderResourceBreadcrumb([{ id: "world", name: "搜索结果" }])}
    ${regions.length || packs.length ? `<div class="resource-section-title">区域<span>${regions.length + packs.length} 项</span></div>${regions.map(renderResourceRegionRow).join("")}${packs.map(renderResourcePackRow).join("")}` : ""}
    ${types.length ? `<div class="resource-section-title">资源类型<span>${types.length} 项</span></div>${types.map((type) => renderResourceTypeRow(type)).join("")}` : ""}`;
}

function renderResourceDownload() {
  if (state.resourceRegionId.startsWith("pack:")) {
    const pack = state.mapPacks.find((item) => item.id === state.resourceRegionId.slice(5));
    return pack ? renderPackResources(pack) : "";
  }
  const region = resourceRegion(state.resourceRegionId) || resourceRegion("world");
  const children = (region.children || []).map(resourceRegion).filter(Boolean);
  const packs = (region.datasetIds || []).map((id) => state.mapPacks.find((pack) => pack.id === id)).filter(Boolean);
  const globalTypes = region.id === "world" ? state.resourceCatalog.resourceTypes.filter((type) => type.scope === "global") : [];
  const regionalTypes = !children.length && !packs.length ? state.resourceCatalog.resourceTypes.filter((type) => type.scope === "regional") : [];
  const meta = resourceRegionMeta(region);
  const childCount = children.length + packs.length;
  const childRows = childCount
    ? `<div class="resource-section-title">下级区域<span>${childCount} 项</span></div>${children.map(renderResourceRegionRow).join("")}${packs.map(renderResourcePackRow).join("")}`
    : "";
  return `${renderResourceBreadcrumb(resourceRegionPath(region.id))}
    <div class="resource-detail-heading"><span><i data-lucide="${escapeHtml(region.icon || "map")}"></i></span><div><h3>${escapeHtml(resourceRegionName(region))}</h3><p>${escapeHtml(childCount ? `${childCount} 个下级区域 · ${meta.label}` : meta.label)}</p></div></div>
    ${globalTypes.length ? `<div class="resource-section-title">世界资源<span>${globalTypes.length} 类</span></div>${globalTypes.map((type) => renderResourceTypeRow(type)).join("")}` : ""}
    ${regionalTypes.length ? `<div class="resource-section-title">${escapeHtml(resourceRegionName(region))}资源<span>${regionalTypes.length} 类</span></div>${regionalTypes.map((type) => renderResourceTypeRow(type)).join("")}` : ""}
    ${childRows}
    ${!childCount && !globalTypes.length && !regionalTypes.length ? `<div class="resource-section-title">区域状态<span>独立单元</span></div><p class="resource-command-note">${escapeHtml(region.description || region.sourceName || "该区域的离线地图包可独立管理。")}</p>` : ""}`;
}

function renderResourceLocal() {
  const managedBytes = Number(state.resourceInventory?.storage?.managedBytes) || 1;
  const installedMaps = state.mapPacks.filter((pack) => pack.installed).sort((a, b) => Number(b.bytes || 0) - Number(a.bytes || 0));
  const selectedCount = installedMaps.filter((pack) => state.selectedResourcePackIds.has(pack.id)).length;
  const allSelected = installedMaps.length > 0 && selectedCount === installedMaps.length;
  const mapRows = installedMaps.length ? `<section class="resource-local-group" data-resource-group="maps">
    <div class="resource-section-title">已安装地图包<span>${installedMaps.length} 个 · ${installedMaps.filter((pack) => pack.enabled !== false).length} 个启用</span></div>
    <div class="resource-bulk-toolbar">
      <label><input type="checkbox" data-resource-select-all ${allSelected ? "checked" : ""} /><span>${selectedCount ? `已选 ${selectedCount} 项` : "全选"}</span></label>
      <span class="resource-bulk-actions">
        <button class="command-button" type="button" data-resource-bulk="verify" ${selectedCount ? "" : "disabled"}><i data-lucide="shield-check"></i><span>校验</span></button>
        <button class="command-button" type="button" data-resource-bulk="update" ${selectedCount ? "" : "disabled"}><i data-lucide="refresh-cw"></i><span>更新</span></button>
        <button class="command-button danger" type="button" data-resource-bulk="remove" ${selectedCount ? "" : "disabled"}><i data-lucide="trash-2"></i><span>移除</span></button>
      </span>
    </div>
    ${installedMaps.map((pack) => `<div class="resource-local-row resource-pack-row ${pack.enabled === false ? "disabled" : ""}" data-local-pack="${escapeHtml(pack.id)}">
      <label class="resource-pack-select" title="选择${escapeHtml(resourcePackName(pack))}"><input type="checkbox" data-resource-pack-select="${escapeHtml(pack.id)}" ${state.selectedResourcePackIds.has(pack.id) ? "checked" : ""} /></label>
      <span class="resource-row-icon"><i data-lucide="map"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(resourcePackName(pack))}</strong><span>${pack.enabled === false ? "已停用 · 文件保留" : "参与地图渲染"} · 源数据 ${escapeHtml(formatDate(pack.sourceUpdatedAt))} · 构建 ${escapeHtml(formatDate(pack.generatedAt))}</span></span>
      <span class="resource-size-cell"><span>${formatBytes(Number(pack.bytes))}</span><span class="resource-size-meter"><span style="width:${Math.max(1, Math.min(100, Number(pack.bytes) / managedBytes * 100)).toFixed(2)}%"></span></span></span>
      <span class="resource-row-controls resource-menu-wrap">
        <span class="resource-row-status ${pack.enabled === false ? "partial" : "ready"}">${pack.enabled === false ? "停用" : "启用"}</span>
        <button class="icon-button resource-row-action" type="button" data-resource-pack-menu="${escapeHtml(pack.id)}" title="地图包操作" aria-label="打开${escapeHtml(pack.name)}操作菜单"><i data-lucide="more-vertical"></i></button>
        ${state.resourceMenuPackId === pack.id ? `<span class="resource-item-menu">
          <button type="button" data-resource-pack-command="info" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="info"></i><span>信息</span></button>
          <button type="button" data-resource-pack-command="verify" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="shield-check"></i><span>校验</span></button>
          <button type="button" data-resource-pack-command="manifest" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="file-down"></i><span>导出清单</span></button>
          <button type="button" data-resource-pack-command="toggle" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="power"></i><span>${pack.enabled === false ? "启用" : "停用"}</span></button>
          <button type="button" data-resource-pack-command="rebuild" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="hammer"></i><span>重建</span></button>
          ${pack.enabled !== false ? `<button type="button" data-resource-pack-command="open" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="map"></i><span>浏览</span></button>` : ""}
          <button class="danger" type="button" data-resource-pack-command="remove" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="trash-2"></i><span>移除</span></button>
        </span>` : ""}
      </span>
    </div>`).join("")}
  </section>` : "";
  const groups = (state.resourceInventory?.localGroups || []).map((group) => `
    <section class="resource-local-group" data-resource-group="${escapeHtml(group.id)}">
      <div class="resource-section-title">${escapeHtml(group.name)}<span>${formatBytes((group.items || []).reduce((sum, item) => sum + (Number(item.bytes) || 0), 0))}</span></div>
      ${[...(group.items || [])].sort((a, b) => Number(b.bytes || 0) - Number(a.bytes || 0)).map((item) => {
        const hasMeasuredBytes = item.bytes !== null && item.bytes !== undefined && Number.isFinite(Number(item.bytes));
        const bytes = hasMeasuredBytes ? Number(item.bytes) : 0;
        const ratio = hasMeasuredBytes ? Math.max(1, Math.min(100, bytes / managedBytes * 100)) : 0;
        const actions = {
          "standard-maps": "standard-mode", geocoder: "search", routing: "route", terrain: "contours",
          encyclopedia: "encyclopedia", "overview-map": "overview", weather: "weather", "travel-guide": "travel-guide",
          nautical: "nautical", tts: "tts", "personal-database": "personal", "personal-media": "personal",
          "web-assets": "styles", "regenerable-caches": "contours"
        };
        const action = actions[item.id];
        const installable = ["overview-map", "weather", "nautical", "encyclopedia", "travel-guide"].includes(item.id);
        const control = item.status === "ready" && action
          ? `<button class="icon-button resource-row-action" type="button" data-resource-action="${escapeHtml(action)}" title="使用${escapeHtml(item.name)}" aria-label="使用${escapeHtml(item.name)}"><i data-lucide="arrow-right"></i></button>`
          : item.status === "missing" && installable
            ? `<button class="command-button" type="button" data-resource-install="${escapeHtml(item.id)}"><i data-lucide="download"></i><span>安装</span></button>`
            : "";
        return `<div class="resource-local-row">
          <span class="resource-row-icon"><i data-lucide="${escapeHtml(item.icon)}"></i></span>
          <span class="resource-row-copy"><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.subtitle || "本地资源")}</span></span>
          <span class="resource-size-cell"><span>${hasMeasuredBytes ? formatBytes(bytes) : "Docker 卷"}</span><span class="resource-size-meter"><span style="width:${ratio.toFixed(2)}%"></span></span></span>
          <span class="resource-row-controls"><span class="resource-row-status ${item.status === "ready" ? "ready" : ""}">${resourceStatusLabel(item.status)}</span>${control}</span>
        </div>`;
      }).join("")}
    </section>`).join("");
  const caches = state.resourceInventory?.caches || [];
  const cacheRows = `<section class="resource-local-group" data-resource-group="caches">
    <div class="resource-section-title">可再生缓存<span>${formatBytes(caches.reduce((sum, item) => sum + Number(item.bytes || 0), 0))}</span></div>
    ${caches.map((item) => `<div class="resource-local-row resource-cache-row">
      <span class="resource-row-icon"><i data-lucide="database-zap"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.description)} · ${Number(item.files || 0)} 个文件</span></span>
      <span class="resource-size-cell resource-size-static"><span>${formatBytes(Number(item.bytes || 0))}</span></span>
      <button class="command-button" type="button" data-resource-cache-clear="${escapeHtml(item.id)}" ${Number(item.bytes || 0) ? "" : "disabled"}><i data-lucide="eraser"></i><span>清理</span></button>
    </div>`).join("")}
  </section>`;
  const legacy = state.resourceInventory?.legacyPackages || [];
  const legacyRows = legacy.length ? `<section class="resource-local-group" data-resource-group="legacy">
    <div class="resource-section-title">旧区域包<span>${legacy.length} 个待迁移</span></div>
    ${legacy.map((item) => `<div class="resource-local-row resource-legacy-row">
      <span class="resource-row-icon"><i data-lucide="package-open"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.reason)} · 建议：${item.replacementPacks.map((pack) => `${resourcePackName(pack)}${pack.installed ? "（已安装）" : "（待构建）"}`).join("、")}</span></span>
      <span class="resource-size-cell resource-size-static"><span>${formatBytes(Number(item.bytes || 0))}</span></span>
      <span class="resource-row-status ${item.readyToRemove ? "ready" : "partial"}">${item.readyToRemove ? "可移除旧包" : "先安装替代包"}</span>
    </div>`).join("")}
  </section>` : "";
  return mapRows + cacheRows + legacyRows + groups;
}

function maintenanceJobFor(resourceId, action = null) {
  return (state.maintenance?.jobs || []).find((job) => job.resourceId === resourceId && (!action || job.action === action) && ["queued", "running"].includes(job.status)) || null;
}

function latestMaintenanceJobFor(resourceId, action = null) {
  return (state.maintenance?.jobs || []).find((job) => job.resourceId === resourceId && (!action || job.action === action)) || null;
}

function maintenanceStatusText(job) {
  if (!job) return "";
  if (job.cancelRequested) return "停止中";
  return job.status === "running" ? "执行中" : "等待中";
}

function maintenanceElapsedText(job) {
  const source = job.status === "running" ? job.startedAt : job.requestedAt;
  if (!source) return "";
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(source).getTime()) / 1000));
  if (seconds < 60) return `${seconds} 秒`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return `${hours} 小时${minutes ? ` ${minutes} 分` : ""}`;
}

function formatActivityCount(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "--";
  return new Intl.NumberFormat("zh-CN", { notation: number >= 10000 ? "compact" : "standard", maximumFractionDigits: 1 }).format(number);
}

function maintenanceCompactText(job) {
  if (!job) return "";
  const progress = job.progress || {};
  const activity = progress.activity || {};
  if (activity.kind === "download" && Number.isFinite(Number(activity.bytesPerSecond))) {
    return `${formatBytes(Number(activity.bytesPerSecond))}/秒`;
  }
  if (activity.kind === "generation" && Number.isFinite(Number(activity.rate))) {
    return `${formatActivityCount(activity.rate)} 瓦片/秒`;
  }
  if (activity.kind === "processing" && Number.isFinite(Number(activity.rate))) {
    return `${formatActivityCount(activity.rate)} 要素/秒`;
  }
  if (job.status === "queued") {
    return Number(progress.queuePosition) > 0 ? `队列第 ${Number(progress.queuePosition)} 位` : "等待中";
  }
  return progress.stage || maintenanceStatusText(job) || "处理中";
}

function renderMaintenanceActivity(activity) {
  if (!activity) return "";
  if (activity.kind === "download") {
    const speed = Number.isFinite(Number(activity.bytesPerSecond)) ? `${formatBytes(Number(activity.bytesPerSecond))}/秒` : "正在连接";
    const received = Number.isFinite(Number(activity.receivedBytes)) ? formatBytes(Number(activity.receivedBytes)) : "--";
    const total = Number.isFinite(Number(activity.totalBytes)) && Number(activity.totalBytes) > 0 ? formatBytes(Number(activity.totalBytes)) : "未知大小";
    const percent = Number.isFinite(Number(activity.percent)) ? ` · ${Number(activity.percent).toFixed(0)}%` : "";
    return `<span class="resource-task-activity"><strong>${escapeHtml(speed)}</strong><span>已下载 ${escapeHtml(received)} / ${escapeHtml(total)}${percent}</span></span>`;
  }
  if (activity.kind === "generation") {
    const rate = Number.isFinite(Number(activity.rate)) ? `${formatActivityCount(activity.rate)} 瓦片/秒` : "正在生成瓦片";
    const processed = Number.isFinite(Number(activity.processed)) ? `已生成 ${formatActivityCount(activity.processed)} 个` : "";
    const bytes = Number.isFinite(Number(activity.bytes)) ? formatBytes(Number(activity.bytes)) : "";
    return `<span class="resource-task-activity"><strong>${escapeHtml(rate)}</strong><span>${escapeHtml([processed, bytes].filter(Boolean).join(" · "))}</span></span>`;
  }
  if (activity.kind === "processing") {
    const rate = Number.isFinite(Number(activity.rate)) ? `${formatActivityCount(activity.rate)} 要素/秒` : "正在处理要素";
    const processed = Number.isFinite(Number(activity.processed)) ? `已处理 ${formatActivityCount(activity.processed)} 个` : "";
    return `<span class="resource-task-activity"><strong>${escapeHtml(rate)}</strong><span>${escapeHtml(processed)}</span></span>`;
  }
  return "";
}

function renderMaintenanceProgress(job, item) {
  const progress = job.progress || {};
  const percent = progress.percent !== null && progress.percent !== undefined && Number.isFinite(Number(progress.percent))
    ? Math.max(0, Math.min(100, Number(progress.percent)))
    : null;
  const queuedPosition = Number(progress.queuePosition) > 0 ? `队列第 ${Number(progress.queuePosition)} 位` : "等待调度";
  const timing = job.status === "queued" ? queuedPosition : `${maintenanceElapsedText(job) || "刚刚开始"}`;
  const stagePrefix = progress.step && progress.steps ? `第 ${progress.step}/${progress.steps} 阶段 · ` : "";
  const stage = `${stagePrefix}${progress.stage || job.message || maintenanceStatusText(job)}`;
  const progressClass = percent === null ? "indeterminate" : progress.kind || "staged";
  const valueAttributes = percent === null ? "" : `aria-valuenow="${percent.toFixed(0)}" aria-valuemin="0" aria-valuemax="100"`;
  const localSize = Number(item.bytes) > 0 ? `本地 ${formatBytes(Number(item.bytes))}` : "共享索引";
  return `<span class="resource-job-cell">
    <span class="resource-task-heading"><strong>${escapeHtml(maintenanceStatusText(job))}</strong><span>${escapeHtml(localSize)}</span></span>
    <span class="resource-task-stage">${escapeHtml(stage)}</span>
    ${renderMaintenanceActivity(progress.activity)}
    <span class="resource-task-progress ${escapeHtml(progressClass)}" role="progressbar" ${valueAttributes} aria-label="${escapeHtml(`${item.name}：${stage}`)}"><span style="${percent === null ? "" : `width:${percent.toFixed(1)}%`}"></span></span>
    <span class="resource-task-foot"><span>${escapeHtml(timing)}</span><span>${progress.kind === "staged" ? "阶段进度" : progress.kind === "queued" ? "等待前序任务" : "持续处理中"}</span></span>
  </span>`;
}

function renderResourceUpdates() {
  const checks = state.resourceInventory?.updateChecks || [];
  const updates = checks.filter((item) => item.updateAvailable);
  const currentChecks = checks.filter((item) => !item.updateAvailable);
  const regularUpdates = updates.filter((item) => !item.heavy);
  const settings = state.maintenance?.settings || {};
  const workerOnline = Boolean(state.maintenance?.worker?.online);
  const maintenanceJobs = state.maintenance?.jobs || [];
  const activeJobs = maintenanceJobs.filter((job) => ["queued", "running"].includes(job.status));
  const latestByResource = new Map();
  maintenanceJobs.forEach((job) => {
    if (!latestByResource.has(job.resourceId)) latestByResource.set(job.resourceId, job);
  });
  const latestTerminal = maintenanceJobs.find((job) => ["failed", "cancelled", "succeeded"].includes(job.status));
  const runningJobs = activeJobs.filter((job) => job.status === "running");
  const queuedJobs = activeJobs.filter((job) => job.status === "queued");
  const automaticResources = [
    { id: "weather", label: "天气", interval: "每 6 小时" },
    { id: "world-region-catalog", label: "全球区域目录", interval: "每 7 天" },
    { id: "overview-map", label: "全球概览图", interval: "每 30 天" }
  ];
  const automaticOptions = automaticResources.map((resource) => {
    const resourceSettings = settings.resources?.[resource.id] || {};
    return `<label><input type="checkbox" data-resource-auto-resource="${escapeHtml(resource.id)}" ${resourceSettings.enabled ? "checked" : ""} ${settings.enabled ? "" : "disabled"} /><span><strong>${escapeHtml(resource.label)}</strong><small>${escapeHtml(resource.interval)}</small></span></label>`;
  }).join("");
  const jobStrip = activeJobs.length
    ? `<div class="resource-job-strip"><i data-lucide="activity"></i><span><strong>${activeJobs.length} 个维护任务</strong><small>${runningJobs.length} 项执行中 · ${queuedJobs.length} 项等待</small></span></div>`
    : latestTerminal?.status === "failed" ? `<div class="resource-job-strip failed"><i data-lucide="circle-alert"></i><span><strong>最近任务失败</strong><small>${escapeHtml(latestTerminal.label)} · ${escapeHtml(latestTerminal.message || "请查看维护日志")}</small></span></div>`
      : latestTerminal?.status === "cancelled" ? `<div class="resource-job-strip cancelled"><i data-lucide="circle-x"></i><span><strong>最近任务已取消</strong><small>${escapeHtml(latestTerminal.label)} · 可在对应项目中重新加入队列</small></span></div>`
        : latestTerminal ? `<div class="resource-job-strip complete"><i data-lucide="circle-check-big"></i><span><strong>最近完成</strong><small>${escapeHtml(latestTerminal.label)} · ${escapeHtml(new Date(latestTerminal.finishedAt).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Shanghai" }))}</small></span></div>` : "";
  return `<div class="resource-update-toolbar">
      <div class="resource-update-summary"><strong>${updates.length} 项需要处理</strong><span class="resource-worker-state ${workerOnline ? "online" : ""}">${workerOnline ? "本机维护服务运行中" : "本机维护服务未运行"}</span></div>
      <div class="resource-update-actions">
        <label class="resource-auto-toggle"><input type="checkbox" data-resource-auto-toggle ${settings.enabled ? "checked" : ""} /><span>自动更新常规资源</span></label>
        <button class="command-button primary" type="button" data-resource-update-all ${!workerOnline || !regularUpdates.length ? "disabled" : ""}><i data-lucide="refresh-cw"></i><span>${regularUpdates.length ? "全部更新" : "常规资源已最新"}</span></button>
      </div>
    </div>
    <div class="resource-auto-options ${settings.enabled ? "" : "disabled"}" aria-label="自动更新范围">${automaticOptions}</div>
    ${jobStrip}
    ${updates.length
    ? `<div class="resource-section-title">需要处理<span>${updates.length} 项</span></div>${updates.map((item) => renderResourceUpdateRow(item, true)).join("")}`
    : '<div class="resource-empty resource-update-empty"><div><i data-lucide="circle-check-big"></i><strong>已是最新状态</strong><span>地图、目录、天气、知识库与共享索引均已检查</span></div></div>'}
    <div class="resource-section-title">检查结果<span>${currentChecks.length} 项</span></div>
    ${currentChecks.map((item) => renderResourceUpdateRow(item, false)).join("")}`;
}

function renderResourceUpdatesLoading() {
  const activeJobs = (state.maintenance?.jobs || []).filter((job) => ["queued", "running"].includes(job.status));
  const runningJobs = activeJobs.filter((job) => job.status === "running");
  const queuedJobs = activeJobs.filter((job) => job.status === "queued");
  const rows = activeJobs.map((job) => {
    const item = { id: job.resourceId, name: job.label, bytes: 0 };
    return `<div class="resource-update-row has-job ${escapeHtml(job.status)}" data-resource-update="${escapeHtml(job.resourceId)}">
      <span class="resource-row-icon"><i data-lucide="${job.operation === "region-pack" ? "map" : "refresh-cw"}"></i></span>
      <span class="resource-row-copy"><strong>${escapeHtml(job.label)}</strong><span>更新目录同步期间，任务状态独立刷新</span></span>
      ${renderMaintenanceProgress(job, item)}
      <button class="command-button resource-task-action" type="button" data-maintenance-cancel="${escapeHtml(job.id)}" ${job.cancelRequested ? "disabled" : ""} title="取消${escapeHtml(job.label)}"><i data-lucide="circle-x"></i><span>${job.cancelRequested ? "停止中" : "取消"}</span></button>
    </div>`;
  }).join("");
  return `<div class="resource-update-toolbar">
      <div class="resource-update-summary"><strong>正在同步更新目录</strong><span class="resource-worker-state ${state.maintenance?.worker?.online ? "online" : ""}">${state.maintenance?.worker?.online ? "维护任务已独立连接" : "正在连接维护服务"}</span></div>
    </div>
    ${activeJobs.length ? `<div class="resource-job-strip"><i data-lucide="activity"></i><span><strong>${activeJobs.length} 个维护任务</strong><small>${runningJobs.length} 项执行中 · ${queuedJobs.length} 项等待</small></span></div>${rows}` : ""}
    <div class="resource-loading compact"><span>${activeJobs.length ? "本地盘点在后台继续，不影响上方任务速度刷新" : "正在并行获取本地资源与更新检查..."}</span></div>`;
}

function renderResourceUpdateRow(item, actionable) {
  const version = formatDate(item.installedVersion);
  const icons = { "standard-map": "map", "capability-index": "route", catalog: "list-tree", "overview-map": "globe-2", weather: "cloud-sun", nautical: "anchor", encyclopedia: "book-open", "travel-guide": "landmark" };
  const pack = item.type === "standard-map" ? state.mapPacks.find((candidate) => candidate.id === item.id) : null;
  const displayName = pack ? resourcePackName(pack) : item.name;
  const maintenanceAction = item.action || "update";
  const job = maintenanceJobFor(item.id, maintenanceAction);
  const latestJob = latestMaintenanceJobFor(item.id, maintenanceAction);
  const retryableJob = !job && ["failed", "cancelled"].includes(latestJob?.status) ? latestJob : null;
  const rowState = job?.status || retryableJob?.status || "";
  const statusLabels = { upstream: "上游有新数据", rebuild: "需要重建", repair: "需要修复", refresh: "到期刷新", missing: "需要安装", unknown: "未检查", current: "最新", "local-newer": "本地较新" };
  const actionLabel = maintenanceAction === "rebuild" || item.statusKind === "rebuild" || item.heavy ? "重建" : item.statusKind === "missing" ? "安装" : item.statusKind === "repair" ? "修复" : "更新";
  const timeline = [
    ["源数据", item.sourceUpdatedAt || item.availableVersion],
    ["本地构建", item.builtAt || item.installedVersion],
    ["上次检查", item.lastCheckedAt],
    ["下次检查", item.nextCheckAt]
  ];
  const sizeCell = `<span class="resource-size-cell resource-size-static"><span>${Number(item.bytes) > 0 ? formatBytes(Number(item.bytes)) : "共享索引"}</span></span>`;
  const historyCell = retryableJob ? `<span class="resource-job-cell resource-task-result">
    <span class="resource-task-heading"><strong>${retryableJob.status === "cancelled" ? "已取消" : "执行失败"}</strong><span>${Number(item.bytes) > 0 ? `本地 ${formatBytes(Number(item.bytes))}` : "共享索引"}</span></span>
    <span class="resource-task-stage">${escapeHtml(retryableJob.message || (retryableJob.status === "cancelled" ? "任务已取消，可重新加入队列" : "请重试或检查维护日志"))}</span>
  </span>` : "";
  const taskCell = job ? renderMaintenanceProgress(job, item) : historyCell || sizeCell;
  const actionControl = job
    ? `<button class="command-button resource-task-action" type="button" data-maintenance-cancel="${escapeHtml(job.id)}" ${job.cancelRequested ? "disabled" : ""} title="取消${escapeHtml(displayName)}维护任务"><i data-lucide="circle-x"></i><span>${job.cancelRequested ? "停止中" : "取消"}</span></button>`
    : retryableJob && actionable
      ? `<button class="command-button resource-task-action" type="button" data-maintenance-retry="${escapeHtml(retryableJob.id)}" title="重试${escapeHtml(displayName)}维护任务"><i data-lucide="rotate-ccw"></i><span>重试</span></button>`
      : actionable
        ? `<button class="command-button" type="button" data-resource-update-now="${escapeHtml(item.id)}" data-resource-update-action="${escapeHtml(maintenanceAction)}" ${!state.maintenance?.worker?.online ? "disabled" : ""}><i data-lucide="${maintenanceAction === "rebuild" ? "hammer" : item.heavy ? "database-zap" : "refresh-cw"}"></i><span>${actionLabel}</span></button>`
        : `<span class="resource-row-status ${item.updateAvailable ? "update" : "ready"}">${statusLabels[item.statusKind] || "最新"}</span>`;
  return `<div class="resource-update-row ${job || retryableJob ? "has-job" : ""} ${escapeHtml(rowState)}" data-resource-update="${escapeHtml(item.id)}">
    <span class="resource-row-icon"><i data-lucide="${icons[item.type] || "refresh-cw"}"></i></span>
    <span class="resource-row-copy"><strong>${escapeHtml(displayName)}</strong><span>${item.heavy ? "重型维护 · " : ""}${escapeHtml(item.reason || (item.updateAvailable ? "需要处理" : "当前可用"))}</span><span class="resource-time-grid">${timeline.map(([label, value]) => `<small><b>${label}</b>${escapeHtml(value ? formatDate(value) : "待检查")}</small>`).join("")}</span></span>
    ${taskCell}
    ${actionControl}
  </div>`;
}

function renderResourceManager() {
  if (!elements.resourceManagerContent) return;
  document.querySelectorAll("[data-resource-tab]").forEach((button) => {
    const active = button.dataset.resourceTab === state.resourceTab;
    button.classList.toggle("active", active);
    button.setAttribute("aria-selected", String(active));
  });
  const browsingRegions = state.resourceTab === "download";
  elements.resourceRegionBrowser.hidden = !browsingRegions;
  elements.resourceManagerBody.classList.toggle("single-pane", !browsingRegions);
  elements.resourceSearchWrap.hidden = !browsingRegions;
  const storage = state.resourceInventory?.storage;
  const summary = state.resourceInventory?.summary;
  elements.resourceDownloadBadge.textContent = summary?.availablePacks ?? state.mapPacks.filter((pack) => pack.kind === "province" && !pack.installed).length;
  elements.resourceLocalBadge.textContent = storage ? formatBytes(Number(storage.managedBytes)) : "--";
  elements.resourceUpdatesBadge.textContent = summary?.updates ?? ((state.maintenance?.jobs || []).filter((job) => ["queued", "running"].includes(job.status)).length || "--");
  if (storage) {
    const usedPercent = Number(storage.diskTotalBytes) > 0 ? Number(storage.diskUsedBytes) / Number(storage.diskTotalBytes) * 100 : 0;
    const managedPercent = Number(storage.diskTotalBytes) > 0 ? Number(storage.managedBytes) / Number(storage.diskTotalBytes) * 100 : 0;
    elements.resourceDiskFree.textContent = `${formatBytes(Number(storage.diskFreeBytes))} 可用`;
    elements.resourceDiskUsed.textContent = `磁盘已用 ${formatBytes(Number(storage.diskUsedBytes))}`;
    elements.resourceManagedSize.textContent = `TerraSys 占用 ${formatBytes(Number(storage.managedBytes))}`;
    elements.resourceDiskUsedBar.style.width = `${Math.max(0, Math.min(100, usedPercent)).toFixed(1)}%`;
    elements.resourceManagedUsedBar.style.width = `${Math.max(0, Math.min(100, managedPercent)).toFixed(1)}%`;
    elements.resourceStorageTrack.setAttribute("aria-label", `磁盘已用 ${formatBytes(Number(storage.diskUsedBytes))}，其中 TerraSys 占用 ${formatBytes(Number(storage.managedBytes))}`);
  }
  if (!state.resourceInventory && state.resourceTab === "download" && state.resourceCatalog && state.mapPacks.length) {
    elements.resourceManagerContent.innerHTML = renderResourceDownload();
    renderResourceBrowser();
  } else if (!state.resourceInventory && state.resourceTab === "updates" && state.maintenance) {
    elements.resourceManagerContent.innerHTML = renderResourceUpdatesLoading();
  } else if (state.resourceLoading && !state.resourceInventory) {
    elements.resourceManagerContent.innerHTML = '<div class="resource-loading"><span>正在并行盘点本地资源...</span></div>';
  } else if (!state.resourceInventory) {
    elements.resourceManagerContent.innerHTML = '<div class="resource-empty"><div><i data-lucide="circle-alert"></i><strong>资源盘点不可用</strong><span>请检查本地 API 服务</span></div></div>';
  } else if (state.resourceTab === "local") {
    elements.resourceManagerContent.innerHTML = renderResourceLocal();
  } else if (state.resourceTab === "updates") {
    elements.resourceManagerContent.innerHTML = renderResourceUpdates();
  } else {
    elements.resourceManagerContent.innerHTML = renderResourceDownload();
    renderResourceBrowser();
  }
  elements.resourceRefreshButton.classList.toggle("loading", state.resourceLoading);
  elements.resourceRefreshButton.disabled = state.resourceLoading;
  elements.resourceManagerSubtitle.textContent = state.resourceInventory
    ? `离线资源目录 · TerraSys 占用 ${formatBytes(Number(state.resourceInventory.storage.managedBytes))}${state.resourceInventory.cache?.state === "cached" ? " · 后台刷新中" : ""}`
    : "离线资源目录与本地存储";
  icons();
}

async function loadResourceInventory(checkUpstream = false) {
  if (state.resourceLoading) return;
  state.resourceLoading = true;
  renderResourceManager();
  try {
    if (!checkUpstream && !state.resourceInventory) {
      try {
        state.resourceInventory = await api("/resources?cached=true");
        renderResourceManager();
      } catch (error) {
        if (!String(error.message).includes("cache is not ready")) console.warn("Cached resource inventory unavailable", error);
      }
    }
    state.resourceInventory = await api(`/resources${checkUpstream ? "?check_upstream=true" : ""}`);
    if (Array.isArray(state.resourceInventory?.osmCartoPackIds)) {
      state.osmCartoPackIds = state.resourceInventory.osmCartoPackIds;
    }
    renderRegionPacks();
    syncLocalBaseMapForViewport();
  } catch (error) {
    showToast(`资源盘点失败：${error.message}`, true);
  } finally {
    state.resourceLoading = false;
    renderResourceManager();
  }
}

async function loadMaintenanceStatus(silent = false) {
  if (state.maintenanceLoading) return;
  state.maintenanceLoading = true;
  const hadActiveJobs = (state.maintenance?.jobs || []).some((job) => ["queued", "running"].includes(job.status));
  try {
    state.maintenance = await api("/maintenance");
    const hasActiveJobs = (state.maintenance?.jobs || []).some((job) => ["queued", "running"].includes(job.status));
    if (elements.resourceManagerDialog?.open) renderResourceManager();
    if (hadActiveJobs && !hasActiveJobs && state.resourceInventory) loadResourceInventory(true);
  } catch (error) {
    if (!silent) showToast(`维护服务状态获取失败：${error.message}`, true);
  } finally {
    state.maintenanceLoading = false;
  }
}

async function queueMaintenanceJob(resourceId, action = "update") {
  try {
    const job = await api("/maintenance/jobs", {
      method: "POST",
      body: JSON.stringify({ resourceId, action })
    });
    showToast(`${job.label}已加入维护队列`);
    await loadMaintenanceStatus(true);
  } catch (error) {
    showToast(`无法启动维护任务：${error.message}`, true);
  }
}

async function cancelMaintenanceJob(jobId) {
  try {
    await api(`/maintenance/jobs/${encodeURIComponent(jobId)}`, { method: "DELETE" });
    showToast("维护任务已请求取消");
    await loadMaintenanceStatus(true);
  } catch (error) {
    showToast(`无法取消任务：${error.message}`, true);
  }
}

async function retryMaintenanceJob(jobId) {
  try {
    await api(`/maintenance/jobs/${encodeURIComponent(jobId)}/retry`, { method: "POST" });
    showToast("维护任务已重新加入队列");
    await loadMaintenanceStatus(true);
  } catch (error) {
    showToast(`无法重试任务：${error.message}`, true);
  }
}

async function queueRegularUpdates() {
  const updates = (state.resourceInventory?.updateChecks || []).filter((item) => item.updateAvailable && !item.heavy);
  if (!updates.length) return;
  try {
    await Promise.all(updates.map((item) => api("/maintenance/jobs", {
      method: "POST",
      body: JSON.stringify({ resourceId: item.id, action: item.action || "update" })
    })));
    showToast(`${updates.length} 个常规更新已加入队列`);
    await loadMaintenanceStatus(true);
  } catch (error) {
    showToast(`批量更新未能全部加入队列：${error.message}`, true);
  }
}

async function setAutomaticUpdates(enabled, resourceId = null) {
  try {
    const payload = resourceId
      ? { enabled: Boolean(state.maintenance?.settings?.enabled), resources: { [resourceId]: enabled } }
      : { enabled, resources: {} };
    state.maintenance = await api("/maintenance/settings", {
      method: "PUT",
      body: JSON.stringify(payload)
    });
    renderResourceManager();
    showToast(resourceId ? "自动更新范围已保存" : enabled ? "常规资源自动更新已开启" : "常规资源自动更新已关闭");
  } catch (error) {
    showToast(`自动更新设置失败：${error.message}`, true);
    await loadMaintenanceStatus(true);
  }
}

function startMaintenancePolling() {
  clearInterval(state.maintenanceTimer);
  state.maintenanceTimer = setInterval(() => {
    if (elements.resourceManagerDialog?.open) {
      loadMaintenanceStatus(true);
    }
  }, 3000);
}

function stopMaintenancePolling() {
  clearInterval(state.maintenanceTimer);
  state.maintenanceTimer = null;
}

function openResourceManager() {
  state.resourceTab = "download";
  state.resourceRegionId = state.resourceCatalog?.rootRegion || "world";
  state.resourceQuery = "";
  elements.resourceSearchInput.value = "";
  elements.resourceManagerDialog.showModal();
  renderResourceManager();
  startMaintenancePolling();
  loadMaintenanceStatus(true);
  if (!state.resourceInventory) loadResourceInventory();
}

function fitActiveRegion() {
  const bounds = state.viewPackId === "all" ? combinedInstalledBounds() : activeDataset()?.bounds;
  if (!bounds || !state.map) return;
  const leftPadding = document.body.classList.contains("panel-collapsed") ? 72 : 400;
  state.map.fitBounds([[bounds[0], bounds[1]], [bounds[2], bounds[3]]], {
    padding: { top: 80, right: 72, bottom: 72, left: leftPadding },
    duration: 650
  });
}

function activateRegionPack(packId) {
  const pack = state.mapPacks.find((item) => item.id === packId);
  if (!pack?.installed || pack.enabled === false) return;
  localStorage.setItem("terrasys-active-pack", packId);
  if (!state.map?.getSource(packId) || state.mapResourceChanged) {
    window.location.reload();
    return;
  }
  state.activePackId = packId;
  state.viewPackId = packId;
  renderViewSwitcher();
  renderRegionPacks();
  fitActiveRegion();
}

async function refreshMapPackStateFromResources() {
  const packStatus = await api("/map-packs").catch(() => null);
  if (!packStatus?.packs) return;
  state.mapPacks = packStatus.packs;
  state.osmCartoPackIds = packStatus.osmCartoPackIds;
  state.mapResourceChanged = true;
  syncInstalledCatalogDatasets();
  renderViewSwitcher();
  renderRegionPacks();
  if (!syncMapStyleForInstalledPacks()) syncLocalBaseMapForViewport();
  updateCoveragePrompt();
  showToast("地图资源已变化；切换区域时将载入新版本");
}

function locateRegionPack(packId) {
  const pack = state.mapPacks.find((item) => item.id === packId);
  if (!pack || !Array.isArray(pack.bounds) || pack.bounds.length !== 4) return;
  elements.resourceManagerDialog.close();
  state.coveragePromptDismissedId = null;
  state.coveragePromptPinnedId = pack.id;
  state.coveragePromptPinnedUntil = Date.now() + 1500;
  if (pack.installed && pack.enabled !== false) {
    elements.coveragePrompt.hidden = true;
  } else {
    showCoveragePromptForPack(pack);
  }
  state.map.fitBounds([[Number(pack.bounds[0]), Number(pack.bounds[1])], [Number(pack.bounds[2]), Number(pack.bounds[3])]], {
    padding: { top: 92, right: 72, bottom: 132, left: document.body.classList.contains("panel-collapsed") ? 72 : 400 },
    maxZoom: 7,
    duration: 700
  });
}

async function verifyRegionPack(packId) {
  const pack = state.mapPacks.find((item) => item.id === packId);
  if (!pack) return;
  try {
    await queueMaintenanceJob(packId, "verify");
    showToast(`${pack.name}完整性校验已加入后台队列`);
  } catch (error) {
    showToast(error.message, true);
  }
}

async function setRegionPackEnabled(packId, enabled) {
  const pack = state.mapPacks.find((item) => item.id === packId);
  if (!pack) return;
  try {
    await api(`/map-packs/${encodeURIComponent(packId)}/activation`, {
      method: "PUT",
      body: JSON.stringify({ enabled })
    });
    showToast(`${resourcePackName(pack)}已${enabled ? "启用" : "停用"}，正在重载地图`);
    window.setTimeout(() => window.location.reload(), 450);
  } catch (error) {
    showToast(`无法修改地图包状态：${error.message}`, true);
  }
}

async function exportRegionPackManifest(packId) {
  const pack = state.mapPacks.find((item) => item.id === packId);
  try {
    const response = await fetch(`/api/map-packs/${encodeURIComponent(packId)}/manifest`, { cache: "no-store" });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const blob = new Blob([JSON.stringify(await response.json(), null, 2)], { type: "application/json" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `${packId}.manifest.json`;
    link.click();
    URL.revokeObjectURL(link.href);
    showToast(`${resourcePackName(pack || { name: packId })}清单已导出`);
  } catch (error) {
    showToast(`清单导出失败：${error.message}`, true);
  }
}

async function protectedRemovePacks(packIds) {
  const packs = packIds.map((id) => state.mapPacks.find((item) => item.id === id)).filter(Boolean);
  if (!packs.length) return;
  const confirmation = `移除 ${packs.length} 个地图包`;
  const typed = window.prompt(`将移除派生地图文件，但保留 OSM 源数据。请输入“${confirmation}”继续。`);
  if (typed !== confirmation) {
    if (typed !== null) showToast("确认文字不匹配，未执行移除", true);
    return;
  }
  try {
    for (const pack of packs) {
      await api("/maintenance/jobs", {
        method: "POST",
        body: JSON.stringify({ resourceId: pack.id, action: "remove", confirmToken: pack.id })
      });
    }
    state.selectedResourcePackIds.clear();
    showToast(`${packs.length} 个受保护移除任务已加入队列`);
    await loadMaintenanceStatus(true);
  } catch (error) {
    showToast(`移除任务未能全部加入队列：${error.message}`, true);
  }
}

async function runResourceBulkAction(action) {
  const ids = [...state.selectedResourcePackIds];
  if (!ids.length) return;
  if (action === "remove") return protectedRemovePacks(ids);
  if (action === "verify") {
    for (const id of ids) await verifyRegionPack(id);
    showToast(`${ids.length} 个地图包校验任务已加入队列`);
    return;
  }
  if (action === "update") {
    const updateIds = ids.filter((id) => state.resourceInventory?.updateChecks?.some((item) => item.id === id && item.updateAvailable));
    if (!updateIds.length) {
      showToast("所选地图包均为最新状态");
      return;
    }
    for (const id of updateIds) {
      const check = state.resourceInventory?.updateChecks?.find((item) => item.id === id);
      await queueMaintenanceJob(id, check?.action || "update");
    }
    showToast(`${updateIds.length} 个地图包更新已加入队列`);
  }
}

async function clearRegenerableCache(cacheId) {
  const item = state.resourceInventory?.caches?.find((candidate) => candidate.id === cacheId);
  if (!item || !window.confirm(`清理“${item.name}”？这些文件可重新生成。`)) return;
  try {
    await api(`/caches/${encodeURIComponent(cacheId)}?confirm=${encodeURIComponent(cacheId)}`, { method: "DELETE" });
    showToast(`${item.name}已清理`);
    state.resourceInventory = null;
    await loadResourceInventory();
  } catch (error) {
    showToast(`缓存清理失败：${error.message}`, true);
  }
}

function daysAgo(value) {
  const time = new Date(value).getTime();
  if (!Number.isFinite(time)) return null;
  return Math.max(0, Math.floor((Date.now() - time) / 86400000));
}

function categoryLabel(category, subtype = "") {
  const categories = {
    place: "地名", amenity: "公共设施", shop: "商店", tourism: "游览",
    historic: "历史地点", leisure: "休闲", railway: "铁路", public_transport: "公共交通",
    highway: "道路设施", natural: "自然地物", office: "机构", craft: "工坊",
    man_made: "人工地物", reference: "参考地点"
  };
  return [categories[category] || category || "参考地点", subtype].filter(Boolean).join(" · ");
}

function setStatusTone(element, tone = "") {
  element.classList.remove("warning", "error");
  if (tone) element.classList.add(tone);
}

function baseFeatureName(feature) {
  const properties = feature?.properties || {};
  const featureClass = String(properties.class || "").toLowerCase();
  const names = [properties.name_zh, properties["name:zh"], properties.name, properties.name_en];
  if (["country", "state"].includes(featureClass)
      && names.some((name) => ["中华民国", "Taiwan", "Taiwan Province"].includes(name))) {
    return "台湾省";
  }
  return properties.name_zh || properties["name:zh"] || properties.name || properties.name_en || properties["name:latin"] || "";
}

const onlineProviderMeta = {
  osm: { label: "OSM 标准地图", sourceId: "online-osm", layerId: "online-osm-raster", icon: "map" },
  openfreemap: { label: "OpenFreeMap", sourceId: "online-openfreemap", icon: "layers-3" },
  "esri-imagery": { label: "Esri 全球卫星影像", sourceId: "online-esri-imagery", layerId: "online-esri-imagery-raster", icon: "satellite" },
  opentopomap: { label: "OpenTopoMap 全球地形参考", sourceId: "online-opentopomap", layerId: "online-opentopomap-raster", icon: "mountain" }
};

function onlineProvider(provider = state.onlineMapProvider) {
  return onlineProviderMeta[provider] || onlineProviderMeta.osm;
}

function onlineRasterCatalog(provider) {
  if (provider === "esri-imagery") return state.resourceCatalog?.onlineMaps?.esriWorldImagery;
  if (provider === "opentopomap") return state.resourceCatalog?.onlineMaps?.openTopoMap;
  if (provider === "osm") return state.resourceCatalog?.onlineMaps?.osmStandard;
  return null;
}

function baseFeatureCategory(feature) {
  const properties = feature?.properties || {};
  const sourceLayer = feature?.layer?.["source-layer"] || "";
  const labels = {
    poi: "兴趣点", poi_detail: "兴趣点", place: "地名", mountain_peak: "山峰",
    aerodrome_label: "机场", transportation_name: "道路",
    water_name: "水体", waterway: "水系", park: "公园与绿地", building: "建筑"
  };
  const kind = labels[sourceLayer] || "地图地物";
  return [kind, properties.class || properties.category, properties.subclass].filter(Boolean).join(" · ");
}

function selectableBaseFeature(point) {
  const features = state.map.queryRenderedFeatures(point);
  const topLayer = features[0]?.layer?.id || "";
  if (topLayer.startsWith("personal-") || topLayer.startsWith("search-result-") || topLayer.startsWith("measure-")
      || topLayer.startsWith("emergency-") || topLayer.startsWith("active-route-")
      || topLayer.startsWith("weather-") || topLayer.startsWith("nautical-")) {
    return null;
  }
  const allowed = new Set([
    "poi", "poi_detail", "place", "mountain_peak", "aerodrome_label",
    "transportation_name", "water_name", "waterway", "park", "building"
  ]);
  return features.find((feature) => allowed.has(feature.layer?.["source-layer"])) || null;
}

function detailRows(feature, reference = null) {
  const properties = feature?.properties || {};
  const tags = reference?.details?.tags || {};
  const address = properties.addr_full || [
    properties.addr_province, properties.addr_city, properties.addr_district,
    properties.addr_street, properties.addr_housenumber
  ].filter(Boolean).join("") || tags["addr:full"] || [
    tags["addr:province"], tags["addr:city"], tags["addr:district"],
    tags["addr:street"], tags["addr:housenumber"]
  ].filter(Boolean).join("");
  return [
    ["分类", properties.class || properties.category || reference?.category],
    ["类型", properties.subclass || reference?.subtype],
    ["地址", address],
    ["品牌", properties.brand || tags.brand],
    ["运营方", properties.operator || tags.operator],
    ["开放时间", properties.opening_hours || tags.opening_hours],
    ["电话", properties.phone || tags.phone || tags["contact:phone"]],
    ["网站", properties.website || tags.website || tags["contact:website"]],
    ["餐饮类型", properties.cuisine || tags.cuisine],
    ["无障碍", properties.wheelchair || tags.wheelchair],
    ["费用", properties.fee || tags.fee],
    ["通行", properties.access || tags.access],
    ["道路编号", properties.ref || tags.ref],
    ["海拔", tags.ele || properties.ele],
    ["说明", properties.description || tags.description],
    ["附近距离", reference?.details?.distance_m ? `${reference.details.distance_m} m` : ""]
  ].filter(([, value]) => value !== undefined && value !== null && String(value).trim());
}

function renderDetailRows(rows) {
  elements.detailProperties.innerHTML = rows.length
    ? rows.map(([label, value]) => {
      const text = String(value);
      const isLink = label === "网站" && /^https?:\/\//i.test(text);
      const rendered = isLink
        ? `<a href="${escapeHtml(text)}" target="_blank" rel="noreferrer">${escapeHtml(text)}</a>`
        : escapeHtml(text);
      return `<div><dt>${escapeHtml(label)}</dt><dd>${rendered}</dd></div>`;
    }).join("")
    : "<div><dt>信息</dt><dd>当前缩放级别没有更多属性</dd></div>";
}

function setSelectedFeatureMarker(coordinate) {
  const source = state.map.getSource("selected-feature");
  if (!source) return;
  source.setData({
    type: "FeatureCollection",
    features: coordinate ? [{ type: "Feature", properties: {}, geometry: { type: "Point", coordinates: coordinate } }] : []
  });
}

function closeMapFeatureDetail() {
  state.detailRequestId += 1;
  state.selectedMapFeature = null;
  elements.detailPanel.hidden = true;
  document.body.classList.remove("detail-open");
  setSelectedFeatureMarker(null);
}

function setDetailButton(button, icon, label) {
  button.innerHTML = `<i data-lucide="${icon}"></i><span>${escapeHtml(label)}</span>`;
}

function resetDetailContext() {
  elements.detailTagsSection.hidden = true;
  elements.detailTags.innerHTML = "";
  elements.detailKnowledgeSection.hidden = true;
  elements.detailKnowledgeLinks.innerHTML = "";
  elements.detailPersonalSection.hidden = true;
  elements.detailPersonalLinks.innerHTML = "";
}

function renderDetailContext(feature, coordinate, reference = null, sourceLabel = "离线 OSM") {
  resetDetailContext();
  const tags = { ...(feature?.properties || {}), ...(reference?.details?.tags || {}) };
  const coverage = mapCoverageAt(coordinate[0], coordinate[1]);
  const sourceDate = state.serviceStatus?.reference_dataset?.source_updated_at || state.datasetManifest?.source?.updatedAt;
  const coverageText = coverage.installed
    ? `${resourcePackName(coverage.installed)}已安装`
    : coverage.available
      ? `${resourcePackName(coverage.available)}尚未安装`
      : "当前区域暂无独立离线包";
  const offlineReady = Boolean(coverage.installed);
  elements.detailAvailability.dataset.tone = offlineReady ? "ready" : "warning";
  elements.detailAvailability.innerHTML = `<i data-lucide="${offlineReady ? "hard-drive" : "cloud"}"></i><span>${escapeHtml(`${sourceLabel} · ${coverageText}`)}</span>`;
  elements.detailSourceText.textContent = [sourceLabel, sourceDate ? `数据 ${formatDate(sourceDate)}` : "", coverageText].filter(Boolean).join(" · ");

  const tagEntries = Object.entries(tags).filter(([, value]) => value !== null && value !== undefined && String(value).trim()).sort(([left], [right]) => left.localeCompare(right));
  if (tagEntries.length) {
    elements.detailTagsSection.hidden = false;
    elements.detailTags.innerHTML = tagEntries.map(([key, value]) => `<div><code>${escapeHtml(key)}</code><span>${escapeHtml(String(value))}</span></div>`).join("");
  }

  const knowledgeLinks = [];
  const wikipedia = String(tags.wikipedia || "").trim();
  const wikidata = String(tags.wikidata || "").trim();
  const title = baseFeatureName(feature) || elements.detailTitle.textContent;
  knowledgeLinks.push(`<a href="/wiki/search?pattern=${encodeURIComponent(title)}" target="_blank" rel="noreferrer"><i data-lucide="book-open"></i><span>离线百科搜索</span></a>`);
  if (wikipedia) {
    const [language, ...pageParts] = wikipedia.includes(":") ? wikipedia.split(":") : ["zh", wikipedia];
    knowledgeLinks.push(`<a href="https://${encodeURIComponent(language)}.wikipedia.org/wiki/${encodeURIComponent(pageParts.join(":"))}" target="_blank" rel="noreferrer"><i data-lucide="globe-2"></i><span>Wikipedia</span></a>`);
  }
  if (/^Q\d+$/i.test(wikidata)) knowledgeLinks.push(`<a href="https://www.wikidata.org/wiki/${encodeURIComponent(wikidata)}" target="_blank" rel="noreferrer"><i data-lucide="database"></i><span>Wikidata</span></a>`);
  elements.detailKnowledgeSection.hidden = knowledgeLinks.length === 0;
  elements.detailKnowledgeLinks.innerHTML = knowledgeLinks.join("");

  const relatedTracks = relatedTracksForPlace(coordinate);
  const relatedPlaces = state.places.features
    .map((item) => ({ feature: item, distance: haversine(coordinate, item.geometry.coordinates) }))
    .filter((item) => item.distance <= 2000)
    .sort((left, right) => left.distance - right.distance)
    .slice(0, 3);
  const personalLinks = [
    ...relatedPlaces.map((item) => `<button type="button" data-detail-personal="place" data-detail-id="${escapeHtml(item.feature.properties.id)}"><i data-lucide="map-pin"></i><span>${escapeHtml(item.feature.properties.name)} · ${item.distance.toFixed(0)} m</span></button>`),
    ...relatedTracks.map((item) => `<button type="button" data-detail-personal="track" data-detail-id="${escapeHtml(item.feature.properties.id)}"><i data-lucide="route"></i><span>${escapeHtml(item.feature.properties.name)} · ${(item.distance / 1000).toFixed(1)} km</span></button>`)
  ];
  elements.detailPersonalSection.hidden = personalLinks.length === 0;
  elements.detailPersonalLinks.innerHTML = personalLinks.join("");
  icons();
}

async function showMapFeatureDetail(feature, coordinate, options = {}) {
  closeRoutePanel();
  const requestId = ++state.detailRequestId;
  const name = baseFeatureName(feature);
  const category = baseFeatureCategory(feature);
  state.selectedMapFeature = { kind: "base", feature, coordinate, reference: options.reference || null, nearbyResults: [], searchResult: options.searchResult || null };
  elements.detailEyebrow.textContent = options.eyebrow || "本地矢量底图";
  elements.detailTitle.textContent = name || category.split(" · ")[0];
  elements.detailSubtitle.textContent = `${category} · ${coordinate[0].toFixed(5)}, ${coordinate[1].toFixed(5)}`;
  renderDetailRows(detailRows(feature, options.reference || null));
  elements.detailMediaSection.hidden = true;
  elements.detailMediaGrid.innerHTML = "";
  renderDetailContext(feature, coordinate, options.reference || null, options.sourceLabel || "离线 OSM");
  elements.detailDeleteButton.hidden = true;
  elements.detailNearbyButton.disabled = false;
  setDetailButton(elements.detailNearbyButton, "radar", "附近地点");
  setDetailButton(elements.detailSaveButton, "bookmark-plus", "保存为个人点位");
  elements.detailPanel.hidden = false;
  document.body.classList.add("detail-open");
  setSelectedFeatureMarker(coordinate);
  icons();

  const radius = state.map.getZoom() >= 14 ? 350 : state.map.getZoom() >= 11 ? 1500 : 10_000;
  try {
    const nearby = await api(`/reference/nearby?longitude=${coordinate[0]}&latitude=${coordinate[1]}&radius_m=${radius}&limit=30`);
    if (requestId !== state.detailRequestId || !state.selectedMapFeature) return;
    const normalizedName = name.trim().toLocaleLowerCase("zh-CN");
    const reference = (normalizedName
      ? nearby.results.find((item) => item.name.trim().toLocaleLowerCase("zh-CN") === normalizedName)
      : null) || options.reference || null;
    state.selectedMapFeature.reference = reference || null;
    state.selectedMapFeature.nearbyResults = nearby.results;
    if (reference) {
      elements.detailEyebrow.textContent = "OSM 参考索引匹配";
      renderDetailRows(detailRows(feature, reference));
      renderDetailContext(feature, coordinate, reference, options.sourceLabel || "离线 OSM");
    }
  } catch {
    // Vector-tile details remain usable even if enrichment is temporarily unavailable.
  }
}

function relatedTracksForPlace(coordinate) {
  return state.tracks.features
    .map((feature) => ({ feature, distance: haversine(coordinate, featureCenter(feature)) }))
    .filter((item) => item.distance <= 50_000)
    .sort((left, right) => left.distance - right.distance)
    .slice(0, 3);
}

async function loadPersonalMedia(targetKind, targetId, requestId = state.detailRequestId) {
  try {
    const parameter = targetKind === "track" ? "track_id" : "place_id";
    const media = await api(`/media?${parameter}=${encodeURIComponent(targetId)}`);
    if (requestId !== state.detailRequestId || state.selectedMapFeature?.feature?.properties?.id !== targetId) return;
    elements.detailMediaGrid.innerHTML = media.length
      ? media.map((item) => `
        <figure class="detail-media-item">
          <a href="${escapeHtml(item.content_url)}" target="_blank" rel="noreferrer" title="${escapeHtml(item.original_name)}">
            <img src="${escapeHtml(item.content_url)}" alt="${escapeHtml(item.original_name)}" loading="lazy" />
          </a>
          <button type="button" data-media-delete="${escapeHtml(item.id)}" title="删除照片" aria-label="删除照片"><i data-lucide="trash-2"></i></button>
        </figure>`).join("")
      : '<div class="detail-media-empty">还没有照片</div>';
    icons();
  } catch (error) {
    elements.detailMediaGrid.innerHTML = `<div class="detail-media-empty">${escapeHtml(error.message)}</div>`;
  }
}

async function showPersonalPlaceDetail(feature) {
  closeRoutePanel();
  const requestId = ++state.detailRequestId;
  const props = feature.properties || {};
  const coordinate = feature.geometry.coordinates;
  const collections = featureCollections(props).map((collection) => collection.name);
  const relatedTracks = relatedTracksForPlace(coordinate);
  state.selectedMapFeature = { kind: "personal", feature, coordinate, relatedTracks };
  resetDetailContext();
  elements.detailEyebrow.textContent = "我的个人点位";
  elements.detailTitle.textContent = props.name || "未命名点位";
  elements.detailSubtitle.textContent = `${props.province || "未填写地区"} · ${coordinate[0].toFixed(5)}, ${coordinate[1].toFixed(5)}`;
  renderDetailRows([
    ["分类", props.category || "未分类"],
    ["集合", collections.join("、")],
    ["标签", featureTags(props).join("、")],
    ["评分", `${props.rating || 0} / 5`],
    ["备注", props.note],
    ["附近轨迹", relatedTracks.map((item) => `${item.feature.properties?.name} (${item.distance >= 1000 ? `${(item.distance / 1000).toFixed(1)} km` : `${item.distance.toFixed(0)} m`})`).join("、")],
    ["更新时间", formatDate(props.updated_at)]
  ].filter(([, value]) => value !== undefined && value !== null && String(value).trim()));
  elements.detailMediaSection.hidden = false;
  elements.detailMediaGrid.innerHTML = '<div class="detail-media-empty">正在读取照片…</div>';
  elements.detailSourceText.textContent = "个人 PostGIS 数据库";
  elements.detailAvailability.dataset.tone = "personal";
  elements.detailAvailability.innerHTML = '<i data-lucide="user-round"></i><span>个人点位 · 完全保存在本地</span>';
  elements.detailDeleteButton.hidden = false;
  elements.detailNearbyButton.disabled = relatedTracks.length === 0;
  setDetailButton(elements.detailNearbyButton, "route", "轨迹");
  setDetailButton(elements.detailSaveButton, "pencil", "编辑");
  elements.detailPanel.hidden = false;
  document.body.classList.add("detail-open");
  setSelectedFeatureMarker(coordinate);
  icons();
  await loadPersonalMedia("place", props.id, requestId);
}

async function showPersonalTrackDetail(feature) {
  closeRoutePanel();
  const canonical = state.tracks.features.find((item) => item.properties?.id === feature.properties?.id) || feature;
  const requestId = ++state.detailRequestId;
  const props = canonical.properties || {};
  const coordinate = featureCenter(canonical);
  state.selectedMapFeature = { kind: "track", feature: canonical, coordinate };
  resetDetailContext();
  elements.detailEyebrow.textContent = "我的个人轨迹";
  elements.detailTitle.textContent = props.name || "未命名轨迹";
  elements.detailSubtitle.textContent = `${props.activity || "other"} · ${(Number(props.distance_m || 0) / 1000).toFixed(2)} km`;
  renderDetailRows([
    ["活动", props.activity || "other"],
    ["距离", `${(Number(props.distance_m || 0) / 1000).toFixed(2)} km`],
    ["标签", featureTags(props).join("、")],
    ["备注", props.note],
    ["来源", props.source],
    ["更新时间", formatDate(props.updated_at)]
  ].filter(([, value]) => value !== undefined && value !== null && String(value).trim()));
  elements.detailMediaSection.hidden = false;
  elements.detailMediaGrid.innerHTML = '<div class="detail-media-empty">正在读取照片…</div>';
  elements.detailSourceText.textContent = "个人 PostGIS 轨迹数据库";
  elements.detailAvailability.dataset.tone = "personal";
  elements.detailAvailability.innerHTML = '<i data-lucide="route"></i><span>轨迹记录 · 完全保存在本地</span>';
  elements.detailDeleteButton.hidden = false;
  elements.detailNearbyButton.disabled = false;
  setDetailButton(elements.detailNearbyButton, "download", "GPX");
  setDetailButton(elements.detailSaveButton, "pencil", "编辑");
  elements.detailPanel.hidden = false;
  document.body.classList.add("detail-open");
  setSelectedFeatureMarker(coordinate);
  icons();
  await loadPersonalMedia("track", props.id, requestId);
}

async function showNearbyResults() {
  const selected = state.selectedMapFeature;
  if (!selected) return;
  if (selected.kind === "personal") {
    const first = selected.relatedTracks?.[0];
    if (first) showListFeature("track", first.feature.properties.id);
    return;
  }
  if (selected.kind === "track") {
    window.open(`/api/tracks/${encodeURIComponent(selected.feature.properties.id)}.gpx`, "_blank", "noopener");
    return;
  }
  try {
    const [longitude, latitude] = selected.coordinate;
    const nearby = await api(`/reference/nearby?longitude=${longitude}&latitude=${latitude}&radius_m=2000&limit=50`);
    state.searchQuery = "";
    state.resultMode = "nearby";
    state.resultLabel = `${elements.detailTitle.textContent}附近`;
    state.searchResults = nearby.results || [];
    elements.searchInput.value = "";
    elements.searchSummary.textContent = `${state.resultLabel} · ${state.searchResults.length} 个地点`;
    updateSearchMap();
    renderPersonalList();
    document.querySelector('[data-tab="personal"]').click();
    showToast(`找到 ${state.searchResults.length} 个附近地点`);
  } catch (error) {
    showToast(error.message, true);
  }
}

function saveSelectedMapFeature() {
  const selected = state.selectedMapFeature;
  if (!selected) return;
  if (selected.kind === "personal") {
    openPlaceDialog(selected.feature);
    return;
  }
  if (selected.kind === "track") {
    openTrackDialog(selected.feature);
    return;
  }
  const feature = selected.feature;
  const reference = selected.reference;
  const properties = feature.properties || {};
  const tags = reference?.details?.tags || {};
  const sourceLayer = feature.layer?.["source-layer"] || "map";
  openPlaceDialog({
    type: "Feature",
    properties: {
      name: baseFeatureName(feature) || baseFeatureCategory(feature).split(" · ")[0],
      category: "reference",
      province: tags["addr:province"] || "",
      tags: [sourceLayer, properties.class, properties.subclass].filter(Boolean),
      note: `来源：OpenStreetMap 本地底图（${baseFeatureCategory(feature)}）`
    },
    geometry: { type: "Point", coordinates: selected.coordinate }
  }, { copyAsNew: true, collectionIds: ["default-favorites"] });
}

async function deleteSelectedPersonalRecord() {
  const selected = state.selectedMapFeature;
  if (!selected || !["personal", "track"].includes(selected.kind)) return;
  const props = selected.feature.properties || {};
  const type = selected.kind === "track" ? "轨迹" : "点位";
  if (!window.confirm(`删除${type}“${props.name}”？关联照片也会一并删除。`)) return;
  try {
    const path = selected.kind === "track" ? "tracks" : "places";
    await api(`/${path}/${encodeURIComponent(props.id)}`, { method: "DELETE" });
    closeMapFeatureDetail();
    await refreshData();
    showToast(`${type}已删除`);
  } catch (error) {
    showToast(error.message, true);
  }
}

async function handleDetailMediaClick(event) {
  const button = event.target.closest("[data-media-delete]");
  if (!button || !["personal", "track"].includes(state.selectedMapFeature?.kind)) return;
  if (!window.confirm("删除这张照片？")) return;
  try {
    await api(`/media/${encodeURIComponent(button.dataset.mediaDelete)}`, { method: "DELETE" });
    const selected = state.selectedMapFeature;
    await loadPersonalMedia(selected.kind, selected.feature.properties.id);
    await checkServices();
    showToast("照片已删除");
  } catch (error) {
    showToast(error.message, true);
  }
}

async function assetSize(id, url) {
  try {
    const response = await fetch(url, { method: "HEAD", cache: "no-store" });
    const length = Number(response.headers.get("content-length"));
    elements[id].textContent = formatBytes(length);
  } catch {
    elements[id].textContent = "--";
  }
}

function featureTags(properties) {
  const tags = properties?.tags;
  if (Array.isArray(tags)) return tags;
  if (!tags) return [];
  if (typeof tags === "string") {
    try {
      const parsed = JSON.parse(tags);
      if (Array.isArray(parsed)) return parsed;
    } catch {
      return tags.split(",").map((item) => item.trim()).filter(Boolean);
    }
  }
  return [];
}

function featureCollections(properties) {
  const collections = properties?.collections;
  if (Array.isArray(collections)) return collections;
  if (typeof collections === "string") {
    try {
      const parsed = JSON.parse(collections);
      if (Array.isArray(parsed)) return parsed;
    } catch {
      return [];
    }
  }
  return [];
}

function renderCollectionControls() {
  const current = state.collections.some((collection) => collection.id === state.collectionFilter)
    ? state.collectionFilter
    : "all";
  elements.collectionFilter.innerHTML = [
    '<option value="all">全部个人记录</option>',
    ...state.collections.map((collection) =>
      `<option value="${escapeHtml(collection.id)}">${escapeHtml(collection.name)} (${Number(collection.place_count || 0)})</option>`)
  ].join("");
  elements.collectionFilter.value = current;
  state.collectionFilter = current;

  elements.collectionManagerList.innerHTML = state.collections.map((collection) => `
    <div class="collection-manager-item" data-collection-id="${escapeHtml(collection.id)}">
      <span class="collection-swatch" style="background:${escapeHtml(collection.color)}"></span>
      <span class="collection-manager-copy"><strong>${escapeHtml(collection.name)}</strong><span>${Number(collection.place_count || 0)} 个点位 · ${escapeHtml(collection.note || "暂无说明")}</span></span>
      <button class="icon-button compact" type="button" data-collection-edit title="编辑集合" aria-label="编辑 ${escapeHtml(collection.name)}"><i data-lucide="pencil"></i></button>
      ${collection.id.startsWith("default-") ? '<span class="collection-system-label">内置</span>' : `<button class="icon-button compact" type="button" data-collection-delete title="删除集合" aria-label="删除 ${escapeHtml(collection.name)}"><i data-lucide="trash-2"></i></button>`}
    </div>`).join("");
  icons();
}

function renderPlaceCollectionChoices(selectedIds = []) {
  const selected = new Set(selectedIds);
  elements.placeCollectionChoices.innerHTML = state.collections.length
    ? state.collections.map((collection) => `
      <label title="${escapeHtml(collection.note || collection.name)}">
        <input type="checkbox" value="${escapeHtml(collection.id)}" ${selected.has(collection.id) ? "checked" : ""} />
        <span>${escapeHtml(collection.name)}</span>
      </label>`).join("")
    : "<span>尚未建立集合</span>";
}

function resetCollectionForm() {
  elements.collectionId.value = "";
  elements.collectionName.value = "";
  elements.collectionColor.value = "#267352";
  elements.collectionNote.value = "";
  elements.collectionName.focus();
}

function updateListCaption() {
  if (state.searchQuery) {
    elements.searchSummary.textContent = `“${state.searchQuery}” · ${state.searchResults.length} 个结果`;
    return;
  }
  if (state.resultMode) {
    elements.searchSummary.textContent = `${state.resultLabel} · ${state.searchResults.length} 个地点`;
    return;
  }
  const collection = state.collections.find((item) => item.id === state.collectionFilter);
  elements.searchSummary.textContent = collection ? collection.name : "最近更新";
}

function setMode(mode) {
  state.mode = mode;
  state.map.getCanvas().style.cursor = mode ? "crosshair" : "";
  elements.addPlaceButton.classList.toggle("primary", mode !== "add-place");
  elements.measureButton.classList.toggle("active", mode === "measure-distance");
  elements.routeButton.classList.toggle("primary", mode === "route-start" || mode === "route-end");
  document.querySelectorAll("[data-route-point]").forEach((button) => {
    button.classList.toggle("active", button.dataset.routePoint === (mode === "route-start" ? "0" : mode === "route-end" ? "1" : ""));
  });
  if (!mode) {
    elements.modeBanner.hidden = true;
    return;
  }
  const messages = {
    "add-place": "在地图上点击要保存的位置",
    "measure-distance": "依次点击地图测量距离，再次点击测距按钮清空",
    "measure-area": "依次点击至少三个边界点测量面积",
    "route-start": "在地图上选择路线起点",
    "route-end": "在地图上选择路线终点"
  };
  elements.modeText.textContent = messages[mode] || "";
  elements.modeBanner.hidden = false;
}

function routePointLabel(location) {
  if (!location) return "未设置";
  return location.name || `${location.longitude.toFixed(5)}, ${location.latitude.toFixed(5)}`;
}

async function routeToSelectedFeature() {
  const selected = state.selectedMapFeature;
  if (!selected?.coordinate) return;
  const coordinate = [...selected.coordinate];
  const name = elements.detailTitle.textContent.trim();
  closeMapFeatureDetail();
  openRoutePanel();
  await setRouteLocation(1, coordinate, name);
  if (!state.route.locations[0]) setMode("route-start");
}

function routeRecentLocations() {
  try {
    const parsed = JSON.parse(localStorage.getItem("terrasys-route-recents") || "[]");
    return Array.isArray(parsed)
      ? parsed.filter((item) => Number.isFinite(item?.longitude) && Number.isFinite(item?.latitude)).slice(0, 6)
      : [];
  } catch {
    return [];
  }
}

function rememberRouteLocation(location) {
  if (!location) return;
  const recent = routeRecentLocations().filter((item) => Math.abs(item.longitude - location.longitude) > 1e-5 || Math.abs(item.latitude - location.latitude) > 1e-5);
  recent.unshift({ longitude: location.longitude, latitude: location.latitude, name: routePointLabel(location) });
  localStorage.setItem("terrasys-route-recents", JSON.stringify(recent.slice(0, 6)));
}

function updateRouteCoverageStatus() {
  if (!elements.routeCoverageStatus) return;
  const routing = state.capabilities?.services?.routing;
  const locations = state.route.locations.filter(Boolean);
  const packs = locations.map((location) => mapCoverageAt(location.longitude, location.latitude).installed);
  const allCovered = locations.length > 0 && packs.every(Boolean);
  const missingIndexedPack = packs.find((pack) => pack && routing?.missingPackIds?.includes(pack.id));
  let label = "本次使用 Valhalla 离线路由引擎";
  let tone = "ready";
  if (!routing?.available) {
    label = "离线路由索引尚未就绪";
    tone = "warning";
  } else if (missingIndexedPack) {
    label = `${resourcePackName(missingIndexedPack)}尚未进入路由索引`;
    tone = "warning";
  } else if (locations.length && !allCovered) {
    label = "端点超出已安装区域，离线路线可能不可用";
    tone = "warning";
  } else if (locations.length === 2) {
    label = `离线路由覆盖：${[...new Set(packs.map(resourcePackName))].join("、")}`;
  }
  elements.routeEngineMode.textContent = "离线引擎";
  elements.routeCoverageStatus.dataset.tone = tone;
  elements.routeCoverageStatus.innerHTML = `<i data-lucide="${tone === "ready" ? "shield-check" : "triangle-alert"}"></i><span>${escapeHtml(label)}</span>`;
  const recent = routeRecentLocations();
  elements.routeRecentSection.hidden = recent.length === 0;
  elements.routeRecentList.innerHTML = recent.map((item, index) => `<button type="button" data-route-recent="${index}"><i data-lucide="history"></i><span>${escapeHtml(item.name)}</span></button>`).join("");
  icons();
}

function updateRoutePanel() {
  [elements.routeStartLabel, elements.routeEndLabel].forEach((input, index) => {
    if (document.activeElement !== input) input.value = state.route.drafts[index] ?? (state.route.locations[index] ? routePointLabel(state.route.locations[index]) : "");
  });
  document.querySelectorAll("[data-route-costing]").forEach((button) => {
    button.classList.toggle("active", button.dataset.routeCosting === state.route.costing);
  });
  updateRouteCoverageStatus();
}

function updateRouteSource() {
  const source = state.map.getSource("active-route");
  if (!source) return;
  const features = [];
  if (state.route.result?.geometry) {
    features.push({ type: "Feature", properties: {}, geometry: state.route.result.geometry });
  }
  state.route.locations.forEach((location, index) => {
    if (!location) return;
    features.push({
      type: "Feature",
      properties: { point_type: index === 0 ? "start" : "end" },
      geometry: { type: "Point", coordinates: [location.longitude, location.latitude] }
    });
  });
  source.setData({ type: "FeatureCollection", features });
}

function openRoutePanel() {
  closeMapFeatureDetail();
  elements.routePanel.hidden = false;
  document.body.classList.add("route-open");
  elements.routeButton.classList.add("active");
  updateRoutePanel();
  if (!state.route.locations[0]) setMode("route-start");
  else if (!state.route.locations[1]) setMode("route-end");
}

function closeRoutePanel() {
  state.route.locationSearchIds = state.route.locationSearchIds.map((id) => id + 1);
  if (state.route.controller) invalidateRoute();
  elements.routePanel.hidden = true;
  document.body.classList.remove("route-open");
  elements.routeButton.classList.remove("active");
  if (state.mode === "route-start" || state.mode === "route-end") setMode(null);
}

function invalidateRoute() {
  state.route.requestId += 1;
  state.route.controller?.abort();
  state.route.controller = null;
  state.route.result = null;
  state.route.resultInput = null;
  elements.routeResult.hidden = true;
  elements.routeEmpty.hidden = false;
  elements.routeEmpty.innerHTML = '<i data-lucide="navigation"></i><span>在地图上设置起点和终点</span>';
  elements.routeSaveButton.disabled = true;
  elements.routeSpeakButton.disabled = true;
  updateRouteSource();
  return state.route.requestId;
}

function clearRoute() {
  state.route.locations = [null, null];
  state.route.drafts = [null, null];
  state.route.locationSearchIds = state.route.locationSearchIds.map((id) => id + 1);
  invalidateRoute();
  updateRoutePanel();
  setMode("route-start");
  icons();
}

async function setRouteLocation(index, coordinate, name = "") {
  const location = { longitude: coordinate[0], latitude: coordinate[1], name };
  state.route.locations[index] = location;
  state.route.drafts[index] = null;
  state.route.locationSearchIds[index] += 1;
  invalidateRoute();
  updateRoutePanel();
  if (index === 0 && !state.route.locations[1]) setMode("route-end");
  else if (state.route.locations.every(Boolean)) setMode(null);

  // Address lookup only enriches the label; route geometry can be calculated immediately.
  const routePromise = state.route.locations.every(Boolean) ? runRoute() : Promise.resolve();
  if (!location.name) {
    try {
      const result = await api(`/reverse?longitude=${coordinate[0]}&latitude=${coordinate[1]}`);
      if (state.route.locations[index] !== location) return;
      location.name = result.name || result.subtitle || "";
      updateRoutePanel();
    } catch {
      // Coordinates remain a valid offline route endpoint while the address index is rebuilding.
    }
  }
  if (state.route.locations[index] !== location) return;
  rememberRouteLocation(location);
  updateRouteCoverageStatus();
  await routePromise;
}

async function searchRouteLocation(index) {
  const input = index === 0 ? elements.routeStartLabel : elements.routeEndLabel;
  const query = input.value.trim();
  if (!query) {
    setMode(index === 0 ? "route-start" : "route-end");
    return;
  }
  const searchId = ++state.route.locationSearchIds[index];
  invalidateRoute();
  try {
    const encoded = encodeURIComponent(query);
    const responses = await Promise.allSettled([
      api(`/geocode?q=${encoded}&limit=8`),
      api(`/search?q=${encoded}&limit=12`)
    ]);
    if (searchId !== state.route.locationSearchIds[index] || input.value.trim() !== query) return;
    const candidates = responses.flatMap((response) => response.status === "fulfilled" ? (response.value.results || []) : [])
      .filter((item) => Number.isFinite(Number(item.longitude)) && Number.isFinite(Number(item.latitude)));
    const normalizedQuery = query.toLocaleLowerCase("zh-CN").replace(/\s+/g, "");
    const center = state.map.getCenter();
    const score = (item) => {
      const name = String(item.name || "").toLocaleLowerCase("zh-CN").replace(/\s+/g, "");
      const exactPenalty = name === normalizedQuery ? -100 : name.startsWith(normalizedQuery) ? -60 : name.includes(normalizedQuery) ? -25 : 0;
      const sourcePenalty = ["personal_place", "personal_track"].includes(item.kind) ? -50 : item.kind === "geocoder" ? -25 : 0;
      const longitude = Number(item.longitude);
      const latitude = Number(item.latitude);
      const distance = Math.hypot((longitude - center.lng) * Math.cos(center.lat * Math.PI / 180), latitude - center.lat);
      return exactPenalty + sourcePenalty + distance;
    };
    const match = candidates.sort((left, right) => score(left) - score(right))[0];
    if (!match) throw new Error("没有找到可用于路线的地点");
    const routePromise = setRouteLocation(index, [Number(match.longitude), Number(match.latitude)], match.name || query);
    const selectedLocation = state.route.locations[index];
    await routePromise;
    if (state.route.locations[index] !== selectedLocation) return;
    state.map.easeTo({ center: [Number(match.longitude), Number(match.latitude)], zoom: Math.max(state.map.getZoom(), 12), duration: 500 });
  } catch (error) {
    if (searchId !== state.route.locationSearchIds[index]) return;
    showToast(error.message, true);
  }
}

async function swapRouteLocations() {
  state.route.locations = [state.route.locations[1], state.route.locations[0]];
  state.route.drafts = [state.route.drafts[1], state.route.drafts[0]];
  state.route.locationSearchIds = state.route.locationSearchIds.map((id) => id + 1);
  invalidateRoute();
  updateRoutePanel();
  if (state.route.locations.every(Boolean)) await runRoute();
}

async function setRouteCosting(costing) {
  state.route.costing = costing;
  invalidateRoute();
  updateRoutePanel();
  if (state.route.locations.every(Boolean)) await runRoute();
}

function editRouteLocation(index) {
  state.route.locations[index] = null;
  state.route.drafts[index] = (index === 0 ? elements.routeStartLabel : elements.routeEndLabel).value;
  state.route.locationSearchIds[index] += 1;
  invalidateRoute();
  updateRouteCoverageStatus();
}

function useCurrentRouteLocation() {
  if (!navigator.geolocation) {
    showToast("当前浏览器没有定位能力", true);
    return;
  }
  navigator.geolocation.getCurrentPosition(
    (position) => setRouteLocation(0, [position.coords.longitude, position.coords.latitude], "当前位置"),
    () => showToast("无法读取当前位置，请使用搜索或地图选择", true),
    { enableHighAccuracy: true, timeout: 10000, maximumAge: 60000 }
  );
}

function formatRouteDuration(seconds) {
  const minutes = Math.max(1, Math.round(Number(seconds || 0) / 60));
  if (minutes < 60) return `${minutes} 分钟`;
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return remainder ? `${hours} 小时 ${remainder} 分钟` : `${hours} 小时`;
}

function drawRouteProfile(profile) {
  const values = (profile || []).filter((item) => Number.isFinite(Number(item.elevation_m)));
  elements.routeProfileSection.hidden = values.length < 2;
  if (values.length < 2) return;
  const canvas = elements.routeProfileCanvas;
  const context = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 8;
  const elevations = values.map((item) => Number(item.elevation_m));
  const minimum = Math.min(...elevations);
  const maximum = Math.max(...elevations);
  const span = Math.max(10, maximum - minimum);
  const maxDistance = Math.max(1, Number(values.at(-1).distance_m));
  elements.routeElevationRange.textContent = `${Math.round(minimum)}–${Math.round(maximum)} m`;
  context.clearRect(0, 0, width, height);
  context.fillStyle = "rgba(38,115,82,0.10)";
  context.strokeStyle = "#267352";
  context.lineWidth = 2;
  context.beginPath();
  values.forEach((item, index) => {
    const x = padding + Number(item.distance_m) / maxDistance * (width - padding * 2);
    const y = height - padding - (Number(item.elevation_m) - minimum) / span * (height - padding * 2);
    if (index === 0) context.moveTo(x, y);
    else context.lineTo(x, y);
  });
  context.stroke();
  context.lineTo(width - padding, height - padding);
  context.lineTo(padding, height - padding);
  context.closePath();
  context.fill();
}

function localizedManeuver(maneuver) {
  const road = Array.isArray(maneuver.street_names) ? maneuver.street_names[0] : "";
  const target = road ? `进入 ${road}` : "继续行进";
  const templates = {
    1: `出发，${target}`, 2: `向右出发，${target}`, 3: `向左出发，${target}`,
    4: "到达终点", 5: "终点在道路右侧", 6: "终点在道路左侧",
    7: `道路转为 ${road || "下一路段"}`, 8: `直行，${target}`,
    9: `稍向右转，${target}`, 10: `右转，${target}`, 11: `向右急转，${target}`,
    12: `向右掉头，${target}`, 13: `向左掉头，${target}`, 14: `向左急转，${target}`,
    15: `左转，${target}`, 16: `稍向左转，${target}`, 17: "直行进入匝道",
    18: "向右进入匝道", 19: "向左进入匝道", 20: "从右侧出口驶出", 21: "从左侧出口驶出",
    22: "在分岔处保持直行", 23: "在分岔处靠右", 24: "在分岔处靠左", 25: "汇入道路",
    26: "进入环岛", 27: `驶出环岛，${target}`, 28: "驶上渡轮", 29: "驶离渡轮"
  };
  return templates[Number(maneuver.type)] || maneuver.instruction || "继续前行";
}

function speakText(text) {
  if (!("speechSynthesis" in window) || typeof SpeechSynthesisUtterance !== "function") {
    showToast("当前浏览器没有可用的本地语音接口", true);
    return;
  }
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = "zh-CN";
  utterance.rate = 0.95;
  const voice = window.speechSynthesis.getVoices().find((item) => item.lang.toLowerCase().startsWith("zh"));
  if (voice) utterance.voice = voice;
  window.speechSynthesis.speak(utterance);
}

function speakRoute() {
  const maneuvers = (state.route.result?.maneuvers || []).slice(0, 40);
  if (!maneuvers.length) return;
  speakText(maneuvers.map((maneuver) => localizedManeuver(maneuver)).join("。"));
}

function renderRouteResult(result) {
  const summary = result.summary || {};
  elements.routeDistance.textContent = `${Number(summary.length || 0).toFixed(1)} km`;
  elements.routeDuration.textContent = formatRouteDuration(summary.time);
  elements.routeManeuvers.innerHTML = (result.maneuvers || []).slice(0, 40).map((maneuver) => `
    <div class="route-step">
      <i data-lucide="corner-down-right"></i>
      <strong title="${escapeHtml(maneuver.instruction || "")}">${escapeHtml(localizedManeuver(maneuver))}</strong>
      <span>${Number(maneuver.length_km || 0) >= 1 ? `${Number(maneuver.length_km).toFixed(1)} km` : `${Math.round(Number(maneuver.length_km || 0) * 1000)} m`}</span>
    </div>`).join("");
  elements.routeEmpty.hidden = true;
  elements.routeResult.hidden = false;
  elements.routeSaveButton.disabled = false;
  elements.routeSpeakButton.disabled = false;
  drawRouteProfile(result.profile);
  icons();
}

async function runRoute() {
  if (!state.route.locations.every(Boolean)) return;
  const requestId = invalidateRoute();
  const input = { costing: state.route.costing, locations: state.route.locations.map((location) => ({ ...location })) };
  const controller = new AbortController();
  state.route.controller = controller;
  elements.routeEmpty.hidden = false;
  elements.routeEmpty.innerHTML = '<i data-lucide="loader-circle"></i><span>正在计算本地路线</span>';
  icons();
  try {
    const result = await api("/route", {
      method: "POST",
      body: JSON.stringify(input),
      signal: controller.signal
    });
    if (requestId !== state.route.requestId) return;
    state.route.result = result;
    state.route.resultInput = input;
    updateRouteSource();
    renderRouteResult(result);
    const bounds = result.geometry.coordinates.reduce(
      (current, coordinate) => current.extend(coordinate),
      new maplibregl.LngLatBounds(result.geometry.coordinates[0], result.geometry.coordinates[0])
    );
    state.map.fitBounds(bounds, {
      padding: { top: 80, right: 370, bottom: 72, left: document.body.classList.contains("panel-collapsed") ? 72 : 400 },
      duration: 650
    });
  } catch (error) {
    if (requestId !== state.route.requestId) return;
    elements.routeEmpty.innerHTML = '<i data-lucide="triangle-alert"></i><span>路线计算失败</span>';
    icons();
    showToast(error.message, true);
  } finally {
    if (state.route.controller === controller) state.route.controller = null;
  }
}

async function saveRouteTrack() {
  const result = state.route.result;
  const input = state.route.resultInput;
  if (!result?.geometry || !input) return;
  const [start, end] = input.locations;
  const activities = { auto: "driving", bicycle: "cycling", pedestrian: "walking" };
  try {
    await api("/tracks", {
      method: "POST",
      body: JSON.stringify({
        name: `${routePointLabel(start)} 至 ${routePointLabel(end)}`,
        activity: activities[input.costing],
        note: "由 TerraSys 离线 Valhalla 路线引擎生成",
        tags: ["offline-route", input.costing],
        color: "#2679a6",
        geometry: result.geometry
      })
    });
    await refreshData();
    showToast("路线已保存为个人轨迹");
  } catch (error) {
    showToast(error.message, true);
  }
}

async function updateEmergencyLayer() {
  const source = state.map.getSource("emergency-places");
  if (!source || !state.layerVisibility.emergency) return;
  const requestId = ++state.emergencyRequestId;
  const bounds = state.map.getBounds();
  const categories = [...elements.emergencyFilters.querySelectorAll("input:checked")].map((input) => input.value).join(",");
  if (!categories) {
    source.setData({ type: "FeatureCollection", features: [] });
    return;
  }
  try {
    const data = await api(`/emergency.geojson?categories=${encodeURIComponent(categories)}&west=${bounds.getWest()}&south=${bounds.getSouth()}&east=${bounds.getEast()}&north=${bounds.getNorth()}&limit=5000`);
    if (requestId === state.emergencyRequestId) source.setData(data);
  } catch (error) {
    showToast(error.message, true);
  }
}

function featureObjectProperty(value) {
  if (value && typeof value === "object") return value;
  if (typeof value === "string") {
    try {
      return JSON.parse(value);
    } catch {
      return {};
    }
  }
  return {};
}

function showEmergencyFeature(feature, lngLat) {
  const properties = feature.properties || {};
  const tags = featureObjectProperty(properties.tags);
  const labels = { medical: "医疗", security: "救援", shelter: "避难", supplies: "补给", fuel: "燃料" };
  const name = properties.name || "未命名应急设施";
  const popup = new maplibregl.Popup({ closeButton: true, maxWidth: "320px" })
    .setLngLat(lngLat)
    .setHTML(`
      <div class="popup-title">${escapeHtml(name)}</div>
      <div class="popup-meta">${escapeHtml(labels[properties.emergency_category] || "应急设施")} · ${escapeHtml(categoryLabel(properties.category, properties.subtype))}</div>
      <div class="popup-note">OpenStreetMap 本地应急参考</div>
      <div class="popup-actions">
        <button type="button" data-popup-action="save-emergency">保存为个人点位</button>
        <a href="/wiki/search?pattern=${encodeURIComponent(name)}" target="_blank" rel="noreferrer">百科</a>
      </div>`)
    .addTo(state.map);
  popup.getElement().querySelector('[data-popup-action="save-emergency"]').addEventListener("click", () => {
    openPlaceDialog({
      type: "Feature",
      properties: {
        name,
        category: "reference",
        province: tags["addr:province"] || "",
        tags: ["emergency", properties.emergency_category, properties.subtype].filter(Boolean),
        note: `来源：OpenStreetMap 本地应急图层（${labels[properties.emergency_category] || "应急设施"}）`
      },
      geometry: { type: "Point", coordinates: feature.geometry.coordinates }
    }, { copyAsNew: true, collectionIds: ["default-favorites"] });
    popup.remove();
  });
}

function applyLayerVisibility() {
  for (const [layerId, groups] of state.layerGroups.entries()) {
    if (!state.map.getLayer(layerId)) continue;
    const packId = state.layerPackIds.get(layerId);
    const visible = (!packId || state.visiblePackIds.has(packId))
      && groups.every((group) => state.layerVisibility[group] !== false);
    state.map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none");
  }
  syncMapShortcuts();
}

function syncMapShortcuts() {
  const liveCount = state.liveLayers?.visibleCount() || 0;
  const livePopoverOpen = elements.liveLayersPopover ? !elements.liveLayersPopover.hidden : false;
  elements.liveLayersShortcut?.classList.toggle("active", liveCount > 0 || livePopoverOpen);
  elements.liveLayersShortcut?.classList.toggle("has-visible-layers", liveCount > 0);
  elements.liveLayersShortcut?.setAttribute("aria-label", liveCount ? `附加信息图层，已开启 ${liveCount} 层` : "附加信息图层");
  elements.liveLayersShortcut?.setAttribute("title", liveCount ? `附加信息图层 · 已开启 ${liveCount} 层` : "附加信息图层");
  elements.onlineMapShortcut?.classList.toggle("active", state.onlineMapEnabled);
  elements.onlineMapShortcut?.classList.toggle("degraded", state.onlineMapEnabled && state.onlineMapStatus === "degraded");
  elements.onlineMapShortcut?.classList.toggle("fallback", state.onlineMapEnabled && state.onlineMapStatus === "fallback");
  elements.onlineMapShortcut?.setAttribute("aria-pressed", String(state.onlineMapEnabled));
  document.querySelectorAll("[data-theme]").forEach((button) => {
    const active = !state.onlineMapEnabled && button.dataset.theme === state.theme;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
    if (button.getAttribute("role") === "radio") button.setAttribute("aria-checked", String(active));
  });
  document.querySelectorAll("[data-online-provider]").forEach((button) => {
    const provider = button.dataset.onlineProvider;
    const active = provider === "offline"
      ? !state.onlineMapEnabled
      : state.onlineMapEnabled && provider === state.onlinePreferredProvider;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
    if (button.getAttribute("role") === "radio") button.setAttribute("aria-checked", String(active));
  });
  syncMapSourceControl();
}

function mapCoverageAt(longitude, latitude) {
  const installed = state.mapPacks
    .filter((pack) => !pack.deprecated && pack.installed && pack.enabled !== false && coordinateInPack(longitude, latitude, pack))
    .sort((left, right) => {
      const leftArea = Math.abs((Number(left.bounds[2]) - Number(left.bounds[0])) * (Number(left.bounds[3]) - Number(left.bounds[1])));
      const rightArea = Math.abs((Number(right.bounds[2]) - Number(right.bounds[0])) * (Number(right.bounds[3]) - Number(right.bounds[1])));
      return leftArea - rightArea;
    })[0] || null;
  return { installed, available: mapPackAt(longitude, latitude) };
}

function localBaseMapStatus(coordinate = null) {
  if (state.theme === "vector") return { mode: "vector", pack: null };
  const center = mapFocusCoordinate(coordinate);
  if (!center) return { mode: "unknown", pack: null };
  const longitude = Number(center.lng ?? center[0]);
  const latitude = Number(center.lat ?? center[1]);
  const coverage = mapCoverageAt(longitude, latitude);
  if (!coverage.installed) return { mode: "overview", pack: null };
  const readyIds = state.osmCartoPackIds;
  if (!Array.isArray(readyIds)) return { mode: "osm-carto", pack: coverage.installed };
  const readySet = new Set(readyIds);
  const cartoPack = state.mapPacks.find((pack) => readySet.has(pack.id)
    && pack.installed && pack.enabled !== false && coordinateInPack(longitude, latitude, pack));
  return cartoPack
    ? { mode: "osm-carto", pack: cartoPack }
    : { mode: "vector-fallback", pack: coverage.installed };
}

function osmCartoPackInViewport() {
  if (!state.map || state.theme !== "osm-carto") return null;
  const readyIds = Array.isArray(state.osmCartoPackIds) ? new Set(state.osmCartoPackIds) : null;
  const viewport = state.map.getBounds();
  return state.mapPacks.find((pack) => !pack.deprecated
    && pack.installed
    && pack.enabled !== false
    && (!readyIds || readyIds.has(pack.id))
    && packBoundsIntersectViewport(pack, viewport)) || null;
}

function syncLocalBaseMapForViewport(coordinate = null) {
  const status = localBaseMapStatus(coordinate);
  state.localBaseMapMode = status.mode;
  if (state.map?.getLayer("local-osm-carto-raster")) {
    state.map.setLayoutProperty("local-osm-carto-raster", "visibility", osmCartoPackInViewport() ? "visible" : "none");
  }
  syncMapSourceControl();
  return status;
}

function mapSourcePresentation() {
  if (!state.onlineMapEnabled) {
    const label = state.localBaseMapMode === "vector-fallback"
      ? "离线交互矢量（OSM 原版同步中）"
      : state.theme === "vector"
        ? "离线交互矢量"
        : state.localBaseMapMode === "osm-carto"
          ? "离线 OSM 原版"
          : "离线全球概览";
    return { label, icon: "wifi-off", tone: "offline" };
  }
  if (state.onlineMapStatus === "degraded") return { label: "在线不可用，已由离线概览补齐", icon: "wifi-off", tone: "degraded" };
  if (["loading", "fallback-loading"].includes(state.onlineMapStatus)) {
    return { label: `正在连接 ${onlineProvider().label}`, icon: onlineProvider().icon, tone: "loading" };
  }
  if (state.onlineMapProvider === "openfreemap") {
    const suffix = state.onlinePreferredProvider === "osm" ? "（备用源）" : "";
    return { label: `OpenFreeMap 已连接${suffix}`, icon: "wifi", tone: "online" };
  }
  return { label: `${onlineProvider().label}已连接`, icon: onlineProvider().icon, tone: "online" };
}

const legendBaseStyles = {
  "osm-carto": {
    hint: "OSM Carto 栅格样式；道路、用地和兴趣点配色与交互矢量不同。",
    items: [
      ["water", "水域"], ["park", "公园与绿地"], ["motorway", "高速公路"],
      ["primary-road", "主干路"], ["secondary-road", "次干路"], ["rail", "铁路"],
      ["osm-building", "建筑"], ["osm-boundary", "行政边界"], ["poi", "设施 / 兴趣点"]
    ],
    groups: [
      { title: "道路与交通", items: [
        ["motorway", "高速公路"], ["primary-road", "主干路"], ["secondary-road", "次干路"],
        ["minor-road", "普通道路 / 支路"], ["path", "步道 / 便道"], ["rail", "铁路"],
        ["tunnel", "隧道"], ["bridge", "桥梁"], ["road-ref", "道路编号"]
      ] },
      { title: "土地利用与水系", items: [
        ["water", "湖泊 / 水面"], ["waterway", "河流 / 溪流"], ["park", "公园"],
        ["osm-forest", "森林"], ["osm-grass", "草地"], ["osm-wetland", "湿地"],
        ["osm-farmland", "农田"], ["osm-residential", "住宅用地"], ["osm-commercial", "商业用地"],
        ["osm-industrial", "工业用地"], ["osm-cemetery", "墓地"], ["osm-sand", "沙地"]
      ] },
      { title: "建筑、边界与设施", items: [
        ["osm-building", "建筑物"], ["osm-boundary", "行政边界"], ["osm-school", "学校用地"],
        ["osm-hospital-area", "医疗用地"], ["aeroway", "机场 / 跑道"], ["poi-hospital poi-dot", "医疗设施"],
        ["poi-school poi-dot", "教育设施"], ["poi-transit poi-dot", "车站 / 公交"], ["poi-shop poi-dot", "商店 / 服务"],
        ["poi-tourism poi-dot", "旅游 / 历史"], ["poi-amenity poi-dot", "餐饮 / 常用设施"], ["mountain", "山峰"]
      ] },
      { title: "文字与标注", items: [
        ["label-sample", "地点 / 设施名称"], ["road-ref", "路线编号"], ["house-number", "门牌号码"]
      ] }
    ],
    note: "OSM 原版包含大量图标；这里按用途归类，具体图标和名称会随缩放级别出现。"
  },
  vector: {
    hint: "交互矢量样式；符号可随图层开关、缩放级别和交互状态变化。",
    items: [
      ["vector-water", "水域"], ["vector-park", "植被与绿地"], ["motorway", "高速公路"],
      ["primary-road", "主干路"], ["secondary-road", "次干路"], ["rail", "铁路"],
      ["vector-building", "建筑"], ["vector-boundary", "行政边界"], ["vector-poi", "设施 / 兴趣点"]
    ],
    groups: [
      { title: "道路与交通", items: [
        ["motorway", "高速公路"], ["primary-road", "主干路 / 快速路"], ["secondary-road", "次干路 / 三级路"],
        ["minor-road", "支路 / 服务道路"], ["path", "步道 / 台阶"], ["cycleway", "自行车道"],
        ["rail", "铁路 / 轨道交通"], ["tunnel", "隧道"], ["bridge", "桥梁"], ["road-ref", "道路编号"]
      ] },
      { title: "自然地貌与水系", items: [
        ["vector-water", "湖泊 / 水面"], ["waterway", "河流 / 溪流"], ["vector-forest", "森林"],
        ["vector-park", "草地 / 公园"], ["vector-wetland", "湿地"], ["vector-farmland", "农田"],
        ["osm-sand", "沙地"], ["terrain", "岩石 / 裸地"]
      ] },
      { title: "城市用地、建筑与边界", items: [
        ["vector-residential", "住宅用地"], ["vector-commercial", "商业 / 零售"], ["vector-industrial", "工业用地"],
        ["vector-school", "学校用地"], ["vector-hospital-area", "医疗用地"], ["vector-cemetery", "墓地"],
        ["aeroway", "机场 / 跑道"], ["vector-building", "建筑物"], ["vector-boundary", "行政边界"]
      ] },
      { title: "兴趣点与标注", items: [
        ["poi-park poi-dot", "公园设施"], ["poi-hospital poi-dot", "医疗设施"], ["poi-school poi-dot", "教育设施"],
        ["poi-transit poi-dot", "铁路 / 交通设施"], ["poi-amenity poi-dot", "公共设施"], ["poi-shop poi-dot", "购物"],
        ["poi-tourism poi-dot", "旅游 / 历史"], ["mountain", "山峰"], ["label-sample", "名称标注"],
        ["house-number", "门牌号码"]
      ] }
    ],
    note: "矢量图层会按缩放级别逐步显示；门牌、步道和详细兴趣点通常要放大后才出现。"
  },
  overview: {
    hint: "全球低缩放概览只表达骨架信息，不代表详细道路和完整兴趣点。",
    items: [
      ["world-land", "陆地与地貌"], ["world-water", "水域"], ["world-park", "主要绿地"],
      ["world-country", "国家边界"], ["world-region", "地区边界"], ["world-road", "主要道路"],
      ["rail", "主要铁路"], ["world-river", "主要河流"], ["world-place", "国家 / 城市名称"]
    ],
    groups: [
      { title: "地貌与水系", items: [
        ["world-land", "陆地 / 一般地貌"], ["osm-forest", "林地"], ["world-park", "主要公园"],
        ["world-urban", "城市区域"], ["world-sand", "沙地"], ["world-ice", "冰雪区域"],
        ["world-water", "海洋 / 湖泊"], ["world-river", "主要河流"]
      ] },
      { title: "交通、边界与地名", items: [
        ["world-road", "高速 / 主干路"], ["rail", "主要铁路"], ["world-country", "国家边界"],
        ["world-region", "地区边界"], ["world-place", "国家名称"], ["label-sample", "地区 / 城市名称"]
      ] }
    ],
    note: "全球概览只包含低缩放骨架数据；建筑、街巷和普通兴趣点并不存在于这一底图中。"
  },
  imagery: {
    hint: "Esri World Imagery 全球在线卫星与航空影像；清晰度随地区和数据年份变化。",
    items: [["imagery", "卫星 / 航空影像"], ["world-country", "道路与地名需通过覆盖层补充"]],
    groups: [{ title: "影像说明", items: [["imagery", "全球卫星与航空影像"], ["label-sample", "影像本身不保证包含地名标注"]] }],
    note: "影像仅按当前视口在线加载，不会写入离线区域包。"
  },
  "online-terrain": {
    hint: "OpenTopoMap 全球在线地形参考图，基于 OpenStreetMap 与 SRTM 高程数据。",
    items: [["terrain", "地形与晕渲"], ["world-water", "水系"], ["world-road", "道路"], ["world-country", "行政边界"]],
    groups: [{ title: "地形参考", items: [["terrain", "地貌与阴影"], ["world-water", "水域与河流"], ["world-road", "交通骨架"], ["label-sample", "主要地名"]] }],
    note: "在线地形参考与本地动态等高线是两套独立数据，可同时显示。"
  }
};

const legendOverlayItems = [
  { group: "personal", items: [["personal", "个人点位"], ["track", "个人轨迹"]] },
  { group: "terrain", items: [["terrain", "地形阴影"]] },
  { group: "contours", items: [["contours", "主等高线"], ["contours-minor", "次等高线高度"]] },
  { group: "weather", items: [["weather", "天气快照"]] },
  { group: "nautical", items: [["nautical", "航海参考"]] },
  { group: "emergency", items: [["emergency", "应急设施"]] }
];

function currentLegendPresentation() {
  const source = mapSourcePresentation();
  if (state.onlineMapEnabled) {
    if (state.onlineMapStatus === "degraded") {
      return { key: "overview", label: source.label };
    }
    if (state.onlineMapProvider === "openfreemap") {
      return { key: "vector", label: source.label };
    }
    if (state.onlineMapProvider === "esri-imagery") return { key: "imagery", label: source.label };
    if (state.onlineMapProvider === "opentopomap") return { key: "online-terrain", label: source.label };
    return { key: "osm-carto", label: source.label };
  }
  if (state.theme === "vector" || state.localBaseMapMode === "vector-fallback") {
    return { key: "vector", label: source.label };
  }
  if (state.localBaseMapMode === "osm-carto") {
    return { key: "osm-carto", label: source.label };
  }
  return { key: "overview", label: source.label };
}

function renderLegendItems(container, items) {
  if (!container) return;
  container.replaceChildren(...items.map(([swatch, label]) => {
    const row = document.createElement("span");
    const marker = document.createElement("i");
    marker.className = `swatch ${swatch}`;
    marker.setAttribute("aria-hidden", "true");
    row.append(marker, document.createTextNode(label));
    return row;
  }));
}

function renderLegendGroups(container, groups, note = "") {
  if (!container) return;
  const sections = groups.map((group) => {
    const section = document.createElement("section");
    section.className = "legend-detail-group";
    const heading = document.createElement("h3");
    heading.textContent = group.title;
    const grid = document.createElement("div");
    grid.className = "legend-grid";
    renderLegendItems(grid, group.items);
    section.append(heading, grid);
    return section;
  });
  if (note) {
    const noteElement = document.createElement("small");
    noteElement.className = "legend-detail-note";
    noteElement.textContent = note;
    sections.push(noteElement);
  }
  container.replaceChildren(...sections);
}

function renderLegend() {
  if (!elements.legendSourceLabel || !elements.legendBaseGrid) return;
  const presentation = currentLegendPresentation();
  const style = legendBaseStyles[presentation.key];
  const overlays = legendOverlayItems
    .filter(({ group }) => state.layerVisibility[group] !== false)
    .flatMap(({ items }) => items)
    .concat(state.liveLayers?.getLegendItems() || []);
  const signature = [presentation.key, presentation.label, ...overlays.flat()].join("|");
  if (state.legendSignature === signature) return;
  state.legendSignature = signature;
  elements.legendSourceLabel.textContent = presentation.label;
  elements.legendSourceHint.textContent = style.hint;
  renderLegendItems(elements.legendBaseGrid, style.items);
  renderLegendGroups(elements.legendDetailGroups, style.groups, style.note);
  renderLegendItems(elements.legendOverlayGrid, overlays);
  elements.legendOverlayEmpty.hidden = overlays.length > 0;
  elements.legendPopover.dataset.legendStyle = presentation.key;
}

function mapFocusCoordinate(coordinate = null) {
  if (coordinate) return coordinate;
  if (!state.map) return null;
  const canvas = state.map.getCanvas();
  const canvasRect = canvas.getBoundingClientRect();
  let contentLeft = 0;
  let contentRight = canvasRect.width;
  const sideRect = elements.sidePanel?.getBoundingClientRect();
  if (sideRect && sideRect.right > canvasRect.left && sideRect.left < canvasRect.right) {
    contentLeft = Math.min(canvasRect.width, sideRect.right - canvasRect.left + 14);
  }
  const overlayPanel = !elements.detailPanel?.hidden
    ? elements.detailPanel
    : !elements.routePanel?.hidden
      ? elements.routePanel
      : null;
  const overlayRect = overlayPanel?.getBoundingClientRect();
  if (overlayRect && overlayRect.left < canvasRect.right && overlayRect.right > canvasRect.left) {
    contentRight = Math.max(0, overlayRect.left - canvasRect.left - 14);
  }
  if (contentRight <= contentLeft) return state.map.getCenter();
  return state.map.unproject([(contentLeft + contentRight) / 2, canvasRect.height / 2]);
}

function syncMapSourceControl() {
  if (!elements.onlineMapShortcut) return;
  const center = mapFocusCoordinate();
  const promptedPack = !elements.coveragePrompt?.hidden
    ? state.mapPacks.find((pack) => pack.id === state.coveragePromptPackId)
    : null;
  const coverage = promptedPack
    ? { installed: promptedPack.installed && promptedPack.enabled !== false ? promptedPack : null, available: promptedPack }
    : center
      ? mapCoverageAt(Number(center.lng), Number(center.lat))
      : { installed: null, available: null };
  const source = mapSourcePresentation();
  const cartoFallback = !state.onlineMapEnabled && state.localBaseMapMode === "vector-fallback" && coverage.installed;
  const coverageLabel = coverage.installed
    ? `${resourcePackName(coverage.installed)}已安装并启用${cartoFallback ? " · OSM 原版后台同步中" : ""}`
    : coverage.available
      ? `${resourcePackName(coverage.available)}未安装`
      : "当前区域暂无独立离线包";
  const offlineStyle = cartoFallback ? "交互矢量（OSM 原版同步中）" : state.theme === "vector" ? "交互矢量" : "OSM 原版";
  const offlineLabel = coverage.installed ? `离线地图：${resourcePackName(coverage.installed)} · ${offlineStyle}` : "离线全球概览";
  const title = state.onlineMapEnabled ? source.label : offlineLabel;
  elements.mapSourceStatus.textContent = title;
  elements.mapCoverageStatus.textContent = coverageLabel;
  elements.onlineMapShortcut.title = `地图来源：${title}`;
  elements.onlineMapShortcut.setAttribute("aria-label", `地图来源，当前${title}`);
  const iconName = source.icon;
  if (elements.onlineMapShortcut.dataset.icon !== iconName) {
    elements.onlineMapShortcut.dataset.icon = iconName;
    elements.onlineMapShortcut.innerHTML = `<i data-lucide="${iconName}"></i><span class="map-source-indicator" aria-hidden="true"></span>`;
    icons();
  }
  elements.onlineMapShortcut.classList.remove("source-online", "source-loading", "source-degraded", "source-offline", "source-offline-covered");
  elements.onlineMapShortcut.classList.add(`source-${source.tone === "offline" && coverage.installed ? "offline-covered" : source.tone}`);
  renderLegend();
}

function setMapSourceOpen(open) {
  if (!elements.mapSourcePopover) return;
  elements.mapSourcePopover.hidden = !open;
  elements.onlineMapShortcut.setAttribute("aria-expanded", String(open));
  if (open) {
    setLegendOpen(false);
    setLayersOpen(false);
    setLiveLayersOpen(false);
    syncMapSourceControl();
  }
}

function setLayersOpen(open) {
  if (!elements.layersPopover) return;
  elements.layersPopover.hidden = !open;
  elements.layersShortcut.setAttribute("aria-expanded", String(open));
  elements.layersShortcut.classList.toggle("active", open);
  if (open) {
    setMapSourceOpen(false);
    setLegendOpen(false);
    setLiveLayersOpen(false);
    syncDisplaySettings();
  }
}

function setLiveLayersOpen(open) {
  if (!elements.liveLayersPopover) return;
  elements.liveLayersPopover.hidden = !open;
  elements.liveLayersShortcut?.setAttribute("aria-expanded", String(open));
  if (open) {
    setMapSourceOpen(false);
    setLayersOpen(false);
    setLegendOpen(false);
  }
  syncMapShortcuts();
}

function setOnlineMapStatus(status) {
  state.onlineMapStatus = status;
  ["osm", "esri-imagery", "opentopomap"].forEach((provider) => {
    const layerId = onlineProvider(provider).layerId;
    if (!state.map?.getLayer(layerId)) return;
    const visible = state.onlineMapEnabled && state.onlineMapProvider === provider && status !== "degraded";
    state.map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none");
  });
  state.onlineVectorLayerIds.forEach((layerId) => {
    if (!state.map?.getLayer(layerId)) return;
    const visible = state.onlineMapEnabled && state.onlineMapProvider === "openfreemap" && status !== "degraded";
    state.map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none");
  });
  clearTimeout(state.onlineRetryTimer);
  if (status === "degraded" && state.onlineMapEnabled) {
    state.onlineRetryTimer = setTimeout(() => {
      if (!state.onlineMapEnabled) return;
      watchOnlineMapConnection(state.onlinePreferredProvider);
    }, 30_000);
  }
  syncMapShortcuts();
}

function watchOnlineMapConnection(provider = "osm") {
  clearTimeout(state.onlineStatusTimer);
  clearTimeout(state.onlineRetryTimer);
  state.onlineMapProvider = provider;
  state.onlineTileErrors = 0;
  if (!state.onlineMapEnabled) {
    setOnlineMapStatus("idle");
    return;
  }
  setOnlineMapStatus(provider === "openfreemap" ? "fallback-loading" : "loading");
  state.onlineStatusTimer = setTimeout(() => {
    if (!state.onlineMapEnabled) return;
    if (provider === "osm" && state.onlineMapProvider === "osm" && state.onlineMapStatus !== "ready") activateOnlineFallback();
    if (provider !== "osm" && state.onlineMapProvider === provider && !["ready", "fallback"].includes(state.onlineMapStatus)) setOnlineMapStatus("degraded");
  }, 8000);
}

function activateOnlineFallback() {
  if (!state.map?.getSource("online-openfreemap")) {
    setOnlineMapStatus("degraded");
    return;
  }
  if (!state.onlineFallbackAnnounced) {
    state.onlineFallbackAnnounced = true;
    showToast("OSM 标准图连接不稳定，已切换开放矢量备用源");
  }
  watchOnlineMapConnection("openfreemap");
}

function setOnlineMapEnabled(enabled, announce = true) {
  state.onlineMapEnabled = Boolean(enabled);
  localStorage.setItem("terrasys-online-map", String(state.onlineMapEnabled));
  state.onlineFallbackAnnounced = false;
  watchOnlineMapConnection(state.onlinePreferredProvider);
  syncMapShortcuts();
  updateCoveragePrompt();
  if (announce) {
    const providerName = onlineProvider(state.onlinePreferredProvider).label;
    showToast(state.onlineMapEnabled ? `${providerName}已开启，仅加载当前视口` : "已返回本地离线概览");
  }
}

function setOnlineMapProvider(provider, announce = true) {
  if (provider === "offline") {
    setOnlineMapEnabled(false, announce);
    return;
  }
  if (!onlineMapProviders.includes(provider)) return;
  state.onlinePreferredProvider = provider;
  state.onlineMapProvider = provider;
  state.onlineMapEnabled = true;
  state.onlineFallbackAnnounced = false;
  localStorage.setItem("terrasys-online-provider", provider);
  localStorage.setItem("terrasys-online-map", "true");
  watchOnlineMapConnection(provider);
  updateCoveragePrompt();
  if (announce) {
    showToast(`已切换到${onlineProvider(provider).label}，仅加载当前视口`);
  }
}

function coordinateInBounds(longitude, latitude, bounds) {
  return Array.isArray(bounds) && bounds.length === 4
    && longitude >= Number(bounds[0]) && longitude <= Number(bounds[2])
    && latitude >= Number(bounds[1]) && latitude <= Number(bounds[3]);
}

function coordinateInRing(longitude, latitude, ring) {
  const ringLongitudes = ring.map((coordinate) => Number(coordinate[0])).filter(Number.isFinite);
  const crossesDateLine = ringLongitudes.length > 1
    && Math.max(...ringLongitudes) - Math.min(...ringLongitudes) > 180;
  const normalizedLongitude = (value) => crossesDateLine && Number(value) < 0 ? Number(value) + 360 : Number(value);
  const targetLongitude = normalizedLongitude(longitude);
  let inside = false;
  for (let current = 0, previous = ring.length - 1; current < ring.length; previous = current++) {
    const currentLongitude = normalizedLongitude(ring[current][0]);
    const currentLatitude = Number(ring[current][1]);
    const previousLongitude = normalizedLongitude(ring[previous][0]);
    const previousLatitude = Number(ring[previous][1]);
    const crossesLatitude = (currentLatitude > latitude) !== (previousLatitude > latitude);
    const crossingLongitude = ((previousLongitude - currentLongitude) * (latitude - currentLatitude))
      / (previousLatitude - currentLatitude) + currentLongitude;
    if (crossesLatitude && targetLongitude < crossingLongitude) inside = !inside;
  }
  return inside;
}

function boundaryFromGeometry(geometry) {
  const boundary = { include: [], exclude: [] };
  const appendPolygon = (polygon) => {
    if (!Array.isArray(polygon) || !Array.isArray(polygon[0])) return;
    boundary.include.push(polygon[0]);
    polygon.slice(1).filter(Array.isArray).forEach((ring) => boundary.exclude.push(ring));
  };
  if (geometry?.type === "Polygon") appendPolygon(geometry.coordinates);
  if (geometry?.type === "MultiPolygon") geometry.coordinates.forEach(appendPolygon);
  return boundary;
}

function countryBoundariesFromGeoJson(collection) {
  const boundaries = {};
  (collection?.features || []).forEach((feature) => {
    const properties = feature.properties || {};
    const countryCode = [properties.ISO_A2, properties.ISO_A2_EH, properties.POSTAL]
      .map((value) => String(value || "").toUpperCase())
      .find((value) => /^[A-Z]{2}$/.test(value));
    if (!countryCode) return;
    const boundary = boundaryFromGeometry(feature.geometry);
    if (!boundary.include.length) return;
    if (!boundaries[countryCode]) boundaries[countryCode] = { include: [], exclude: [] };
    boundaries[countryCode].include.push(...boundary.include);
    boundaries[countryCode].exclude.push(...boundary.exclude);
  });
  return boundaries;
}

function precisePackBoundaries(pack) {
  const candidateIds = [
    pack.id,
    ...(Array.isArray(pack.members) ? pack.members.map((member) => member.id) : []),
    String(pack.id || "").replace(/^gf-/, "")
  ];
  const boundaries = [...new Set(candidateIds)]
    .map((id) => state.mapPackBoundaries[id])
    .filter(Boolean);
  const countryCode = String(pack.countryId || "").toUpperCase();
  if (/^[A-Z]{2}$/.test(countryCode) && state.mapCountryBoundaries[countryCode]) {
    boundaries.push(state.mapCountryBoundaries[countryCode]);
  }
  return boundaries;
}

function coordinateInPack(longitude, latitude, pack) {
  if (!coordinateInBounds(longitude, latitude, pack.bounds)) return false;
  const boundaries = precisePackBoundaries(pack);
  if (!boundaries.length) return pack.kind === "province";
  return boundaries.some((boundary) => {
    const included = boundary.include.some((ring) => coordinateInRing(longitude, latitude, ring));
    const excluded = boundary.exclude.some((ring) => coordinateInRing(longitude, latitude, ring));
    return included && !excluded;
  });
}

function mapPackAt(longitude, latitude) {
  return state.mapPacks
    .filter((pack) => !pack.deprecated && coordinateInPack(longitude, latitude, pack))
    .sort((left, right) => {
      const leftArea = Math.abs((Number(left.bounds[2]) - Number(left.bounds[0])) * (Number(left.bounds[3]) - Number(left.bounds[1])));
      const rightArea = Math.abs((Number(right.bounds[2]) - Number(right.bounds[0])) * (Number(right.bounds[3]) - Number(right.bounds[1])));
      return leftArea - rightArea;
    })[0] || null;
}

function showCoveragePromptForPack(pack) {
  state.coveragePromptPackId = pack.id;
  const name = resourcePackName(pack);
  elements.coveragePromptTitle.textContent = `${name}未安装离线地图`;
  elements.coveragePromptText.textContent = state.onlineMapEnabled
    ? "当前使用在线地图；断网后仅保留全球概览。可提前下载此区域。"
    : "当前仅显示全球离线概览。可在资源管理中下载此区域。";
  elements.coveragePrompt.hidden = false;
  syncMapSourceControl();
  icons();
}

function updateCoveragePrompt(coordinate = null, force = false) {
  if (!elements.coveragePrompt || !state.map) return;
  const center = mapFocusCoordinate(coordinate);
  const longitude = Number(center.lng ?? center[0]);
  const latitude = Number(center.lat ?? center[1]);
  const pinnedPack = state.mapPacks.find((pack) => pack.id === state.coveragePromptPinnedId);
  if (pinnedPack && !pinnedPack.installed
      && (Date.now() < state.coveragePromptPinnedUntil
        || coordinateInPack(longitude, latitude, pinnedPack)
        || coordinateInBounds(longitude, latitude, pinnedPack.bounds))) {
    showCoveragePromptForPack(pinnedPack);
    return;
  }
  if (pinnedPack) {
    state.coveragePromptPinnedId = null;
    state.coveragePromptPinnedUntil = 0;
  }
  const installed = state.mapPacks.some((pack) => pack.installed && pack.enabled !== false && coordinateInPack(longitude, latitude, pack));
  const pack = mapPackAt(longitude, latitude);
  if (state.coveragePromptDismissedId && state.coveragePromptDismissedId !== pack?.id) {
    state.coveragePromptDismissedId = null;
  }
  const belowDetailZoom = state.map.getZoom() < 8;
  if (installed || !pack || (!force && belowDetailZoom) || (!force && state.coveragePromptDismissedId === pack.id)) {
    elements.coveragePrompt.hidden = true;
    state.coveragePromptPackId = null;
    syncMapSourceControl();
    return;
  }
  showCoveragePromptForPack(pack);
}

function setLayerGroupVisibility(group, visible) {
  state.layerVisibility[group] = visible;
  document.querySelectorAll(`[data-layer-toggle="${group}"]`).forEach((input) => {
    input.checked = visible;
  });
  applyLayerVisibility();

  if (group === "emergency") {
    elements.emergencyFilters.hidden = !visible;
    if (visible) updateEmergencyLayer();
  }
}

function applyLayerPreset(preset) {
  const values = preset === "road"
    ? { land: true, roads: true, buildings: false, poi: false, labels: true }
    : { land: true, roads: true, buildings: true, poi: true, labels: true };
  Object.entries(values).forEach(([group, visible]) => {
    state.layerVisibility[group] = visible;
    document.querySelectorAll(`[data-layer-toggle="${group}"]`).forEach((input) => { input.checked = visible; });
  });
  applyLayerVisibility();
  showToast(preset === "road" ? "已切换到道路地图模式" : "已恢复标准地图模式");
}

function useResourceAction(action) {
  if (action === "overview") {
    state.coveragePromptPinnedId = null;
    state.coveragePromptPinnedUntil = 0;
    setOnlineMapEnabled(false, false);
    state.map.fitBounds([[-170, -60], [170, 78]], { padding: 36, duration: 700 });
    showToast("已打开全球离线概览");
  } else if (action === "online-map") {
    setOnlineMapEnabled(!state.onlineMapEnabled);
  } else if (action === "standard-mode") {
    applyLayerPreset("standard");
  } else if (action === "road-mode") {
    applyLayerPreset("road");
  } else if (["contours", "weather", "nautical"].includes(action)) {
    if (action === "weather") state.map.getSource("weather-snapshot")?.setData(`/api/weather?v=${Date.now()}`);
    if (action === "nautical") state.map.getSource("nautical-reference")?.setData(`/api/nautical?v=${Date.now()}`);
    setLayerGroupVisibility(action, true);
    showToast(`${resourceType(action === "weather" ? "weather" : action === "nautical" ? "nautical" : "contours")?.name || "图层"}已显示`);
  } else if (["encyclopedia", "travel-guide"].includes(action)) {
    window.open("/wiki/", "_blank", "noopener,noreferrer");
  } else if (action === "labels") {
    setLayerGroupVisibility("labels", true);
    showToast("离线中文与拉丁字形已启用");
  } else if (action === "styles") {
    elements.resourceManagerDialog.close();
    setSidePanelCollapsed(false);
    document.querySelector('[data-tab="layers"]')?.click();
    showToast("可在图层面板切换矢量样式与本地 OSM 原版");
    return;
  } else if (action === "search") {
    elements.resourceManagerDialog.close();
    elements.searchInput.focus();
    showToast("本地地址与地点搜索已就绪");
    return;
  } else if (action === "route") {
    elements.resourceManagerDialog.close();
    elements.routeButton.click();
    return;
  } else if (action === "personal") {
    elements.resourceManagerDialog.close();
    setSidePanelCollapsed(false);
    document.querySelector('[data-tab="personal"]')?.click();
    return;
  } else if (action === "tts") {
    speakText("本地中文语音提示已经可以使用。路线计算完成后，可以朗读全部步骤。");
  }
  if (!["encyclopedia", "travel-guide", "tts"].includes(action)) elements.resourceManagerDialog.close();
}

function setLegendOpen(open) {
  if (open) renderLegend();
  elements.legendPopover.hidden = !open;
  elements.legendShortcut.classList.toggle("active", open);
  elements.legendShortcut.setAttribute("aria-expanded", String(open));
  if (open && elements.mapSourcePopover && !elements.mapSourcePopover.hidden) {
    elements.mapSourcePopover.hidden = true;
    elements.onlineMapShortcut.setAttribute("aria-expanded", "false");
  }
  if (open) {
    setLayersOpen(false);
    setLiveLayersOpen(false);
  }
}

function applyPoiDensity() {
  if (!state.map?.isStyleLoaded()) return;
  for (const [layerId, groups] of state.layerGroups.entries()) {
    if (!groups.includes("poi") || !state.map.getLayer(layerId)) continue;
    const layer = state.map.getLayer(layerId);
    if (!state.layerMinZoom.has(layerId)) state.layerMinZoom.set(layerId, Number(layer.minzoom) || 0);
    const base = state.layerMinZoom.get(layerId);
    const minzoom = state.poiDensity === "low" ? Math.max(base, 14) : state.poiDensity === "high" ? Math.max(0, base - 1.5) : base;
    state.map.setLayerZoomRange(layerId, minzoom, Number(layer.maxzoom) || 24);
  }
}

function syncDisplaySettings() {
  document.querySelectorAll("[data-poi-density]").forEach((button) => button.classList.toggle("active", button.dataset.poiDensity === state.poiDensity));
  document.querySelectorAll("[data-map-light]").forEach((button) => button.classList.toggle("active", button.dataset.mapLight === state.mapLight));
  document.querySelectorAll("[data-scale-unit]").forEach((button) => button.classList.toggle("active", button.dataset.scaleUnit === state.scaleUnit));
  document.body.classList.toggle("map-night", state.mapLight === "night");
}

function setPoiDensity(density) {
  if (!["low", "standard", "high"].includes(density)) return;
  state.poiDensity = density;
  localStorage.setItem("terrasys-poi-density", density);
  applyPoiDensity();
  syncDisplaySettings();
  showToast(`兴趣点密度已切换为${density === "low" ? "精简" : density === "high" ? "丰富" : "标准"}`);
}

function setMapLight(mode) {
  state.mapLight = mode === "night" ? "night" : "day";
  localStorage.setItem("terrasys-map-light", state.mapLight);
  syncDisplaySettings();
  showToast(state.mapLight === "night" ? "已启用夜间浏览" : "已恢复昼间浏览");
}

function setScaleUnit(unit) {
  if (!["metric", "imperial", "nautical"].includes(unit)) return;
  state.scaleUnit = unit;
  localStorage.setItem("terrasys-scale-unit", unit);
  state.scaleControl?.setUnit(unit);
  syncDisplaySettings();
  showToast(`比例尺已切换为${{ metric: "公制", imperial: "英制", nautical: "海里" }[unit]}`);
}

function startMeasure(kind) {
  const nextMode = kind === "area" ? "measure-area" : "measure-distance";
  if (state.mode === nextMode) {
    state.measureCoordinates = [];
    updateMeasure();
    setMode(null);
    return;
  }
  state.measureKind = kind === "area" ? "area" : "distance";
  state.measureCoordinates = [];
  setMode(nextMode);
  updateMeasure();
}

function addWorldVectorOverviewLayers(map, beforeLayerId = undefined) {
  const overview = state.resourceCatalog?.localMaps?.worldOverviewVector;
  if (!overview?.url || map.getSource("world-vector-overview")) return [];
  const sourceId = "world-vector-overview";
  const maxzoom = Number(overview.maxZoom) + 1 || 8;
  const revision = String(overview.revision || "").trim();
  const revisionSeparator = overview.url.includes("?") ? "&" : "?";
  const sourceUrl = `${overview.url}${revision ? `${revisionSeparator}v=${encodeURIComponent(revision)}` : ""}`;
  const sourceNameField = ["coalesce", ["get", "name:zh"], ["get", "name"], ["get", "name:latin"], ["get", "name_en"]];
  const nameField = [
    "case",
    [
      "all",
      ["in", ["get", "class"], ["literal", ["country", "state"]]],
      [
        "any",
        ["==", ["get", "name:zh"], "中华民国"],
        ["==", ["get", "name"], "中华民国"],
        ["==", ["get", "name_en"], "Taiwan"],
        ["==", ["get", "name_en"], "Taiwan Province"]
      ]
    ],
    "台湾省",
    sourceNameField
  ];
  map.addSource(sourceId, {
    type: "vector",
    url: `pmtiles://${window.location.origin}${sourceUrl}`,
    attribution: `<a href="${escapeHtml(overview.naturalEarthUrl || "https://www.naturalearthdata.com/")}" target="_blank" rel="noreferrer">Made with Natural Earth</a>`
  });
  const lineGeometry = ["match", ["geometry-type"], ["LineString", "MultiLineString"], true, false];
  const layers = [
    {
      id: "world-vector-landcover", type: "fill", source: sourceId, "source-layer": "landcover",
      paint: {
        "fill-color": ["match", ["get", "class"], "wood", "#a7c99a", "grass", "#cbdca8", "urban", "#ddd3c8", "ice", "#e8f1f2", "sand", "#eadcb9", "land", "#dde4cb", "#d8dfbd"],
        "fill-opacity": ["interpolate", ["linear"], ["zoom"], 2, 0.28, 6, 0.56]
      }
    },
    {
      id: "world-vector-park", type: "fill", source: sourceId, "source-layer": "park", minzoom: 4,
      paint: { "fill-color": "#bdd6ad", "fill-opacity": 0.5 }
    },
    {
      id: "world-vector-water", type: "fill", source: sourceId, "source-layer": "water",
      paint: { "fill-color": "#a8d2df", "fill-opacity": 0.96 }
    },
    {
      id: "world-vector-boundary", type: "line", source: sourceId, "source-layer": "boundary",
      filter: ["all", ["!=", ["get", "maritime"], 1]],
      paint: {
        "line-color": ["match", ["get", "admin_level"], 2, "#69636f", 4, "#99909b", "#b0a8ae"],
        "line-width": ["interpolate", ["linear"], ["zoom"], 2, 0.45, 5, ["match", ["get", "admin_level"], 2, 1.25, 4, 0.75, 0.45], 7, ["match", ["get", "admin_level"], 2, 1.8, 4, 1, 0.6]],
        "line-opacity": ["match", ["get", "admin_level"], 2, 0.88, 4, 0.65, 0.48]
      }
    },
    {
      id: "world-vector-waterway", type: "line", source: sourceId, "source-layer": "waterway", minzoom: 5,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#69a9c0", "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.45, 7, 1.1], "line-opacity": 0.78 }
    },
    {
      id: "world-vector-major-road-casing", type: "line", source: sourceId, "source-layer": "transportation", minzoom: 5,
      filter: ["all", lineGeometry, ["in", ["get", "class"], ["literal", ["motorway", "trunk", "primary"]]]],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#d6a06d", "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.8, 7, 2.3], "line-opacity": 0.75 }
    },
    {
      id: "world-vector-major-road", type: "line", source: sourceId, "source-layer": "transportation", minzoom: 5,
      filter: ["all", lineGeometry, ["in", ["get", "class"], ["literal", ["motorway", "trunk", "primary"]]]],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: {
        "line-color": ["match", ["get", "class"], "motorway", "#e88e9d", "#f4c997"],
        "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.45, 7, 1.45], "line-opacity": 0.92
      }
    },
    {
      id: "world-vector-rail", type: "line", source: sourceId, "source-layer": "transportation", minzoom: 6,
      filter: ["all", lineGeometry, ["in", ["get", "class"], ["literal", ["rail", "transit"]]]],
      paint: { "line-color": "#777777", "line-width": ["interpolate", ["linear"], ["zoom"], 6, 0.35, 7, 0.7], "line-opacity": 0.58 }
    },
    {
      id: "world-vector-country-label", type: "symbol", source: sourceId, "source-layer": "place", minzoom: 2, maxzoom: 5.5,
      filter: ["all", ["has", "name"], ["in", ["get", "class"], ["literal", ["country", "continent"]]]],
      layout: {
        "text-field": nameField, "text-font": ["Noto Sans Regular"],
        "text-size": ["interpolate", ["linear"], ["zoom"], 2, 9, 5, 13], "text-padding": 4,
        "symbol-sort-key": ["coalesce", ["get", "rank"], 20]
      },
      paint: { "text-color": "#323834", "text-halo-color": "rgba(250,249,244,0.9)", "text-halo-width": 1.2 }
    },
    {
      id: "world-vector-place-label", type: "symbol", source: sourceId, "source-layer": "place", minzoom: 4,
      filter: ["all", ["has", "name"], ["in", ["get", "class"], ["literal", ["state", "city", "town"]]]],
      layout: {
        "text-field": nameField, "text-font": ["Noto Sans Regular"],
        "text-size": ["interpolate", ["linear"], ["zoom"], 4, 9, 6, 11, 7, 13], "text-padding": 3,
        "symbol-sort-key": ["coalesce", ["get", "rank"], 20]
      },
      paint: { "text-color": "#26312c", "text-halo-color": "rgba(250,249,244,0.94)", "text-halo-width": 1.25 }
    }
  ].map((layer) => ({ ...layer, maxzoom: Math.min(Number(layer.maxzoom) || maxzoom, maxzoom) }));
  const baseLayerIds = new Set(["world-vector-landcover", "world-vector-park", "world-vector-water"]);
  layers.forEach((layer) => map.addLayer(layer, baseLayerIds.has(layer.id) ? beforeLayerId : undefined));
  return layers.map((layer) => layer.id);
}

function addOfflineReferenceLayers() {
  const map = state.map;
  if (map.getSource("world-overview")) {
    state.liveLayers?.ensureLayers();
    return;
  }
  const firstPackLayerId = map.getStyle().layers.find((layer) => state.layerPackIds.has(layer.id))?.id;
  if (map.getLayer("background")) {
    map.setPaintProperty("background", "background-color", [
      "interpolate", ["linear"], ["zoom"],
      5.4, "#a9cfda",
      6.2, "#f4f1e8"
    ]);
  }
  map.addSource("world-overview", {
    type: "image",
    url: "/assets/overview/gray-earth.jpg?v=mercator-4096-20260801",
    coordinates: [[-179.999, 85.05112878], [179.999, 85.05112878], [179.999, -85.05112878], [-179.999, -85.05112878]]
  });
  map.addLayer({
    id: "world-overview-raster",
    type: "raster",
    source: "world-overview",
    maxzoom: 7,
    paint: {
      "raster-opacity": ["interpolate", ["linear"], ["zoom"], 2, 0.7, 4, 0.54, 5.2, 0.2, 6, 0],
      "raster-contrast": 0.16,
      "raster-brightness-min": 0.18,
      "raster-brightness-max": 0.92
    }
  });
  const localOsmCarto = state.resourceCatalog?.localMaps?.osmCarto;
  if (localOsmCarto?.tiles?.length) {
    const localOsmCartoBounds = Array.isArray(localOsmCarto.bounds) && localOsmCarto.bounds.length === 4
      ? { bounds: localOsmCarto.bounds.map(Number) }
      : {};
    map.addSource("local-osm-carto", {
      type: "raster",
      tiles: localOsmCarto.tiles,
      tileSize: Number(localOsmCarto.tileSize) || 256,
      minzoom: Number(localOsmCarto.minZoom) || 0,
      maxzoom: Number(localOsmCarto.maxZoom) || 20,
      ...localOsmCartoBounds,
      attribution: `<a href="${escapeHtml(localOsmCarto.copyrightUrl || "https://www.openstreetmap.org/copyright")}" target="_blank" rel="noreferrer">© OpenStreetMap contributors</a> · <a href="${escapeHtml(localOsmCarto.styleUrl || "https://github.com/gravitystorm/openstreetmap-carto")}" target="_blank" rel="noreferrer">OpenStreetMap Carto</a>`
    });
    map.addLayer({
      id: "local-osm-carto-raster",
      type: "raster",
      source: "local-osm-carto",
      layout: { visibility: "none" },
      paint: { "raster-opacity": 1, "raster-fade-duration": 0 }
    });
  }
  ["osm", "esri-imagery", "opentopomap"].forEach((provider) => {
    const onlineMap = onlineRasterCatalog(provider);
    const providerMeta = onlineProvider(provider);
    if (!onlineMap?.tiles?.length) return;
    const attributionUrl = onlineMap.copyrightUrl || onlineMap.homepage || "https://www.esri.com/";
    map.addSource(providerMeta.sourceId, {
      type: "raster",
      tiles: onlineMap.tiles,
      tileSize: Number(onlineMap.tileSize) || 256,
      maxzoom: Number(onlineMap.maxZoom) || 19,
      attribution: `<a href="${escapeHtml(attributionUrl)}" target="_blank" rel="noreferrer">${escapeHtml(onlineMap.attribution || providerMeta.label)}</a>`
    });
    map.addLayer({
      id: providerMeta.layerId,
      type: "raster",
      source: providerMeta.sourceId,
      layout: { visibility: state.onlineMapEnabled && state.onlineMapProvider === provider ? "visible" : "none" },
      paint: { "raster-opacity": 1, "raster-fade-duration": provider === "osm" ? 0 : 180 }
    });
  });
  map.addSource("world-countries", {
    type: "geojson",
    data: "/assets/overview/countries.geojson",
    attribution: "Made with Natural Earth"
  });
  map.addLayer({
    id: "world-country-fill",
    type: "fill",
    source: "world-countries",
    maxzoom: 7,
    paint: {
      "fill-color": "#e2e8d7",
      "fill-opacity": ["interpolate", ["linear"], ["zoom"], 2, 0.36, 4, 0.28, 5, 0]
    }
  });
  map.addLayer({
    id: "world-country-boundaries",
    type: "line",
    source: "world-countries",
    maxzoom: 7,
    paint: {
      "line-color": "#777d79",
      "line-width": ["interpolate", ["linear"], ["zoom"], 1, 0.35, 5, 0.8],
      "line-opacity": ["interpolate", ["linear"], ["zoom"], 2, 0.72, 4, 0.5, 5, 0]
    }
  });
  map.addSource("world-places", {
    type: "geojson",
    data: "/assets/overview/places.geojson",
    attribution: "Made with Natural Earth"
  });
  map.addLayer({
    id: "world-place-labels",
    type: "symbol",
    source: "world-places",
    minzoom: 2,
    maxzoom: 5,
    filter: ["<=", ["coalesce", ["get", "scalerank"], 10], 6],
    layout: {
      "text-field": ["coalesce", ["get", "namepar"], ["get", "name"], ["get", "nameascii"]],
      "text-font": ["Noto Sans Regular"],
      "text-size": ["interpolate", ["linear"], ["zoom"], 2, 9, 5, 12],
      "text-padding": 3
    },
    paint: { "text-color": "#26312c", "text-halo-color": "rgba(248,247,241,0.92)", "text-halo-width": 1.2 }
  });
  const worldVectorLayerIds = addWorldVectorOverviewLayers(map, firstPackLayerId);

  const onlineVectorStyle = createOnlineVectorStyle();
  if (onlineVectorStyle) {
    const sourceId = "online-openfreemap";
    map.addSource(sourceId, onlineVectorStyle.style.sources[sourceId]);
    state.onlineVectorLayerIds = [];
    onlineVectorStyle.style.layers.filter((layer) => layer.source === sourceId).forEach((layer) => {
      const onlineLayer = {
        ...layer,
        layout: { ...(layer.layout || {}), visibility: "none" }
      };
      map.addLayer(onlineLayer);
      state.onlineVectorLayerIds.push(onlineLayer.id);
    });
  }

  map.addSource("weather-snapshot", { type: "geojson", data: "/api/weather" });
  map.addLayer({
    id: "weather-point",
    type: "circle",
    source: "weather-snapshot",
    minzoom: 5,
    paint: { "circle-radius": 10, "circle-color": "#2f82ad", "circle-opacity": 0.9, "circle-stroke-color": "#ffffff", "circle-stroke-width": 2 }
  });
  map.addLayer({
    id: "weather-label",
    type: "symbol",
    source: "weather-snapshot",
    minzoom: 5,
    layout: {
      "text-field": ["concat", ["get", "name"], "  ", ["to-string", ["get", "temperature"]], "°"],
      "text-font": ["Noto Sans Regular"],
      "text-size": 11,
      "text-offset": [0, 1.35],
      "text-anchor": "top"
    },
    paint: { "text-color": "#173e53", "text-halo-color": "rgba(255,255,255,0.96)", "text-halo-width": 1.4 }
  });

  map.addSource("nautical-reference", { type: "geojson", data: "/api/nautical", attribution: "OpenStreetMap contributors" });
  map.addLayer({
    id: "nautical-line",
    type: "line",
    source: "nautical-reference",
    filter: ["in", ["geometry-type"], ["literal", ["LineString", "Polygon"]]],
    paint: { "line-color": "#166b8c", "line-width": 1.4, "line-opacity": 0.9 }
  });
  map.addLayer({
    id: "nautical-point",
    type: "circle",
    source: "nautical-reference",
    filter: ["==", ["geometry-type"], "Point"],
    paint: { "circle-radius": 5, "circle-color": "#f5b23b", "circle-stroke-color": "#14536e", "circle-stroke-width": 1.5 }
  });
  map.addLayer({
    id: "nautical-label",
    type: "symbol",
    source: "nautical-reference",
    minzoom: 10,
    filter: ["==", ["geometry-type"], "Point"],
    layout: {
      "text-field": ["coalesce", ["get", "seamark:name"], ["get", "name"], ["get", "seamark:type"]],
      "text-font": ["Noto Sans Regular"],
      "text-size": 10,
      "text-offset": [0, 1.0],
      "text-anchor": "top"
    },
    paint: { "text-color": "#14536e", "text-halo-color": "rgba(255,255,255,0.96)", "text-halo-width": 1.2 }
  });

  const onlineRasterLayerIds = ["osm", "esri-imagery", "opentopomap"]
    .map((provider) => onlineProvider(provider).layerId)
    .filter((layerId) => map.getLayer(layerId));
  onlineRasterLayerIds.forEach((layerId) => {
    if (map.getLayer("weather-point")) map.moveLayer(layerId, "weather-point");
  });
  if (map.getLayer("local-osm-carto-raster")) {
    const onlineLayer = state.onlineVectorLayerIds.find((layerId) => map.getLayer(layerId))
      || onlineRasterLayerIds[0];
    map.moveLayer("local-osm-carto-raster", onlineLayer || "weather-point");
  }
  const worldVectorBaseLayerIds = new Set(["world-vector-landcover", "world-vector-park", "world-vector-water"]);
  const worldVectorOverlayLayerIds = worldVectorLayerIds.filter((layerId) => !worldVectorBaseLayerIds.has(layerId));
  const onlineLayerIds = new Set([
    ...state.onlineVectorLayerIds.filter((layerId) => map.getLayer(layerId)),
    ...onlineRasterLayerIds
  ]);
  const worldVectorOverlayAnchor = map.getStyle().layers.find((layer) => onlineLayerIds.has(layer.id))?.id
    || (map.getLayer("weather-point") ? "weather-point" : undefined);
  worldVectorOverlayLayerIds.forEach((layerId) => map.moveLayer(layerId, worldVectorOverlayAnchor));
  ["world-overview-raster", "world-country-fill", "world-place-labels", ...worldVectorLayerIds]
    .forEach((id) => state.layerGroups.set(id, ["overview"]));
  state.layerGroups.set("world-country-boundaries", ["overview", "boundaries"]);
  ["weather-point", "weather-label"].forEach((id) => state.layerGroups.set(id, ["weather"]));
  ["nautical-line", "nautical-point", "nautical-label"].forEach((id) => state.layerGroups.set(id, ["nautical"]));
  state.liveLayers?.ensureLayers();
  watchOnlineMapConnection(state.onlinePreferredProvider);
}

function weatherCodeLabel(code) {
  const value = Number(code);
  if (value === 0) return "晴";
  if ([1, 2, 3].includes(value)) return "多云";
  if ([45, 48].includes(value)) return "雾";
  if (value >= 51 && value <= 67) return "雨";
  if (value >= 71 && value <= 77) return "雪";
  if (value >= 80 && value <= 82) return "阵雨";
  if (value >= 95) return "雷雨";
  return "天气";
}

function showWeatherFeature(feature, lngLat) {
  const properties = feature.properties || {};
  const forecast = Array.isArray(properties.forecast) ? properties.forecast : featureObjectProperty(properties.forecast);
  const days = Array.isArray(forecast) ? forecast.slice(0, 7) : [];
  new maplibregl.Popup({ closeButton: true, maxWidth: "340px" })
    .setLngLat(lngLat)
    .setHTML(`<div class="popup-title">${escapeHtml(`${properties.province || ""}${properties.name || ""}`)}</div>
      <div class="popup-meta">${escapeHtml(weatherCodeLabel(properties.weatherCode))} · ${escapeHtml(properties.temperature)} °C · 体感 ${escapeHtml(properties.apparentTemperature)} °C</div>
      <div class="popup-note">湿度 ${escapeHtml(properties.humidity)}% · 风速 ${escapeHtml(properties.windSpeed)} km/h · 降水 ${escapeHtml(properties.precipitation)} mm<br>${days.map((day) => `${escapeHtml(day.date)} ${escapeHtml(weatherCodeLabel(day.weatherCode))} ${escapeHtml(day.temperatureMin)}–${escapeHtml(day.temperatureMax)} °C`).join("<br>")}<br>天气数据：Open-Meteo（本地快照）</div>`)
    .addTo(state.map);
}

function showNauticalFeature(feature, lngLat) {
  const properties = feature.properties || {};
  const name = properties["seamark:name"] || properties.name || properties["seamark:type"] || "航海地物";
  new maplibregl.Popup({ closeButton: true, maxWidth: "320px" })
    .setLngLat(lngLat)
    .setHTML(`<div class="popup-title">${escapeHtml(name)}</div><div class="popup-meta">${escapeHtml(properties["seamark:type"] || properties.man_made || properties.leisure || "航海参考")}</div><div class="popup-note">来源：OpenStreetMap 本地快照<br>仅供地图参考，不用于航行安全决策</div>`)
    .addTo(state.map);
}

function addPersonalLayers() {
  const map = state.map;
  addOfflineReferenceLayers();
  if (map.getSource("personal-places")) return;

  map.addSource("terrain-dem", {
    type: "raster-dem",
    tiles: [state.terrainDemSource.sharedDemProtocolUrl],
    tileSize: 256,
    minzoom: 5,
    maxzoom: 12,
    encoding: "terrarium"
  });
  map.addLayer({
    id: "terrain-hillshade",
    type: "hillshade",
    source: "terrain-dem",
    paint: {
      "hillshade-exaggeration": 0.42,
      "hillshade-shadow-color": "#4e554f",
      "hillshade-highlight-color": "#f7f5ed",
      "hillshade-accent-color": "#7b8179"
    }
  });

  map.addSource("terrain-contours", {
    type: "vector",
    tiles: [state.terrainDemSource.contourProtocolUrl({
      thresholds: {
        5: [500, 1000],
        7: [200, 1000],
        8: [100, 500],
        9: [50, 250],
        10: [20, 100],
        11: [10, 50]
      },
      contourLayer: "contours",
      elevationKey: "elevation",
      levelKey: "level",
      extent: 4096,
      buffer: 1
    })],
    maxzoom: 12
  });
  map.addLayer({
    id: "terrain-contour-lines",
    type: "line",
    source: "terrain-contours",
    "source-layer": "contours",
    minzoom: 5,
    layout: { "line-join": "round", "line-cap": "round" },
    paint: {
      "line-color": "#756149",
      "line-opacity": ["match", ["get", "level"], 1, 0.72, 0.48],
      "line-width": ["interpolate", ["linear"], ["zoom"], 5, ["match", ["get", "level"], 1, 0.9, 0.45], 12, ["match", ["get", "level"], 1, 1.35, 0.75]]
    }
  });
  map.addLayer({
    id: "terrain-contour-labels-minor",
    type: "symbol",
    source: "terrain-contours",
    "source-layer": "contours",
    minzoom: 9,
    filter: ["==", ["get", "level"], 0],
    layout: {
      "symbol-placement": "line",
      "symbol-spacing": ["interpolate", ["linear"], ["zoom"], 9, 520, 12, 420],
      "symbol-sort-key": 1,
      "text-field": ["concat", ["number-format", ["get", "elevation"], { "max-fraction-digits": 0 }], " m"],
      "text-font": ["Noto Sans Regular"],
      "text-size": ["interpolate", ["linear"], ["zoom"], 9, 7.5, 12, 8.5, 16, 9],
      "text-letter-spacing": 0.02,
      "text-keep-upright": true,
      "text-max-angle": 20,
      "text-padding": 7
    },
    paint: {
      "text-color": "#88755f",
      "text-opacity": ["interpolate", ["linear"], ["zoom"], 9, 0.52, 12, 0.68],
      "text-halo-color": "rgba(248,246,239,0.78)",
      "text-halo-width": 1
    }
  });
  map.addLayer({
    id: "terrain-contour-labels",
    type: "symbol",
    source: "terrain-contours",
    "source-layer": "contours",
    minzoom: 8,
    filter: [">", ["get", "level"], 0],
    layout: {
      "symbol-placement": "line",
      "symbol-spacing": 320,
      "symbol-sort-key": 0,
      "text-field": ["concat", ["number-format", ["get", "elevation"], { "max-fraction-digits": 0 }], " m"],
      "text-font": ["Noto Sans Regular"],
      "text-size": 10,
      "text-keep-upright": true,
      "text-max-angle": 25,
      "text-padding": 4
    },
    paint: {
      "text-color": "#68543c",
      "text-halo-color": "rgba(248,246,239,0.94)",
      "text-halo-width": 1.3
    }
  });

  map.addSource("personal-tracks", { type: "geojson", data: state.tracks });
  map.addLayer({
    id: "personal-track-halo",
    type: "line",
    source: "personal-tracks",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#ffffff", "line-width": ["interpolate", ["linear"], ["zoom"], 6, 4, 16, 9], "line-opacity": 0.86 }
  });
  map.addLayer({
    id: "personal-track",
    type: "line",
    source: "personal-tracks",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": ["coalesce", ["get", "color"], "#c94532"], "line-width": ["interpolate", ["linear"], ["zoom"], 6, 2, 16, 5.5] }
  });

  map.addSource("personal-places", { type: "geojson", data: state.places });
  map.addLayer({
    id: "personal-halo",
    type: "circle",
    source: "personal-places",
    paint: {
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 7, 13, 10, 17, 14],
      "circle-color": "rgba(201,69,50,0.16)",
      "circle-stroke-width": 1.5,
      "circle-stroke-color": "rgba(201,69,50,0.45)"
    }
  });
  map.addLayer({
    id: "personal-point",
    type: "circle",
    source: "personal-places",
    paint: {
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 4, 13, 6, 17, 8],
      "circle-color": ["match", ["get", "category"], "field", "#267352", "favorite", "#d18b23", "todo", "#c94532", "#2a6f9e"],
      "circle-stroke-width": 2,
      "circle-stroke-color": "#ffffff"
    }
  });
  map.addLayer({
    id: "personal-photo",
    type: "circle",
    source: "personal-places",
    filter: [">", ["to-number", ["coalesce", ["get", "media_count"], 0]], 0],
    paint: {
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 8, 3, 14, 5],
      "circle-color": "#ffffff",
      "circle-stroke-width": 2,
      "circle-stroke-color": "#266f9d"
    }
  });
  map.addLayer({
    id: "personal-label",
    type: "symbol",
    source: "personal-places",
    minzoom: 9,
    layout: {
      "text-field": ["get", "name"],
      "text-font": ["Noto Sans Regular"],
      "text-size": 12,
      "text-offset": [0, 1.25],
      "text-anchor": "top",
      "text-padding": 3
    },
    paint: { "text-color": "#43221f", "text-halo-color": "rgba(255,255,246,0.95)", "text-halo-width": 1.2 }
  });

  map.addSource("search-results", {
    type: "geojson",
    data: { type: "FeatureCollection", features: [] },
    cluster: true,
    clusterMaxZoom: 15,
    clusterRadius: 46
  });
  map.addLayer({
    id: "search-result-cluster",
    type: "circle",
    source: "search-results",
    filter: ["has", "point_count"],
    paint: {
      "circle-radius": ["step", ["get", "point_count"], 15, 10, 19, 30, 23],
      "circle-color": ["step", ["get", "point_count"], "#4d89ad", 10, "#2f759d", 30, "#1f5d82"],
      "circle-stroke-width": 3,
      "circle-stroke-color": "rgba(255,255,255,0.9)"
    }
  });
  map.addLayer({
    id: "search-result-cluster-count",
    type: "symbol",
    source: "search-results",
    filter: ["has", "point_count"],
    layout: {
      "text-field": ["get", "point_count_abbreviated"],
      "text-font": ["Noto Sans Regular"],
      "text-size": 11
    },
    paint: { "text-color": "#ffffff" }
  });
  map.addLayer({
    id: "search-result-halo",
    type: "circle",
    source: "search-results",
    filter: ["!", ["has", "point_count"]],
    paint: {
      "circle-radius": 12,
      "circle-color": "rgba(255,255,255,0.62)",
      "circle-stroke-width": 2,
      "circle-stroke-color": "rgba(38,111,157,0.34)"
    }
  });
  map.addLayer({
    id: "search-result-point",
    type: "circle",
    source: "search-results",
    filter: ["!", ["has", "point_count"]],
    paint: {
      "circle-radius": 6,
      "circle-color": ["case", ["==", ["get", "kind"], "reference"], "#266f9d", "#c94532"],
      "circle-stroke-width": 2,
      "circle-stroke-color": "#ffffff"
    }
  });
  map.addLayer({
    id: "search-result-label",
    type: "symbol",
    source: "search-results",
    minzoom: 8,
    filter: ["!", ["has", "point_count"]],
    layout: {
      "text-field": ["get", "name"],
      "text-font": ["Noto Sans Regular"],
      "text-size": 12,
      "text-offset": [0, 1.25],
      "text-anchor": "top",
      "text-padding": 4
    },
    paint: { "text-color": "#243a48", "text-halo-color": "rgba(255,255,246,0.96)", "text-halo-width": 1.4 }
  });

  map.addSource("emergency-places", {
    type: "geojson",
    data: { type: "FeatureCollection", features: [] },
    cluster: true,
    clusterMaxZoom: 14,
    clusterRadius: 42
  });
  map.addLayer({
    id: "emergency-cluster",
    type: "circle",
    source: "emergency-places",
    filter: ["has", "point_count"],
    paint: {
      "circle-radius": ["step", ["get", "point_count"], 14, 10, 18, 40, 22],
      "circle-color": "#b23b30",
      "circle-stroke-width": 3,
      "circle-stroke-color": "rgba(255,255,255,0.92)"
    }
  });
  map.addLayer({
    id: "emergency-cluster-count",
    type: "symbol",
    source: "emergency-places",
    filter: ["has", "point_count"],
    layout: { "text-field": ["get", "point_count_abbreviated"], "text-font": ["Noto Sans Regular"], "text-size": 11 },
    paint: { "text-color": "#ffffff" }
  });
  map.addLayer({
    id: "emergency-point",
    type: "circle",
    source: "emergency-places",
    filter: ["!", ["has", "point_count"]],
    paint: {
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 7, 4, 14, 7],
      "circle-color": ["match", ["get", "emergency_category"],
        "medical", "#c03b32", "security", "#245f91", "shelter", "#8c5d1f",
        "supplies", "#267352", "fuel", "#77518f", "#6c716d"],
      "circle-stroke-width": 2,
      "circle-stroke-color": "#ffffff"
    }
  });
  map.addLayer({
    id: "emergency-label",
    type: "symbol",
    source: "emergency-places",
    minzoom: 13,
    filter: ["!", ["has", "point_count"]],
    layout: {
      "text-field": ["get", "name"],
      "text-font": ["Noto Sans Regular"],
      "text-size": 11,
      "text-offset": [0, 1.15],
      "text-anchor": "top",
      "text-padding": 3
    },
    paint: { "text-color": "#4b2925", "text-halo-color": "rgba(255,255,246,0.96)", "text-halo-width": 1.3 }
  });

  map.addSource("selected-feature", {
    type: "geojson",
    data: { type: "FeatureCollection", features: [] }
  });
  map.addLayer({
    id: "selected-feature-halo",
    type: "circle",
    source: "selected-feature",
    paint: { "circle-radius": 14, "circle-color": "rgba(209,139,35,0.2)", "circle-stroke-width": 2, "circle-stroke-color": "#d18b23" }
  });
  map.addLayer({
    id: "selected-feature-point",
    type: "circle",
    source: "selected-feature",
    paint: { "circle-radius": 5, "circle-color": "#d18b23", "circle-stroke-width": 2, "circle-stroke-color": "#ffffff" }
  });

  map.addSource("active-route", {
    type: "geojson",
    data: { type: "FeatureCollection", features: [] }
  });
  map.addLayer({
    id: "active-route-halo",
    type: "line",
    source: "active-route",
    filter: ["==", ["geometry-type"], "LineString"],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "rgba(255,255,255,0.92)", "line-width": ["interpolate", ["linear"], ["zoom"], 6, 7, 16, 12] }
  });
  map.addLayer({
    id: "active-route-line",
    type: "line",
    source: "active-route",
    filter: ["==", ["geometry-type"], "LineString"],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#2679a6", "line-width": ["interpolate", ["linear"], ["zoom"], 6, 4, 16, 7] }
  });
  map.addLayer({
    id: "active-route-point",
    type: "circle",
    source: "active-route",
    filter: ["==", ["geometry-type"], "Point"],
    paint: {
      "circle-radius": 7,
      "circle-color": ["match", ["get", "point_type"], "start", "#267352", "#c94532"],
      "circle-stroke-width": 3,
      "circle-stroke-color": "#ffffff"
    }
  });

  map.addSource("measure", {
    type: "geojson",
    data: { type: "FeatureCollection", features: [] }
  });
  map.addLayer({
    id: "measure-fill",
    type: "fill",
    source: "measure",
    filter: ["==", ["geometry-type"], "Polygon"],
    paint: { "fill-color": "#267352", "fill-opacity": 0.18 }
  });
  map.addLayer({
    id: "measure-line",
    type: "line",
    source: "measure",
    filter: ["in", ["geometry-type"], ["literal", ["LineString", "Polygon"]]],
    paint: { "line-color": "#17211c", "line-width": 3, "line-dasharray": [2, 1.5] }
  });
  map.addLayer({
    id: "measure-points",
    type: "circle",
    source: "measure",
    paint: { "circle-radius": 4, "circle-color": "#ffffff", "circle-stroke-color": "#17211c", "circle-stroke-width": 2 }
  });

  state.layerGroups.set("terrain-hillshade", ["terrain"]);
  state.layerGroups.set("terrain-contour-lines", ["contours"]);
  state.layerGroups.set("terrain-contour-labels-minor", ["contours"]);
  state.layerGroups.set("terrain-contour-labels", ["contours"]);
  ["emergency-cluster", "emergency-cluster-count", "emergency-point", "emergency-label"].forEach((id) => {
    state.layerGroups.set(id, ["emergency"]);
  });
  ["personal-track-halo", "personal-track"].forEach((id) => state.layerGroups.set(id, ["personal", "tracks"]));
  ["personal-halo", "personal-point", "personal-label"].forEach((id) => state.layerGroups.set(id, ["personal", "personalPoints"]));
  state.layerGroups.set("personal-photo", ["personal", "photos"]);
  ["search-result-cluster", "search-result-cluster-count", "search-result-halo", "search-result-point", "search-result-label"]
    .forEach((id) => state.layerGroups.set(id, ["personal"]));
  applyLayerVisibility();
  applyPoiDensity();
  syncLocalBaseMapForViewport();
}

function coordinateSearchResult(query) {
  const match = query.trim().match(/^\s*(-?\d+(?:\.\d+)?)\s*[,，\s]\s*(-?\d+(?:\.\d+)?)\s*$/);
  if (!match) return null;
  let first = Number(match[1]);
  let second = Number(match[2]);
  if (Math.abs(first) <= 90 && Math.abs(second) > 90 && Math.abs(second) <= 180) [first, second] = [second, first];
  if (Math.abs(first) > 180 || Math.abs(second) > 90) return null;
  return { id: `coordinate:${first.toFixed(6)},${second.toFixed(6)}`, kind: "coordinate", name: `${first.toFixed(5)}, ${second.toFixed(5)}`, subtitle: "经纬度坐标", category: "coordinate", subtype: "", longitude: first, latitude: second, details: {} };
}

function localSearchExtras(query) {
  const normalized = query.trim().toLocaleLowerCase("zh-CN");
  if (!normalized) return [];
  const coordinate = coordinateSearchResult(query);
  const packs = state.mapPacks
    .filter((pack) => [pack.id, resourcePackName(pack), pack.name, pack.regionName].filter(Boolean).some((value) => String(value).toLocaleLowerCase("zh-CN").includes(normalized)))
    .slice(0, 6)
    .map((pack) => ({
      id: `region:${pack.id}`,
      kind: "region_pack",
      packId: pack.id,
      name: resourcePackName(pack),
      subtitle: pack.installed && pack.enabled !== false ? "区域包已安装并启用" : pack.installed ? "区域包已安装但已停用" : "可在资源管理中安装",
      category: "region",
      subtype: pack.installed ? "installed" : "available",
      longitude: (Number(pack.bounds?.[0]) + Number(pack.bounds?.[2])) / 2,
      latitude: (Number(pack.bounds?.[1]) + Number(pack.bounds?.[3])) / 2,
      details: { installed: Boolean(pack.installed), enabled: pack.enabled !== false }
    }))
    .filter((item) => Number.isFinite(item.longitude) && Number.isFinite(item.latitude));
  return [...(coordinate ? [coordinate] : []), ...packs];
}

async function unifiedSearch(query, limit = 30, options = {}) {
  const extras = localSearchExtras(query);
  const response = await api(`/search?q=${encodeURIComponent(query)}&limit=${Math.max(1, limit - extras.length)}`, options);
  const seen = new Set(extras.map((item) => `${item.kind}:${item.id}`));
  return [...extras, ...(response.results || []).filter((item) => !seen.has(`${item.kind}:${item.id}`))].slice(0, limit);
}

function searchResultSource(result) {
  if (result.kind === "personal_place") return { label: "个人点位", icon: "map-pin", tone: "personal" };
  if (result.kind === "personal_track") return { label: "轨迹记录", icon: "route", tone: "personal" };
  if (result.kind === "region_pack") return { label: result.details?.installed ? "区域包已安装" : "尚未安装该区域", icon: result.details?.installed ? "hard-drive" : "download", tone: result.details?.installed ? "offline" : "warning" };
  if (result.kind === "coordinate") return { label: "坐标", icon: "crosshair", tone: "neutral" };
  if (result.kind === "online") return { label: "在线补充", icon: "cloud", tone: "online" };
  const coverage = mapCoverageAt(Number(result.longitude), Number(result.latitude));
  if (!coverage.installed && coverage.available) return { label: "尚未安装该区域", icon: "download", tone: "warning" };
  if (result.kind === "geocoder") return { label: "离线地址", icon: "locate-fixed", tone: "offline" };
  return { label: "离线 OSM", icon: "hard-drive", tone: "offline" };
}

function closeSearchSuggestions() {
  clearTimeout(state.searchSuggestionTimer);
  state.searchSuggestionTimer = null;
  state.searchSuggestionRequestId += 1;
  state.searchSuggestionController?.abort();
  state.searchSuggestionController = null;
  elements.searchSuggestions.hidden = true;
  elements.searchInput.setAttribute("aria-expanded", "false");
}

function scheduleSearchSuggestions() {
  closeSearchSuggestions();
  const query = elements.searchInput.value.trim();
  if (!query) return;
  const requestId = state.searchSuggestionRequestId;
  state.searchSuggestionTimer = setTimeout(async () => {
    if (requestId !== state.searchSuggestionRequestId || elements.searchInput.value.trim() !== query) return;
    state.searchSuggestionTimer = null;
    const controller = new AbortController();
    state.searchSuggestionController = controller;
    const isCurrent = () => requestId === state.searchSuggestionRequestId && elements.searchInput.value.trim() === query;
    try {
      const results = await unifiedSearch(query, 9, { signal: controller.signal });
      if (isCurrent()) renderSearchSuggestions(results);
    } catch {
      if (isCurrent()) renderSearchSuggestions(localSearchExtras(query));
    } finally {
      if (state.searchSuggestionController === controller) state.searchSuggestionController = null;
    }
  }, 220);
}

function renderSearchSuggestions(results) {
  state.suggestionResults = results;
  elements.searchSuggestions.innerHTML = results.map((result) => {
    const source = searchResultSource(result);
    return `<button type="button" role="option" data-suggestion-id="${escapeHtml(result.id)}">
      <i data-lucide="${source.icon}"></i>
      <span><strong>${escapeHtml(result.name)}</strong><small>${escapeHtml(result.subtitle || categoryLabel(result.category, result.subtype))}</small></span>
      <em data-tone="${source.tone}">${escapeHtml(source.label)}</em>
    </button>`;
  }).join("");
  elements.searchSuggestions.hidden = results.length === 0;
  elements.searchInput.setAttribute("aria-expanded", String(results.length > 0));
  icons();
}

async function refreshData(query = state.searchQuery) {
  const [places, tracks, status, search, collections] = await Promise.all([
    api("/places.geojson"),
    api("/tracks.geojson"),
    api("/status"),
    query ? unifiedSearch(query, 30).then((results) => ({ results })) : Promise.resolve({ results: [] }),
    api("/collections")
  ]);
  state.places = places;
  state.tracks = tracks;
  state.collections = collections;
  state.searchResults = search.results || [];
  if (!query) {
    state.resultMode = null;
    state.resultLabel = "";
  }
  updateStatus(status);
  renderCollectionControls();
  updateListCaption();

  const placesSource = state.map.getSource("personal-places");
  const tracksSource = state.map.getSource("personal-tracks");
  if (placesSource) placesSource.setData(places);
  if (tracksSource) tracksSource.setData(tracks);
  updateSearchMap();
  renderPersonalList();
}

function updateSearchMap() {
  const source = state.map.getSource("search-results");
  if (!source) return;
  source.setData({
    type: "FeatureCollection",
    features: state.searchResults.map((result) => ({
      type: "Feature",
      properties: { id: result.id, kind: result.kind, name: result.name },
      geometry: { type: "Point", coordinates: [result.longitude, result.latitude] }
    }))
  });
}

function updateStatus(status) {
  state.serviceStatus = status;
  elements.placeCount.textContent = Number(status.places || 0).toLocaleString("zh-CN");
  elements.trackCount.textContent = Number(status.tracks || 0).toLocaleString("zh-CN");
  elements.mediaCount.textContent = Number(status.media || 0).toLocaleString("zh-CN");

  const dataset = status.reference_dataset || {};
  const sourceUpdatedAt = dataset.source_updated_at || state.datasetManifest?.source?.updatedAt;
  elements.mapSnapshot.textContent = formatDate(sourceUpdatedAt);
  const referenceCount = Number(dataset.record_count ?? status.reference_places ?? 0);
  elements.referenceCount.textContent = referenceCount
    ? `${referenceCount.toLocaleString("zh-CN")} 个地点`
    : "尚未建立";
  setStatusTone(elements.referenceCount, referenceCount ? "" : "warning");

  const backup = status.latest_backup;
  if (!backup) {
    elements.backupState.textContent = "尚未备份";
    setStatusTone(elements.backupState, "error");
  } else {
    const age = daysAgo(backup.created_at);
    elements.backupState.textContent = age === 0 ? "今天" : `${age} 天前`;
    if (backup.verified_manifest) elements.backupState.textContent += " · 含清单";
    setStatusTone(elements.backupState, age !== null && age > 7 ? "warning" : "");
  }
  const backupPolicy = status.backup_policy;
  if (!backupPolicy) {
    elements.backupPolicyState.textContent = "未安装定时任务";
    setStatusTone(elements.backupPolicyState, "error");
  } else if (backupPolicy.mirrorConfigured) {
    elements.backupPolicyState.textContent = `每日 ${backupPolicy.dailyAt} · 异盘`;
    setStatusTone(elements.backupPolicyState, "");
  } else {
    elements.backupPolicyState.textContent = `每日 ${backupPolicy.dailyAt} · 仅本机`;
    setStatusTone(elements.backupPolicyState, "warning");
  }
}

function updateCapabilities(capabilities) {
  state.capabilities = capabilities;
  const services = capabilities?.services || {};
  const setService = (element, service, ready = "可用") => {
    const available = Boolean(service?.available);
    const expanding = available && service?.coverageComplete === false;
    element.textContent = expanding ? "原范围可用 · 扩展中" : available ? ready : "构建中";
    setStatusTone(element, available && !expanding ? "" : "warning");
  };
  setService(elements.geocoderState, services.geocoder);
  setService(elements.routingState, services.routing);
  setService(elements.elevationState, services.elevation, `${Number(services.elevation?.files || 0)} 个格网`);
  setService(elements.encyclopediaState, services.encyclopedia);
  elements.encyclopediaLink.classList.toggle("disabled", !services.encyclopedia?.available);
  elements.encyclopediaLink.setAttribute("aria-disabled", String(!services.encyclopedia?.available));
  updateRouteCoverageStatus();
}

function renderPersonalList() {
  if (state.searchQuery || state.resultMode) {
    elements.personalList.innerHTML = state.searchResults.map((result) => {
      const source = searchResultSource(result);
      const subtitle = result.subtitle || categoryLabel(result.category, result.subtype);
      return `
        <button class="personal-item search-result" type="button" data-search-id="${escapeHtml(result.id)}">
          <span class="personal-icon ${source.tone === "personal" ? "track" : "reference"}">
            <i data-lucide="${source.icon}"></i>
          </span>
          <span class="personal-copy">
            <span class="result-title"><strong>${escapeHtml(result.name)}</strong><small data-tone="${source.tone}">${escapeHtml(source.label)}</small></span>
            <span>${escapeHtml(subtitle)}</span>
          </span>
          <i data-lucide="chevron-right"></i>
        </button>`;
    }).join("");
    const emptyTitle = elements.emptyState.querySelector("strong");
    const emptyMessage = elements.emptyState.querySelector("span");
    emptyTitle.textContent = "没有找到结果";
    emptyMessage.textContent = "换一个地名、设施名称或个人记录关键词试试。";
    elements.emptyState.hidden = state.searchResults.length > 0;
    icons();
    return;
  }

  const placeItems = state.places.features
    .filter((feature) => state.collectionFilter === "all"
      || featureCollections(feature.properties).some((collection) => collection.id === state.collectionFilter))
    .map((feature) => ({ kind: "place", feature }));
  const trackItems = state.collectionFilter === "all"
    ? state.tracks.features.map((feature) => ({ kind: "track", feature }))
    : [];
  let items = [...placeItems, ...trackItems];
  if (state.listFilter === "places") items = placeItems;
  if (state.listFilter === "tracks") items = trackItems;

  elements.personalList.innerHTML = items.map(({ kind, feature }) => {
    const props = feature.properties || {};
    const isTrack = kind === "track";
    const subtitle = isTrack
      ? `${props.activity || "轨迹"} · ${((Number(props.distance_m) || 0) / 1000).toFixed(1)} km`
      : [props.province, props.category].filter(Boolean).join(" · ") || "个人点位";
    return `
      <button class="personal-item" type="button" data-kind="${kind}" data-id="${escapeHtml(props.id)}">
        <span class="personal-icon ${isTrack ? "track" : ""}"><i data-lucide="${isTrack ? "route" : "map-pin"}"></i></span>
        <span class="personal-copy"><strong>${escapeHtml(props.name)}</strong><span>${escapeHtml(subtitle)}</span></span>
        <i data-lucide="chevron-right"></i>
      </button>`;
  }).join("");
  const emptyTitle = elements.emptyState.querySelector("strong");
  const emptyMessage = elements.emptyState.querySelector("span");
  emptyTitle.textContent = "还没有记录";
  emptyMessage.textContent = "从地图上添加点位，或导入一条 GPX 轨迹。";
  elements.emptyState.hidden = items.length > 0;
  icons();
}

function findFeature(kind, id) {
  const collection = kind === "track" ? state.tracks : state.places;
  return collection.features.find((feature) => String(feature.properties?.id) === String(id));
}

function featureCenter(feature) {
  if (feature.geometry.type === "Point") return feature.geometry.coordinates;
  const lines = feature.geometry.type === "LineString" ? [feature.geometry.coordinates] : feature.geometry.coordinates;
  const coordinates = lines.flat();
  const totals = coordinates.reduce((sum, coordinate) => [sum[0] + coordinate[0], sum[1] + coordinate[1]], [0, 0]);
  return [totals[0] / coordinates.length, totals[1] / coordinates.length];
}

function showListFeature(kind, id) {
  const feature = findFeature(kind, id);
  if (!feature) return;
  closeRoutePanel();
  const center = featureCenter(feature);
  state.map.flyTo({ center, zoom: kind === "place" ? 14 : 11, duration: 650 });
  if (kind === "place") showPersonalPlaceDetail(feature);
  else showTrackPopup(feature, center);
}

function showSearchResult(id) {
  const result = state.searchResults.find((item) => String(item.id) === String(id));
  if (!result) return;
  if (result.kind === "personal_place") {
    showListFeature("place", result.id);
    return;
  }
  if (result.kind === "personal_track") {
    showListFeature("track", result.id);
    return;
  }

  if (result.kind === "region_pack") {
    const pack = state.mapPacks.find((item) => item.id === result.packId);
    if (!pack) return;
    state.map.fitBounds([[Number(pack.bounds[0]), Number(pack.bounds[1])], [Number(pack.bounds[2]), Number(pack.bounds[3])]], { padding: 72, duration: 650 });
    showToast(pack.installed ? `${resourcePackName(pack)}已安装${pack.enabled === false ? "但当前停用" : "并可离线使用"}` : `${resourcePackName(pack)}尚未安装，可从资源管理下载`);
    closeSearchSuggestions();
    return;
  }

  closeRoutePanel();
  const center = [Number(result.longitude), Number(result.latitude)];
  state.map.flyTo({ center, zoom: 15, duration: 650 });
  const tags = result.details?.tags || {};
  const address = result.details?.address || {};
  const feature = {
    type: "Feature",
    properties: {
      ...tags,
      name: result.name,
      class: result.category,
      subclass: result.subtype,
      addr_full: result.subtitle,
      addr_province: address.province || address.state || tags["addr:province"],
      addr_city: address.city || address.town || tags["addr:city"]
    },
    layer: { "source-layer": result.kind === "coordinate" ? "place" : "poi_detail" },
    geometry: { type: "Point", coordinates: center }
  };
  const source = searchResultSource(result);
  showMapFeatureDetail(feature, center, {
    reference: result.kind === "coordinate" ? null : result,
    searchResult: result,
    eyebrow: source.label,
    sourceLabel: result.kind === "geocoder" ? "离线地址索引" : result.kind === "coordinate" ? "坐标定位" : source.label
  });
  closeSearchSuggestions();
}

function showPlacePopup(feature, lngLat) {
  const props = feature.properties || {};
  const collectionNames = featureCollections(props).map((collection) => collection.name);
  const popup = new maplibregl.Popup({ closeButton: true, maxWidth: "320px" })
    .setLngLat(lngLat)
    .setHTML(`
      <div class="popup-title">${escapeHtml(props.name || "未命名点位")}</div>
      <div class="popup-meta">${escapeHtml([props.province, props.category, ...collectionNames, `评分 ${props.rating || 0}`].filter(Boolean).join(" · "))}</div>
      <div class="popup-note">${escapeHtml(props.note || "暂无备注")}</div>
      <div class="popup-actions">
        <button type="button" data-popup-action="edit">编辑</button>
        <button type="button" data-popup-action="photo">添加照片</button>
        <button type="button" class="danger" data-popup-action="delete">删除</button>
      </div>`)
    .addTo(state.map);

  const root = popup.getElement();
  root.querySelector('[data-popup-action="edit"]').addEventListener("click", () => openPlaceDialog(feature));
  root.querySelector('[data-popup-action="photo"]').addEventListener("click", () => {
    state.activePhotoTarget = { kind: "personal", id: props.id };
    elements.photoInput.click();
  });
  root.querySelector('[data-popup-action="delete"]').addEventListener("click", async () => {
    if (!window.confirm(`删除点位“${props.name}”？`)) return;
    try {
      await api(`/places/${encodeURIComponent(props.id)}`, { method: "DELETE" });
      popup.remove();
      await refreshData();
      showToast("点位已删除");
    } catch (error) {
      showToast(error.message, true);
    }
  });
}

function showTrackPopup(feature) {
  showPersonalTrackDetail(feature);
}

function openTrackDialog(feature) {
  const props = feature.properties || {};
  elements.trackId.value = props.id || "";
  elements.trackVersion.value = props.version || "";
  elements.trackName.value = props.name || "";
  elements.trackActivity.value = props.activity || "other";
  elements.trackColor.value = props.color || "#c94532";
  elements.trackTags.value = featureTags(props).join(", ");
  elements.trackNote.value = props.note || "";
  elements.trackSummary.textContent = `${(Number(props.distance_m || 0) / 1000).toFixed(2)} km · 几何路线保持不变`;
  elements.trackDialog.showModal();
  elements.trackName.focus();
}

async function saveTrack(event) {
  event.preventDefault();
  const id = elements.trackId.value;
  const feature = state.tracks.features.find((item) => item.properties?.id === id);
  if (!feature) return;
  try {
    await api(`/tracks/${encodeURIComponent(id)}`, {
      method: "PUT",
      body: JSON.stringify({
        version: Number(elements.trackVersion.value),
        name: elements.trackName.value.trim(),
        activity: elements.trackActivity.value,
        color: elements.trackColor.value,
        tags: elements.trackTags.value.split(",").map((item) => item.trim()).filter(Boolean),
        note: elements.trackNote.value,
        geometry: feature.geometry
      })
    });
    elements.trackDialog.close();
    closeMapFeatureDetail();
    await refreshData();
    showToast("轨迹已更新");
  } catch (error) {
    showToast(error.message, true);
  }
}

function openPlaceDialog(featureOrCoordinate, options = {}) {
  const isFeature = featureOrCoordinate?.type === "Feature";
  const isEdit = isFeature && !options.copyAsNew;
  const props = isFeature ? featureOrCoordinate.properties : {};
  const coordinates = isFeature ? featureOrCoordinate.geometry.coordinates : featureOrCoordinate;
  elements.placeDialogTitle.textContent = isEdit ? "编辑点位" : options.copyAsNew ? "保存参考地点" : "添加点位";
  elements.placeId.value = isEdit ? props.id || "" : "";
  elements.placeVersion.value = isEdit ? props.version || "" : "";
  elements.placeName.value = props.name || "";
  elements.placeCategory.value = props.category || "todo";
  elements.placeProvince.value = props.province || "";
  elements.placeTags.value = featureTags(props).join(", ");
  elements.placeRating.value = props.rating || 0;
  elements.placeNote.value = props.note || "";
  const selectedCollections = options.collectionIds || featureCollections(props).map((collection) => collection.id);
  renderPlaceCollectionChoices(selectedCollections);
  elements.longitude.value = Number(coordinates[0]).toFixed(7);
  elements.latitude.value = Number(coordinates[1]).toFixed(7);
  elements.placeCoordinates.textContent = `${elements.longitude.value}, ${elements.latitude.value}`;
  elements.placeDialog.showModal();
  setTimeout(() => elements.placeName.focus(), 0);
}

async function savePlace(event) {
  event.preventDefault();
  const id = elements.placeId.value;
  const reopenDetail = id && state.selectedMapFeature?.kind === "personal"
    && String(state.selectedMapFeature.feature.properties.id) === String(id);
  const payload = {
    name: elements.placeName.value.trim(),
    province: elements.placeProvince.value.trim(),
    category: elements.placeCategory.value,
    note: elements.placeNote.value.trim(),
    tags: elements.placeTags.value.split(",").map((item) => item.trim()).filter(Boolean),
    collection_ids: Array.from(elements.placeCollectionChoices.querySelectorAll('input[type="checkbox"]:checked'))
      .map((input) => input.value),
    rating: Number(elements.placeRating.value) || 0,
    longitude: Number(elements.longitude.value),
    latitude: Number(elements.latitude.value)
  };
  if (id) payload.version = Number(elements.placeVersion.value);
  try {
    await api(id ? `/places/${encodeURIComponent(id)}` : "/places", {
      method: id ? "PUT" : "POST",
      body: JSON.stringify(payload)
    });
    elements.placeDialog.close();
    setMode(null);
    await refreshData();
    if (reopenDetail) {
      const updatedFeature = findFeature("place", id);
      if (updatedFeature) await showPersonalPlaceDetail(updatedFeature);
    } else if (state.selectedMapFeature?.kind === "base") {
      closeMapFeatureDetail();
    }
    showToast(id ? "点位已更新" : "点位已保存");
  } catch (error) {
    showToast(error.message, true);
  }
}

async function saveCollection(event) {
  event.preventDefault();
  const id = elements.collectionId.value;
  const payload = {
    name: elements.collectionName.value.trim(),
    color: elements.collectionColor.value,
    note: elements.collectionNote.value.trim()
  };
  try {
    await api(id ? `/collections/${encodeURIComponent(id)}` : "/collections", {
      method: id ? "PUT" : "POST",
      body: JSON.stringify(payload)
    });
    await refreshData();
    resetCollectionForm();
    showToast(id ? "集合已更新" : "集合已创建");
  } catch (error) {
    showToast(error.message, true);
  }
}

async function handleCollectionManagerClick(event) {
  const row = event.target.closest("[data-collection-id]");
  if (!row) return;
  const collection = state.collections.find((item) => item.id === row.dataset.collectionId);
  if (!collection) return;
  if (event.target.closest("[data-collection-edit]")) {
    elements.collectionId.value = collection.id;
    elements.collectionName.value = collection.name;
    elements.collectionColor.value = collection.color;
    elements.collectionNote.value = collection.note || "";
    elements.collectionName.focus();
    return;
  }
  if (event.target.closest("[data-collection-delete]")) {
    if (!window.confirm(`删除集合“${collection.name}”？点位本身不会删除。`)) return;
    try {
      await api(`/collections/${encodeURIComponent(collection.id)}`, { method: "DELETE" });
      await refreshData();
      resetCollectionForm();
      showToast("集合已删除");
    } catch (error) {
      showToast(error.message, true);
    }
  }
}

function haversine(a, b) {
  const radius = 6371008.8;
  const radians = (degrees) => degrees * Math.PI / 180;
  const lat1 = radians(a[1]);
  const lat2 = radians(b[1]);
  const deltaLat = lat2 - lat1;
  const deltaLon = radians(b[0] - a[0]);
  const value = Math.sin(deltaLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(deltaLon / 2) ** 2;
  return 2 * radius * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function polygonArea(coordinates) {
  if (coordinates.length < 3) return 0;
  const radius = 6371008.8;
  const radians = (degrees) => degrees * Math.PI / 180;
  let area = 0;
  coordinates.forEach((coordinate, index) => {
    const next = coordinates[(index + 1) % coordinates.length];
    area += radians(next[0] - coordinate[0]) * (2 + Math.sin(radians(coordinate[1])) + Math.sin(radians(next[1])));
  });
  return Math.abs(area * radius * radius / 2);
}

function createTerrainDemSource() {
  const source = new mlcontour.DemSource({
    url: `${window.location.origin}/api/terrain/{z}/{x}/{y}.png`,
    encoding: "terrarium",
    maxzoom: 12,
    worker: true,
    cacheSize: 128,
    timeoutMs: 60_000
  });
  source.setupMaplibre(maplibregl);
  return source;
}

function updateMeasure() {
  const source = state.map.getSource("measure");
  if (!source) return;
  const features = state.measureCoordinates.map((coordinate) => ({
    type: "Feature", properties: {}, geometry: { type: "Point", coordinates: coordinate }
  }));
  if (state.measureKind === "area" && state.measureCoordinates.length > 2) {
    features.unshift({
      type: "Feature", properties: {}, geometry: { type: "Polygon", coordinates: [[...state.measureCoordinates, state.measureCoordinates[0]]] }
    });
  } else if (state.measureCoordinates.length > 1) {
    features.unshift({
      type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: state.measureCoordinates }
    });
  }
  source.setData({ type: "FeatureCollection", features });
  const distance = state.measureCoordinates.slice(1).reduce(
    (total, coordinate, index) => total + haversine(state.measureCoordinates[index], coordinate), 0
  );
  if (state.mode === "measure-distance" || state.mode === "measure-area") {
    const area = polygonArea(state.measureCoordinates);
    elements.modeText.textContent = state.measureKind === "area"
      ? state.measureCoordinates.length > 2
        ? `测量面积：${area >= 1_000_000 ? `${(area / 1_000_000).toFixed(2)} km²` : `${area.toFixed(0)} m²`}`
        : "依次点击至少三个边界点测量面积"
      : state.measureCoordinates.length
        ? `测量距离：${distance >= 1000 ? `${(distance / 1000).toFixed(2)} km` : `${distance.toFixed(0)} m`}`
        : "依次点击地图测量距离，再次点击测距按钮清空";
  }
}

async function switchTheme(theme) {
  const normalizedTheme = theme === "osm-carto" ? "osm-carto" : "vector";
  // Theme choices are local base maps. An enabled online source sits above them,
  // so leave online mode before applying a local theme.
  if (state.onlineMapEnabled) setOnlineMapEnabled(false, false);
  state.theme = normalizedTheme;
  localStorage.setItem("terrasys-theme", normalizedTheme);
  document.querySelectorAll("[data-theme]").forEach((button) => {
    const active = button.dataset.theme === normalizedTheme;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  });
  const renderedIds = new Set(state.renderedPackIds);
  const renderedDatasets = renderingMapCatalog().datasets.filter((dataset) => renderedIds.has(dataset.id));
  const generated = window.TerraSysMapStyle.create(mapStyleCatalog(renderedDatasets), normalizedTheme);
  generated.style.layers.forEach((layer) => {
    if (!state.map.getLayer(layer.id)) return;
    Object.entries(layer.paint || {}).forEach(([property, value]) => {
      state.map.setPaintProperty(layer.id, property, value);
    });
    Object.entries(layer.layout || {}).forEach(([property, value]) => {
      state.map.setLayoutProperty(layer.id, property, value);
    });
    if (layer.filter) state.map.setFilter(layer.id, layer.filter);
    state.map.setLayerZoomRange(layer.id, layer.minzoom ?? 0, layer.maxzoom ?? 24);
  });
  const onlineVectorStyle = createOnlineVectorStyle(normalizedTheme);
  onlineVectorStyle?.style.layers.forEach((layer) => {
    if (!state.map.getLayer(layer.id)) return;
    Object.entries(layer.paint || {}).forEach(([property, value]) => {
      state.map.setPaintProperty(layer.id, property, value);
    });
    Object.entries(layer.layout || {}).forEach(([property, value]) => {
      state.map.setLayoutProperty(layer.id, property, value);
    });
    if (layer.filter) state.map.setFilter(layer.id, layer.filter);
    state.map.setLayerZoomRange(layer.id, layer.minzoom ?? 0, layer.maxzoom ?? 24);
  });
  const localBase = syncLocalBaseMapForViewport();
  syncMapShortcuts();
  showToast(normalizedTheme === "osm-carto"
    ? localBase.mode === "vector-fallback"
      ? `${resourcePackName(localBase.pack)}的 OSM 原版正在后台同步，当前继续使用交互矢量`
      : "已切换到本地 OSM 原版渲染"
    : "已切换到交互矢量地图");
}

async function checkServices(knownPackStatus = null) {
  try {
    const [apiStatus, martinResponse, packStatus, capabilities] = await Promise.all([
      api("/status"),
      fetch("/martin/catalog", { cache: "no-store" }),
      knownPackStatus ? Promise.resolve(knownPackStatus) : api("/map-packs"),
      api("/capabilities")
    ]);
    if (!martinResponse.ok) throw new Error("Martin unavailable");
    elements.dbState.textContent = "正常";
    elements.martinState.textContent = "正常";
    elements.systemState.textContent = "本地在线";
    elements.systemState.classList.remove("error");
    state.mapPacks = packStatus.packs;
    state.osmCartoPackIds = packStatus.osmCartoPackIds;
    syncInstalledCatalogDatasets();
    if (!state.mapPacks.some((pack) => pack.id === state.activePackId && pack.installed)) {
      state.activePackId = state.mapPacks.find((pack) => pack.installed)?.id || state.activePackId;
      renderViewSwitcher();
    }
    renderRegionPacks();
    if (!syncMapStyleForInstalledPacks()) syncLocalBaseMapForViewport();
    updateCoveragePrompt();
    updateStatus(apiStatus);
    updateCapabilities(capabilities);
  } catch {
    elements.dbState.textContent = "异常";
    elements.martinState.textContent = "异常";
    elements.systemState.textContent = "服务异常";
    elements.systemState.classList.add("error");
  }
}

function setSidePanelCollapsed(collapsed, refreshCoverage = true) {
  document.body.classList.toggle("panel-collapsed", collapsed);
  elements.sidePanel.inert = collapsed;
  elements.sidePanel.setAttribute("aria-hidden", String(collapsed));
  elements.panelToggle.title = collapsed ? "展开侧栏" : "收起侧栏";
  elements.panelToggle.setAttribute("aria-label", elements.panelToggle.title);
  elements.panelToggle.setAttribute("aria-expanded", String(!collapsed));
  elements.panelToggle.innerHTML = `<i data-lucide="${collapsed ? "panel-left-open" : "panel-left-close"}"></i>`;
  icons();
  if (refreshCoverage) window.setTimeout(() => updateCoveragePrompt(), 200);
}

function wireUi() {
  elements.panelToggle.addEventListener("click", () => {
    setSidePanelCollapsed(!document.body.classList.contains("panel-collapsed"));
  });

  elements.onlineMapShortcut.addEventListener("click", () => setMapSourceOpen(elements.mapSourcePopover.hidden));
  elements.mapSourceCloseButton.addEventListener("click", () => setMapSourceOpen(false));
  elements.layersShortcut.addEventListener("click", () => setLayersOpen(elements.layersPopover.hidden));
  elements.layersCloseButton.addEventListener("click", () => setLayersOpen(false));
  elements.liveLayersShortcut.addEventListener("click", () => setLiveLayersOpen(elements.liveLayersPopover.hidden));
  elements.liveLayersCloseButton.addEventListener("click", () => setLiveLayersOpen(false));
  elements.coverageDownloadButton.addEventListener("click", () => {
    const packId = state.coveragePromptPackId;
    if (!packId) return;
    state.coveragePromptPinnedId = null;
    state.coveragePromptPinnedUntil = 0;
    window.location.href = `/resources.html?pack=${encodeURIComponent(packId)}`;
  });
  elements.coverageCloseButton.addEventListener("click", () => {
    state.coveragePromptDismissedId = state.coveragePromptPackId;
    state.coveragePromptPinnedId = null;
    state.coveragePromptPinnedUntil = 0;
    elements.coveragePrompt.hidden = true;
    syncMapSourceControl();
  });
  elements.legendShortcut.addEventListener("click", () => {
    setLegendOpen(elements.legendPopover.hidden);
  });
  elements.legendCloseButton.addEventListener("click", () => setLegendOpen(false));
  document.addEventListener("click", (event) => {
    if (!elements.legendPopover.hidden && !elements.mapShortcuts.contains(event.target)) {
      setLegendOpen(false);
    }
    if (!elements.mapSourcePopover.hidden && !elements.mapShortcuts.contains(event.target)) {
      setMapSourceOpen(false);
    }
    if (!elements.layersPopover.hidden && !elements.mapShortcuts.contains(event.target)) {
      setLayersOpen(false);
    }
    if (!elements.liveLayersPopover.hidden && !elements.mapShortcuts.contains(event.target)) {
      setLiveLayersOpen(false);
    }
    if (!elements.searchSuggestions.hidden && !elements.searchForm.contains(event.target)) closeSearchSuggestions();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      setMapSourceOpen(false);
      setLayersOpen(false);
      setLiveLayersOpen(false);
      closeSearchSuggestions();
    }
  });

  elements.availablePacksButton.addEventListener("click", () => {
    window.location.href = "/resources.html";
  });
  document.querySelectorAll("[data-resource-manager-close]").forEach((button) => {
    button.addEventListener("click", () => elements.resourceManagerDialog.close());
  });
  elements.resourceManagerDialog.addEventListener("close", stopMaintenancePolling);
  document.querySelectorAll("[data-resource-tab]").forEach((button) => {
    button.addEventListener("click", () => {
      state.resourceTab = button.dataset.resourceTab;
      renderResourceManager();
    });
  });
  elements.resourceRefreshButton.addEventListener("click", () => {
    loadResourceInventory(true);
    loadMaintenanceStatus(true);
  });
  elements.resourceSearchInput.addEventListener("input", () => {
    state.resourceQuery = elements.resourceSearchInput.value;
    renderResourceManager();
  });
  elements.resourceRegionList.addEventListener("click", (event) => {
    const regionButton = event.target.closest("[data-resource-region]");
    if (!regionButton) return;
    state.resourceRegionId = regionButton.dataset.resourceRegion;
    state.resourceQuery = "";
    elements.resourceSearchInput.value = "";
    renderResourceManager();
    elements.resourceManagerContent.scrollTop = 0;
  });
  elements.resourceManagerContent.addEventListener("click", (event) => {
    const cancelButton = event.target.closest("[data-maintenance-cancel]");
    if (cancelButton) {
      cancelMaintenanceJob(cancelButton.dataset.maintenanceCancel);
      return;
    }
    const retryButton = event.target.closest("[data-maintenance-retry]");
    if (retryButton) {
      retryMaintenanceJob(retryButton.dataset.maintenanceRetry);
      return;
    }
    const resourceAction = event.target.closest("[data-resource-action]");
    if (resourceAction) {
      useResourceAction(resourceAction.dataset.resourceAction);
      return;
    }
    const regionButton = event.target.closest("[data-resource-region]");
    if (regionButton) {
      state.resourceRegionId = regionButton.dataset.resourceRegion;
      state.resourceQuery = "";
      elements.resourceSearchInput.value = "";
      renderResourceManager();
      elements.resourceManagerContent.scrollTop = 0;
      return;
    }
    const buildButton = event.target.closest("[data-resource-pack-job]");
    if (buildButton) {
      queueMaintenanceJob(buildButton.dataset.resourcePackJob, buildButton.dataset.resourcePackAction || "build");
      return;
    }
    const locateButton = event.target.closest("[data-resource-pack-locate]");
    if (locateButton) {
      locateRegionPack(locateButton.dataset.resourcePackLocate);
      return;
    }
    const installButton = event.target.closest("[data-resource-install]");
    if (installButton) {
      queueMaintenanceJob(installButton.dataset.resourceInstall, "update");
      return;
    }
    const verifyButton = event.target.closest("[data-resource-pack-verify]");
    if (verifyButton) {
      verifyRegionPack(verifyButton.dataset.resourcePackVerify);
      return;
    }
    const removeButton = event.target.closest("[data-resource-pack-remove]");
    if (removeButton) {
      protectedRemovePacks([removeButton.dataset.resourcePackRemove]);
      return;
    }
    const menuButton = event.target.closest("[data-resource-pack-menu]");
    if (menuButton) {
      state.resourceMenuPackId = state.resourceMenuPackId === menuButton.dataset.resourcePackMenu ? null : menuButton.dataset.resourcePackMenu;
      renderResourceManager();
      return;
    }
    const packCommand = event.target.closest("[data-resource-pack-command]");
    if (packCommand) {
      const packId = packCommand.dataset.packId;
      const pack = state.mapPacks.find((item) => item.id === packId);
      state.resourceMenuPackId = null;
      if (packCommand.dataset.resourcePackCommand === "info") {
        state.resourceTab = "download";
        state.resourceRegionId = `pack:${packId}`;
        renderResourceManager();
      } else if (packCommand.dataset.resourcePackCommand === "verify") verifyRegionPack(packId);
      else if (packCommand.dataset.resourcePackCommand === "manifest") exportRegionPackManifest(packId);
      else if (packCommand.dataset.resourcePackCommand === "toggle") setRegionPackEnabled(packId, pack?.enabled === false);
      else if (packCommand.dataset.resourcePackCommand === "rebuild") queueMaintenanceJob(packId, "rebuild");
      else if (packCommand.dataset.resourcePackCommand === "open") {
        elements.resourceManagerDialog.close();
        activateRegionPack(packId);
      } else if (packCommand.dataset.resourcePackCommand === "remove") protectedRemovePacks([packId]);
      return;
    }
    const bulkButton = event.target.closest("[data-resource-bulk]");
    if (bulkButton) {
      runResourceBulkAction(bulkButton.dataset.resourceBulk);
      return;
    }
    const cacheButton = event.target.closest("[data-resource-cache-clear]");
    if (cacheButton) {
      clearRegenerableCache(cacheButton.dataset.resourceCacheClear);
      return;
    }
    const openButton = event.target.closest("[data-resource-pack-open]");
    if (openButton) {
      elements.resourceManagerDialog.close();
      activateRegionPack(openButton.dataset.resourcePackOpen);
      return;
    }
    const updateButton = event.target.closest("[data-resource-update-now]");
    if (updateButton) {
      const item = state.resourceInventory?.updateChecks?.find((check) => check.id === updateButton.dataset.resourceUpdateNow);
      if (item?.heavy && !window.confirm(`${item.name}需要重建共享搜索与路线索引，可能持续数小时。确认加入队列吗？`)) return;
      queueMaintenanceJob(updateButton.dataset.resourceUpdateNow, updateButton.dataset.resourceUpdateAction || "update");
      return;
    }
    if (event.target.closest("[data-resource-update-all]")) queueRegularUpdates();
  });
  elements.resourceManagerContent.addEventListener("change", (event) => {
    const selectAll = event.target.closest("[data-resource-select-all]");
    if (selectAll) {
      state.selectedResourcePackIds.clear();
      if (selectAll.checked) state.mapPacks.filter((pack) => pack.installed).forEach((pack) => state.selectedResourcePackIds.add(pack.id));
      renderResourceManager();
      return;
    }
    const packSelect = event.target.closest("[data-resource-pack-select]");
    if (packSelect) {
      if (packSelect.checked) state.selectedResourcePackIds.add(packSelect.dataset.resourcePackSelect);
      else state.selectedResourcePackIds.delete(packSelect.dataset.resourcePackSelect);
      renderResourceManager();
      return;
    }
    const toggle = event.target.closest("[data-resource-auto-toggle]");
    if (toggle) {
      setAutomaticUpdates(toggle.checked);
      return;
    }
    const resourceToggle = event.target.closest("[data-resource-auto-resource]");
    if (resourceToggle) setAutomaticUpdates(resourceToggle.checked, resourceToggle.dataset.resourceAutoResource);
  });

  document.querySelectorAll("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll("[data-tab]").forEach((item) => item.classList.toggle("active", item === button));
      document.querySelectorAll("[data-tab-panel]").forEach((panel) => panel.classList.toggle("active", panel.dataset.tabPanel === button.dataset.tab));
    });
  });

  elements.searchForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    state.searchQuery = elements.searchInput.value.trim();
    state.resultMode = null;
    state.resultLabel = "";
    closeSearchSuggestions();
    try {
      await refreshData();
      document.querySelector('[data-tab="personal"]').click();
    } catch (error) {
      showToast(error.message, true);
    }
  });

  elements.searchInput.addEventListener("input", scheduleSearchSuggestions);
  elements.searchSuggestions.addEventListener("click", (event) => {
    const button = event.target.closest("[data-suggestion-id]");
    if (!button) return;
    state.searchQuery = elements.searchInput.value.trim();
    state.resultMode = null;
    state.searchResults = state.suggestionResults;
    updateSearchMap();
    renderPersonalList();
    showSearchResult(button.dataset.suggestionId);
  });

  elements.searchInput.addEventListener("search", async () => {
    if (elements.searchInput.value) return;
    closeSearchSuggestions();
    state.searchQuery = "";
    state.resultMode = null;
    state.resultLabel = "";
    try {
      await refreshData();
    } catch (error) {
      showToast(error.message, true);
    }
  });

  elements.addPlaceButton.addEventListener("click", () => setMode(state.mode === "add-place" ? null : "add-place"));
  elements.importGpxButton.addEventListener("click", () => elements.gpxInput.click());
  elements.routeButton.addEventListener("click", () => {
    if (elements.routePanel.hidden) openRoutePanel();
    else closeRoutePanel();
  });
  elements.measureButton.addEventListener("click", () => startMeasure("distance"));
  elements.cancelModeButton.addEventListener("click", () => setMode(null));
  elements.routeCloseButton.addEventListener("click", closeRoutePanel);
  elements.routeClearButton.addEventListener("click", clearRoute);
  elements.routeSpeakButton.addEventListener("click", speakRoute);
  elements.routeSaveButton.addEventListener("click", saveRouteTrack);
  elements.routeSwapButton.addEventListener("click", swapRouteLocations);
  elements.routeLocationButton.addEventListener("click", useCurrentRouteLocation);
  elements.routeRecentList.addEventListener("click", (event) => {
    const button = event.target.closest("[data-route-recent]");
    if (!button) return;
    const recent = routeRecentLocations()[Number(button.dataset.routeRecent)];
    if (!recent) return;
    const targetIndex = state.route.locations[0] ? 1 : 0;
    setRouteLocation(targetIndex, [recent.longitude, recent.latitude], recent.name);
  });
  document.querySelectorAll("[data-route-search]").forEach((button) => {
    button.addEventListener("click", () => searchRouteLocation(Number(button.dataset.routeSearch)));
  });
  [elements.routeStartLabel, elements.routeEndLabel].forEach((input, index) => {
    input.addEventListener("input", () => editRouteLocation(index));
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); searchRouteLocation(index); }
    });
  });
  document.querySelectorAll("[data-route-point]").forEach((button) => {
    button.addEventListener("click", () => setMode(button.dataset.routePoint === "0" ? "route-start" : "route-end"));
  });
  document.querySelectorAll("[data-route-costing]").forEach((button) => {
    button.addEventListener("click", () => setRouteCosting(button.dataset.routeCosting));
  });

  document.querySelectorAll("[data-dialog-close]").forEach((button) => {
    button.addEventListener("click", () => {
      elements.placeDialog.close();
      setMode(null);
    });
  });
  elements.placeDialog.addEventListener("cancel", () => setMode(null));
  elements.placeForm.addEventListener("submit", savePlace);
  elements.trackForm.addEventListener("submit", saveTrack);
  document.querySelectorAll("[data-track-close]").forEach((button) => button.addEventListener("click", () => elements.trackDialog.close()));
  elements.collectionFilter.addEventListener("change", () => {
    state.collectionFilter = elements.collectionFilter.value;
    state.listFilter = "all";
    updateListCaption();
    renderPersonalList();
  });
  elements.manageCollectionsButton.addEventListener("click", () => {
    renderCollectionControls();
    resetCollectionForm();
    elements.collectionDialog.showModal();
  });
  elements.collectionForm.addEventListener("submit", saveCollection);
  elements.collectionManagerList.addEventListener("click", handleCollectionManagerClick);
  document.querySelectorAll("[data-collection-close]").forEach((button) => {
    button.addEventListener("click", () => elements.collectionDialog.close());
  });
  document.querySelectorAll("[data-collection-new]").forEach((button) => {
    button.addEventListener("click", resetCollectionForm);
  });
  elements.detailCloseButton.addEventListener("click", closeMapFeatureDetail);
  elements.detailNearbyButton.addEventListener("click", showNearbyResults);
  elements.detailRouteButton.addEventListener("click", routeToSelectedFeature);
  elements.detailSaveButton.addEventListener("click", saveSelectedMapFeature);
  elements.detailDeleteButton.addEventListener("click", deleteSelectedPersonalRecord);
  elements.detailAddPhotoButton.addEventListener("click", () => {
    if (!["personal", "track"].includes(state.selectedMapFeature?.kind)) return;
    state.activePhotoTarget = { kind: state.selectedMapFeature.kind, id: state.selectedMapFeature.feature.properties.id };
    elements.photoInput.click();
  });
  elements.detailMediaGrid.addEventListener("click", handleDetailMediaClick);
  elements.detailPersonalLinks.addEventListener("click", (event) => {
    const button = event.target.closest("[data-detail-personal]");
    if (button) showListFeature(button.dataset.detailPersonal, button.dataset.detailId);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !elements.legendPopover.hidden) {
      setLegendOpen(false);
      elements.legendShortcut.focus();
    } else if (event.key === "Escape" && !elements.detailPanel.hidden && !elements.placeDialog.open) {
      closeMapFeatureDetail();
    } else if (event.key === "Escape" && !elements.routePanel.hidden && !elements.placeDialog.open) {
      closeRoutePanel();
    }
  });

  elements.gpxInput.addEventListener("change", async () => {
    const file = elements.gpxInput.files[0];
    if (!file) return;
    const form = new FormData();
    form.append("file", file);
    try {
      const result = await api("/imports/gpx", { method: "POST", body: form });
      await refreshData();
      showToast(`已导入 ${result.count} 条轨迹`);
    } catch (error) {
      showToast(error.message, true);
    } finally {
      elements.gpxInput.value = "";
    }
  });

  elements.photoInput.addEventListener("change", async () => {
    const file = elements.photoInput.files[0];
    if (!file || !state.activePhotoTarget) return;
    const target = state.activePhotoTarget;
    const form = new FormData();
    form.append("file", file);
    try {
      const parameter = target.kind === "track" ? "track_id" : "place_id";
      await api(`/media?${parameter}=${encodeURIComponent(target.id)}`, { method: "POST", body: form });
      await checkServices();
      if (state.selectedMapFeature?.kind === target.kind && state.selectedMapFeature.feature.properties.id === target.id) {
        await loadPersonalMedia(target.kind, target.id);
      }
      showToast("照片已保存到本地资料库");
    } catch (error) {
      showToast(error.message, true);
    } finally {
      elements.photoInput.value = "";
      state.activePhotoTarget = null;
    }
  });

  document.querySelectorAll("[data-layer-toggle]").forEach((input) => {
    input.addEventListener("change", () => {
      setLayerGroupVisibility(input.dataset.layerToggle, input.checked);
    });
  });
  document.querySelectorAll("[data-poi-density]").forEach((button) => button.addEventListener("click", () => setPoiDensity(button.dataset.poiDensity)));
  document.querySelectorAll("[data-map-light]").forEach((button) => button.addEventListener("click", () => setMapLight(button.dataset.mapLight)));
  document.querySelectorAll("[data-scale-unit]").forEach((button) => button.addEventListener("click", () => setScaleUnit(button.dataset.scaleUnit)));
  elements.emergencyFilters.addEventListener("change", updateEmergencyLayer);

  document.querySelectorAll("[data-theme]").forEach((button) => {
    button.addEventListener("click", () => {
      switchTheme(button.dataset.theme).catch((error) => showToast(error.message, true));
      if (elements.mapSourcePopover.contains(button)) setMapSourceOpen(false);
    });
  });
  document.querySelectorAll("[data-online-provider]").forEach((button) => {
    button.addEventListener("click", () => {
      setOnlineMapProvider(button.dataset.onlineProvider);
      if (elements.mapSourcePopover.contains(button)) setMapSourceOpen(false);
    });
  });

  elements.viewSwitcher?.addEventListener("click", (event) => {
    const button = event.target.closest("[data-view]");
    if (!button) return;
    const view = installedRegionViews().find((item) => item.key === button.dataset.view);
    if (!view) return;
    state.viewPackId = view.packId;
    if (view.packId !== "all") {
      state.activePackId = view.packId;
      localStorage.setItem("terrasys-active-pack", view.packId);
    }
    renderViewSwitcher();
    renderRegionPacks();
    const leftPadding = document.body.classList.contains("panel-collapsed") ? 72 : 400;
    state.map.fitBounds(view.bounds, {
      padding: { top: 80, right: 72, bottom: 72, left: leftPadding },
      duration: 650
    });
  });

  elements.regionPackList.addEventListener("click", (event) => {
    const verifyButton = event.target.closest("[data-pack-verify]");
    if (verifyButton) {
      verifyRegionPack(verifyButton.dataset.packVerify);
      return;
    }
    const openButton = event.target.closest("[data-pack-open]");
    if (openButton) activateRegionPack(openButton.dataset.packOpen);
  });

  document.querySelectorAll("[data-list-filter]").forEach((button) => {
    button.addEventListener("click", () => {
      state.listFilter = state.listFilter === button.dataset.listFilter ? "all" : button.dataset.listFilter;
      renderPersonalList();
    });
  });

  elements.personalList.addEventListener("click", (event) => {
    const searchButton = event.target.closest("[data-search-id]");
    if (searchButton) {
      showSearchResult(searchButton.dataset.searchId);
      return;
    }
    const button = event.target.closest("[data-id]");
    if (button) showListFeature(button.dataset.kind, button.dataset.id);
  });
}

function wireMap() {
  const map = state.map;
  map.on("style.load", async () => {
    addPersonalLayers();
    state.liveLayers?.ensureLayers();
    state.liveLayers?.refreshVisible(true);
    syncMapPackLayerVisibilityForViewport();
    if (state.selectedMapFeature) setSelectedFeatureMarker(state.selectedMapFeature.coordinate);
    updateRouteSource();
    if (state.layerVisibility.emergency) updateEmergencyLayer();
    try {
      await refreshData();
    } catch (error) {
      showToast(error.message, true);
    }
  });
  map.on("load", () => {
    syncMapPackLayerVisibilityForViewport();
    syncLocalBaseMapForViewport();
    updateCoveragePrompt();
  });

  map.on("mousemove", (event) => {
    elements.coordinateReadout.textContent = `${event.lngLat.lng.toFixed(5)}, ${event.lngLat.lat.toFixed(5)}`;
    if (!state.mode) {
      const topLayer = map.queryRenderedFeatures(event.point)[0]?.layer?.id || "";
      const overlayInteractive = ["personal-point", "personal-track", "search-result-point", "search-result-cluster", "emergency-point", "emergency-cluster", "weather-point", "nautical-point", "nautical-line"]
        .includes(topLayer) || topLayer.startsWith("live-");
      map.getCanvas().style.cursor = overlayInteractive || selectableBaseFeature(event.point) ? "pointer" : "";
    }
  });

  map.on("click", (event) => {
    if (state.mode === "route-start" || state.mode === "route-end") {
      setRouteLocation(state.mode === "route-start" ? 0 : 1, [event.lngLat.lng, event.lngLat.lat]);
      return;
    }
    if (state.mode === "add-place") {
      openPlaceDialog([event.lngLat.lng, event.lngLat.lat]);
      return;
    }
    if (state.mode === "measure-distance" || state.mode === "measure-area") {
      state.measureCoordinates.push([event.lngLat.lng, event.lngLat.lat]);
      updateMeasure();
      return;
    }
    if (state.liveLayers?.featureAtPoint(event.point)) return;
    const feature = selectableBaseFeature(event.point);
    if (feature) showMapFeatureDetail(feature, [event.lngLat.lng, event.lngLat.lat]);
    else updateCoveragePrompt(event.lngLat, true);
  });

  map.on("click", "personal-point", (event) => {
    if (state.mode) return;
    showPersonalPlaceDetail(event.features[0]);
  });
  map.on("click", "personal-photo", (event) => {
    if (state.mode) return;
    showPersonalPlaceDetail(event.features[0]);
  });
  map.on("click", "personal-track", (event) => {
    if (state.mode) return;
    showTrackPopup(event.features[0]);
  });
  map.on("click", "search-result-point", (event) => {
    if (state.mode) return;
    showSearchResult(event.features[0].properties.id);
  });
  map.on("click", "search-result-cluster", async (event) => {
    if (state.mode) return;
    const clusterId = event.features[0].properties.cluster_id;
    const source = map.getSource("search-results");
    try {
      const zoom = await source.getClusterExpansionZoom(clusterId);
      map.easeTo({ center: event.features[0].geometry.coordinates, zoom, duration: 500 });
    } catch (error) {
      showToast(error.message, true);
    }
  });
  map.on("click", "emergency-point", (event) => {
    if (state.mode) return;
    showEmergencyFeature(event.features[0], event.lngLat);
  });
  map.on("click", "weather-point", (event) => {
    if (state.mode) return;
    showWeatherFeature(event.features[0], event.lngLat);
  });
  ["nautical-point", "nautical-line"].forEach((layerId) => {
    map.on("click", layerId, (event) => {
      if (state.mode) return;
      showNauticalFeature(event.features[0], event.lngLat);
    });
  });
  map.on("click", "emergency-cluster", async (event) => {
    if (state.mode) return;
    const clusterId = event.features[0].properties.cluster_id;
    const source = map.getSource("emergency-places");
    try {
      const zoom = await source.getClusterExpansionZoom(clusterId);
      map.easeTo({ center: event.features[0].geometry.coordinates, zoom, duration: 500 });
    } catch (error) {
      showToast(error.message, true);
    }
  });

  ["personal-point", "personal-photo", "personal-track", "search-result-point", "search-result-cluster", "emergency-point", "emergency-cluster", "weather-point", "nautical-point", "nautical-line"].forEach((layerId) => {
    map.on("mouseenter", layerId, () => {
      if (!state.mode) map.getCanvas().style.cursor = "pointer";
    });
    map.on("mouseleave", layerId, () => {
      if (!state.mode) map.getCanvas().style.cursor = "";
    });
  });

  map.on("error", (event) => {
    const message = event?.error?.message || "";
    if (message.includes("pmtiles")) showToast("本地瓦片加载失败，请运行健康检查", true);
    const failedProvider = onlineMapProviders.find((provider) => {
      const sourceId = onlineProvider(provider).sourceId;
      if (event?.sourceId === sourceId) return true;
      if (provider === "osm") return message.includes("tile.openstreetmap.org");
      if (provider === "openfreemap") return message.includes("tiles.openfreemap.org");
      if (provider === "esri-imagery") return message.includes("services.arcgisonline.com");
      return provider === "opentopomap" && message.includes("tile.opentopomap.org");
    }) || null;
    if (state.onlineMapEnabled && failedProvider === state.onlineMapProvider) {
      state.onlineTileErrors += 1;
      if (state.onlineTileErrors >= 3) {
        if (failedProvider === "osm") {
          activateOnlineFallback();
        } else {
          setOnlineMapStatus("degraded");
          if (!state.onlineFallbackAnnounced) {
            state.onlineFallbackAnnounced = true;
            showToast("在线地图连接不稳定，当前由本地全球概览补齐", true);
          }
        }
      }
    }
  });
  map.on("sourcedata", (event) => {
    const expectedSource = onlineProvider().sourceId;
    if (event.sourceId !== expectedSource || !state.onlineMapEnabled || !event.isSourceLoaded) return;
    clearTimeout(state.onlineStatusTimer);
    state.onlineTileErrors = 0;
    setOnlineMapStatus(state.onlineMapProvider === "openfreemap" ? "fallback" : "ready");
  });
  map.on("moveend", () => {
    if (state.layerVisibility.emergency) updateEmergencyLayer();
    state.liveLayers?.scheduleViewportRefresh();
    syncMapPackLayerVisibilityForViewport();
    syncLocalBaseMapForViewport();
    updateCoveragePrompt();
  });
}

async function init() {
  cacheElements();
  setSidePanelCollapsed(document.body.classList.contains("panel-collapsed"), false);
  icons();
  syncDisplaySettings();
  const requestParameters = new URLSearchParams(window.location.search);
  const worldCatalogPromise = fetch("/config/world-region-catalog.json", { cache: "no-cache" })
    .then((response) => response.json())
    .catch(() => null);
  const packBoundariesPromise = api("/map-pack-boundaries").catch(() => null);
  const countryBoundariesPromise = fetch("/assets/overview/countries.geojson", { cache: "force-cache" })
    .then((response) => response.ok ? response.json() : null)
    .then(countryBoundariesFromGeoJson)
    .catch(() => ({}));
  const overviewManifestPromise = fetch("/assets/overview/overview.manifest.json", { cache: "no-cache" })
    .then((response) => response.ok ? response.json() : null)
    .catch(() => null);
  const [catalog, resourceCatalog, packStatus, overviewManifest] = await Promise.all([
    fetch("/config/map-catalog.json", { cache: "no-cache" }).then((response) => response.json()),
    fetch("/config/resource-catalog.json", { cache: "no-cache" }).then((response) => response.json()),
    api("/map-packs").catch(() => null),
    overviewManifestPromise
  ]);
  state.catalog = catalog;
  state.resourceCatalog = mergeResourceCatalog(resourceCatalog, null);
  const overviewVectorFile = overviewManifest?.files?.find((file) => file.name === "world-overview.pmtiles");
  if (state.resourceCatalog.localMaps?.worldOverviewVector && overviewVectorFile?.sha256) {
    state.resourceCatalog.localMaps.worldOverviewVector.revision = String(overviewVectorFile.sha256).slice(0, 16);
  }
  state.resourceRegionId = state.resourceCatalog.rootRegion || "world";
  state.mapPacks = packStatus?.packs || catalog.datasets.map((dataset) => ({
    ...dataset,
    installed: dataset.preinstalled === true,
    sizeMatches: dataset.preinstalled === true,
    buildReady: false
  }));
  state.osmCartoPackIds = packStatus?.osmCartoPackIds || null;
  state.mapPackBoundaries = {};
  syncInstalledCatalogDatasets();
  const preferredPackId = localStorage.getItem("terrasys-active-pack");
  const installedPackIds = new Set(state.mapPacks.filter((pack) => pack.installed && pack.enabled !== false).map((pack) => pack.id));
  state.activePackId = [preferredPackId, catalog.activeDataset]
    .find((packId) => packId && installedPackIds.has(packId))
    || state.mapPacks.find((pack) => pack.installed && pack.enabled !== false)?.id
    || catalog.activeDataset;
  if (state.activePackId) localStorage.setItem("terrasys-active-pack", state.activePackId);
  state.viewPackId = "all";
  document.querySelectorAll("[data-theme]").forEach((button) => {
    button.classList.toggle("active", button.dataset.theme === state.theme);
  });
  elements.dataVersion.textContent = packStatus?.catalogVersion || state.catalog.version;
  renderViewSwitcher();
  renderRegionPacks();
  updateRoutePanel();

  const initialBounds = combinedInstalledBounds() || activeDataset()?.bounds || [114.7, 29.25, 122.25, 35.45];
  const defaultCenter = [(initialBounds[0] + initialBounds[2]) / 2, (initialBounds[1] + initialBounds[3]) / 2];
  const requestedLongitudeText = requestParameters.get("lon") ?? requestParameters.get("lng");
  const requestedLatitudeText = requestParameters.get("lat");
  const requestedZoomText = requestParameters.get("zoom");
  const requestedLongitude = requestedLongitudeText === null ? NaN : Number(requestedLongitudeText);
  const requestedLatitude = requestedLatitudeText === null ? NaN : Number(requestedLatitudeText);
  const requestedZoom = requestedZoomText === null ? NaN : Number(requestedZoomText);
  const initialCenter = Number.isFinite(requestedLongitude) && Number.isFinite(requestedLatitude)
    && requestedLongitude >= -180 && requestedLongitude <= 180
    && requestedLatitude >= -85.05112878 && requestedLatitude <= 85.05112878
    ? [requestedLongitude, requestedLatitude]
    : defaultCenter;
  const initialZoom = Number.isFinite(requestedZoom)
    ? Math.max(state.catalog.limits.minZoom, Math.min(state.catalog.limits.maxZoom, requestedZoom))
    : 6.3;

  const protocol = new pmtiles.Protocol();
  maplibregl.addProtocol("pmtiles", protocol.tile);
  state.terrainDemSource = createTerrainDemSource();
  await state.terrainDemSource.manager.loaded;
  const initialStyleDatasets = renderingMapCatalog().datasets;
  state.renderedPackIds = initialStyleDatasets.map((dataset) => dataset.id).sort();
  state.visiblePackIds = new Set(state.renderedPackIds);
  const generated = window.TerraSysMapStyle.create(mapStyleCatalog(initialStyleDatasets), state.theme);
  state.layerGroups = generated.groups;
  indexRenderedPackLayers(generated.style);

  state.map = new maplibregl.Map({
    container: "map",
    center: initialCenter,
    zoom: initialZoom,
    minZoom: state.catalog.limits.minZoom,
    maxZoom: state.catalog.limits.maxZoom,
    maxBounds: state.catalog.limits.maxBounds,
    localIdeographFontFamily: "Microsoft YaHei, SimHei, sans-serif",
    style: generated.style,
    attributionControl: false
  });

  state.map.addControl(new maplibregl.AttributionControl({
    compact: true,
    customAttribution: '<a href="https://github.com/gravitystorm/openstreetmap-carto" target="_blank" rel="noreferrer">OpenStreetMap Carto</a>'
  }), "bottom-right");
  state.map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), "bottom-right");
  state.map.addControl(new maplibregl.GeolocateControl({ positionOptions: { enableHighAccuracy: true }, trackUserLocation: false }), "bottom-right");
  state.scaleControl = new maplibregl.ScaleControl({ maxWidth: 120, unit: state.scaleUnit });
  state.map.addControl(state.scaleControl, "bottom-left");

  state.liveLayers = createLiveLayersModule(state.map, {
    api,
    escapeHtml,
    showToast,
    renderIcons: icons,
    listElement: elements.liveLayersList,
    statusElement: elements.liveLayersStatus,
    onStateChange: () => {
      state.legendSignature = "";
      syncMapShortcuts();
      renderLegend();
    }
  });

  wireUi();
  wireMap();
  worldCatalogPromise.then((worldCatalog) => {
    if (!worldCatalog) return;
    state.resourceCatalog = mergeResourceCatalog(resourceCatalog, worldCatalog);
    renderRegionPacks();
    if (elements.resourceManagerDialog?.open) renderResourceManager();
  });
  packBoundariesPromise.then((packBoundaries) => {
    if (!packBoundaries?.boundaries) return;
    state.mapPackBoundaries = packBoundaries.boundaries;
    syncMapPackLayerVisibilityForViewport();
    syncLocalBaseMapForViewport();
    updateCoveragePrompt();
  });
  countryBoundariesPromise.then((countryBoundaries) => {
    state.mapCountryBoundaries = countryBoundaries;
    syncMapPackLayerVisibilityForViewport();
    syncLocalBaseMapForViewport();
    updateCoveragePrompt();
  });
  const requestedMapPack = requestParameters.get("pack");
  const requestedCoveragePack = requestParameters.get("coverage");
  if (requestedCoveragePack) locateRegionPack(requestedCoveragePack);
  window.addEventListener("storage", (event) => {
    if (event.key === "terrasys-resource-revision" && event.newValue) {
      refreshMapPackStateFromResources();
    }
  });
  await checkServices(packStatus);
  if (requestedMapPack) {
    window.setTimeout(() => activateRegionPack(requestedMapPack), 500);
  }
  window.setInterval(checkServices, 60_000);
}

init().catch((error) => {
  cacheElements();
  elements.systemState.textContent = "启动失败";
  elements.systemState.classList.add("error");
  showToast(error.message, true);
  console.error(error);
});
