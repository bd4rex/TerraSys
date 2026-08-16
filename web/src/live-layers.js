const EMPTY_COLLECTION = Object.freeze({ type: "FeatureCollection", features: [] });

export const LIVE_LAYER_DEFINITIONS = [
  { id: "earthquakes", label: "地震", description: "USGS · 近 7 日", priority: "P0", icon: "activity", refreshSeconds: 60, color: "#ef4444" },
  { id: "wildfires", label: "山火事件", description: "NASA EONET · 开放事件", priority: "P0", icon: "flame", refreshSeconds: 600, color: "#f97316" },
  { id: "disasters", label: "灾害预警", description: "GDACS · 洪水/火山/干旱", priority: "P0", icon: "triangle-alert", refreshSeconds: 300, color: "#eab308" },
  { id: "air-quality", label: "空气质量", description: "Open-Meteo · CAMS 模型", priority: "P0", icon: "wind", refreshSeconds: 900, color: "#22c55e" },
  { id: "floods", label: "河流流量", description: "GloFAS · 模式采样", priority: "P0", icon: "waves", refreshSeconds: 21600, color: "#0ea5e9" },
  { id: "aircraft", label: "ADS-B 飞机", description: "ADSB.lol · 当前视口", priority: "P0", icon: "plane", refreshSeconds: 8, color: "#2563eb" },
  { id: "vessels", label: "AIS 船舶", description: "开放 AIS · 挪威覆盖", priority: "P0", icon: "ship", refreshSeconds: 8, color: "#0891b2" },
  { id: "ocean-buoys", label: "海洋浮标", description: "NOAA NDBC · 最新观测", priority: "P1", icon: "radio-tower", refreshSeconds: 600, color: "#06b6d4" },
  { id: "cyclones", label: "热带气旋", description: "GDACS · 近 30 日", priority: "P1", icon: "tornado", refreshSeconds: 300, color: "#c026d3" }
];

const SOURCE_ATTRIBUTION = {
  earthquakes: "USGS",
  wildfires: "NASA EONET",
  disasters: "GDACS",
  "air-quality": "Open-Meteo / CAMS",
  floods: "Open-Meteo / GloFAS",
  aircraft: "ADSB.lol (ODbL)",
  vessels: "Norwegian Coastal Administration (NLOD)",
  "ocean-buoys": "NOAA NDBC",
  cyclones: "GDACS"
};

function sourceId(id) {
  return `live-${id}-source`;
}

function layerId(id) {
  return `live-${id}`;
}

function pointLayer(definition) {
  const common = {
    id: layerId(definition.id),
    source: sourceId(definition.id),
    minzoom: definition.id === "aircraft" || definition.id === "vessels" ? 3 : 0,
    layout: { visibility: "none" }
  };
  if (definition.id === "aircraft") {
    return { ...common, type: "symbol", layout: { ...common.layout, "icon-image": "live-aircraft-marker", "icon-size": 0.82, "icon-rotate": ["coalesce", ["get", "track"], 0], "icon-rotation-alignment": "map", "icon-allow-overlap": true } };
  }
  if (definition.id === "vessels") {
    return { ...common, type: "symbol", layout: { ...common.layout, "icon-image": "live-vessel-marker", "icon-size": 0.78, "icon-rotate": ["coalesce", ["get", "course"], 0], "icon-rotation-alignment": "map", "icon-allow-overlap": true } };
  }
  const paint = {
    "circle-color": definition.color,
    "circle-radius": 6,
    "circle-opacity": 0.82,
    "circle-stroke-color": "#ffffff",
    "circle-stroke-width": 1.4
  };
  if (definition.id === "earthquakes") {
    paint["circle-radius"] = ["interpolate", ["linear"], ["coalesce", ["get", "magnitude"], 1], 0, 3, 3, 6, 6, 12, 9, 18];
    paint["circle-color"] = ["step", ["coalesce", ["get", "magnitude"], 0], "#fca5a5", 3, "#f97316", 5, "#dc2626", 7, "#7f1d1d"];
  } else if (definition.id === "disasters") {
    paint["circle-color"] = ["match", ["downcase", ["coalesce", ["get", "alertLevel"], "green"]], "red", "#dc2626", "orange", "#f97316", "#eab308"];
    paint["circle-radius"] = 8;
  } else if (definition.id === "air-quality") {
    paint["circle-color"] = ["step", ["coalesce", ["get", "usAqi"], 0], "#22c55e", 51, "#eab308", 101, "#f97316", 151, "#ef4444", 201, "#7c3aed", 301, "#7f1d1d"];
    paint["circle-radius"] = 9;
    paint["circle-opacity"] = 0.72;
  } else if (definition.id === "floods") {
    paint["circle-radius"] = ["interpolate", ["linear"], ["coalesce", ["get", "maxDischarge"], 0], 0, 4, 100, 7, 1000, 12, 10000, 18];
    paint["circle-opacity"] = 0.65;
  } else if (definition.id === "cyclones") {
    paint["circle-radius"] = 10;
    paint["circle-stroke-width"] = 2;
  }
  return { ...common, type: "circle", paint };
}

function normalizeLongitude(value) {
  return ((value + 180) % 360 + 360) % 360 - 180;
}

function viewportQuery(map) {
  const bounds = map.getBounds();
  const rawWest = Number(bounds.getWest());
  const rawEast = Number(bounds.getEast());
  const span = rawEast - rawWest;
  const west = span >= 360 ? -180 : normalizeLongitude(rawWest);
  const east = span >= 360 ? 180 : normalizeLongitude(rawEast);
  const south = Math.max(-90, Number(bounds.getSouth()));
  const north = Math.min(90, Number(bounds.getNorth()));
  return new URLSearchParams({ west: String(west), south: String(south), east: String(east), north: String(north) }).toString();
}

function safeHttpUrl(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.href : "";
  } catch {
    return "";
  }
}

function readableTime(value) {
  if (!value) return "时间未知";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString("zh-CN", { hour12: false });
}

function markerCanvas(kind) {
  const canvas = document.createElement("canvas");
  canvas.width = 36;
  canvas.height = 36;
  const context = canvas.getContext("2d");
  context.translate(18, 18);
  context.beginPath();
  if (kind === "aircraft") {
    context.moveTo(0, -16);
    context.lineTo(4, -4);
    context.lineTo(14, 3);
    context.lineTo(13, 7);
    context.lineTo(4, 4);
    context.lineTo(3, 14);
    context.lineTo(-3, 14);
    context.lineTo(-4, 4);
    context.lineTo(-13, 7);
    context.lineTo(-14, 3);
    context.lineTo(-4, -4);
  } else {
    context.moveTo(0, -15);
    context.lineTo(10, 10);
    context.lineTo(0, 15);
    context.lineTo(-10, 10);
  }
  context.closePath();
  context.fillStyle = kind === "aircraft" ? "#2563eb" : "#0891b2";
  context.strokeStyle = "#ffffff";
  context.lineWidth = 3;
  context.lineJoin = "round";
  context.stroke();
  context.fill();
  return context.getImageData(0, 0, canvas.width, canvas.height);
}

export class LiveLayersModule {
  constructor(map, options) {
    this.map = map;
    this.api = options.api;
    this.escapeHtml = options.escapeHtml;
    this.showToast = options.showToast || (() => {});
    this.onStateChange = options.onStateChange || (() => {});
    this.renderIcons = options.renderIcons || (() => {});
    this.listElement = options.listElement;
    this.statusElement = options.statusElement;
    this.visible = new Set();
    this.counts = new Map();
    this.statuses = new Map();
    this.lastFetch = new Map();
    this.requestIds = new Map();
    this.timer = null;
    this.viewportRefreshTimer = null;
    this.interactionsBound = false;
    this.listInteractionsBound = false;
    this.definitions = LIVE_LAYER_DEFINITIONS.map((item) => ({ ...item, enabled: true }));
    this.renderList();
    this.bindListInteractions();
    this.bindInteractions();
    this.loadCatalog();
  }

  async loadCatalog() {
    try {
      const catalog = await this.api("/live/catalog");
      const configured = new Map((catalog.layers || []).map((item) => [item.id, item]));
      this.definitions = LIVE_LAYER_DEFINITIONS.map((definition) => ({
        ...definition,
        ...(configured.get(definition.id) || {}),
        icon: definition.icon,
        color: definition.color,
        description: definition.description
      }));
      for (const definition of this.definitions) {
        if (definition.enabled === false) this.visible.delete(definition.id);
      }
      this.renderList();
      this.ensureLayers();
      this.onStateChange();
    } catch (error) {
      console.warn("Live layer catalog unavailable; using built-in defaults", error);
    }
  }

  ensureLayers() {
    if (!this.map?.isStyleLoaded()) return;
    if (!this.map.hasImage("live-aircraft-marker")) this.map.addImage("live-aircraft-marker", markerCanvas("aircraft"), { pixelRatio: 2 });
    if (!this.map.hasImage("live-vessel-marker")) this.map.addImage("live-vessel-marker", markerCanvas("vessel"), { pixelRatio: 2 });
    for (const definition of this.definitions) {
      const source = sourceId(definition.id);
      const layer = layerId(definition.id);
      if (!this.map.getSource(source)) {
        this.map.addSource(source, { type: "geojson", data: EMPTY_COLLECTION, attribution: SOURCE_ATTRIBUTION[definition.id] });
      }
      if (!this.map.getLayer(layer)) this.map.addLayer(pointLayer(definition));
      this.map.setLayoutProperty(layer, "visibility", this.visible.has(definition.id) ? "visible" : "none");
    }
  }

  renderList() {
    if (!this.listElement) return;
    this.listElement.innerHTML = ["P0", "P1"].map((priority) => `
      <section class="live-layer-group" aria-label="${priority} 信息图层">
        <h2>${priority === "P0" ? "核心实时层 · P0" : "扩展参考层 · P1"}</h2>
        ${this.definitions.filter((item) => item.priority === priority).map((item) => `
          <label class="live-layer-option${item.enabled === false ? " disabled" : ""}" data-live-row="${item.id}">
            <input type="checkbox" data-live-layer="${item.id}" ${this.visible.has(item.id) ? "checked" : ""} ${item.enabled === false ? "disabled" : ""} />
            <span class="live-layer-icon" style="--live-layer-color:${item.color}"><i data-lucide="${item.icon}"></i></span>
            <span class="live-layer-copy"><strong>${item.label}</strong><small>${item.description}</small></span>
            <span class="live-layer-count" data-live-count="${item.id}">${item.enabled === false ? "已停用" : "关闭"}</span>
          </label>`).join("")}
      </section>`).join("") + `
      <button class="live-layer-coverage" type="button" data-live-action="ais-coverage">
        <i data-lucide="locate-fixed"></i><span><strong>查看 AIS 开放覆盖区</strong><small>飞到挪威海域并开启船舶层</small></span>
      </button>
      <a class="live-layer-manager-link" href="/information-layers.html">
        <i data-lucide="settings-2"></i><span><strong>管理附加信息源</strong><small>启停、刷新频率、运行状态与信源目录</small></span><i data-lucide="chevron-right"></i>
      </a>`;
    for (const definition of this.definitions) this.updateRow(definition.id);
    this.renderIcons();
    this.updateStatus();
  }

  bindListInteractions() {
    if (!this.listElement || this.listInteractionsBound) return;
    this.listInteractionsBound = true;
    this.listElement.addEventListener("change", (event) => {
      const input = event.target.closest("[data-live-layer]");
      if (input) this.setVisible(input.dataset.liveLayer, input.checked);
    });
    this.listElement.addEventListener("click", (event) => {
      if (!event.target.closest('[data-live-action="ais-coverage"]')) return;
      const vessels = this.definitions.find((item) => item.id === "vessels");
      if (vessels?.enabled === false) {
        this.showToast("AIS 船舶已在信息源管理中停用");
        return;
      }
      this.map.flyTo({ center: [10.2, 60.2], zoom: 6, essential: true });
      this.setVisible("vessels", true);
      this.showToast("已前往挪威 AIS 开放覆盖区");
    });
  }

  setVisible(id, visible) {
    const definition = this.definitions.find((item) => item.id === id);
    if (!definition) return;
    if (visible && definition.enabled === false) {
      const input = this.listElement?.querySelector(`[data-live-layer="${id}"]`);
      if (input) input.checked = false;
      this.showToast(`${definition.label}已在信息源管理中停用`);
      return;
    }
    if (visible) this.visible.add(id); else this.visible.delete(id);
    this.ensureLayers();
    if (this.map.getLayer(layerId(id))) this.map.setLayoutProperty(layerId(id), "visibility", visible ? "visible" : "none");
    const input = this.listElement?.querySelector(`[data-live-layer="${id}"]`);
    if (input) input.checked = visible;
    this.updateRow(id);
    this.updateStatus();
    this.onStateChange();
    if (visible) {
      this.startTimer();
      this.refresh(id, true);
    } else if (!this.visible.size) {
      this.stopTimer();
    }
  }

  hasVisibleLayers() {
    return this.visible.size > 0;
  }

  visibleCount() {
    return this.visible.size;
  }

  startTimer() {
    if (this.timer) return;
    this.timer = window.setInterval(() => this.refreshVisible(), 5000);
  }

  stopTimer() {
    if (this.timer) window.clearInterval(this.timer);
    this.timer = null;
  }

  async refresh(id, force = false) {
    if (!this.visible.has(id)) return;
    const definition = this.definitions.find((item) => item.id === id);
    if (!definition || definition.enabled === false) return;
    const now = Date.now();
    if (!force && now - (this.lastFetch.get(id) || 0) < definition.refreshSeconds * 1000) return;
    const requestId = (this.requestIds.get(id) || 0) + 1;
    this.requestIds.set(id, requestId);
    this.statuses.set(id, "loading");
    this.updateRow(id);
    try {
      const payload = await this.api(`/live/${id}?${viewportQuery(this.map)}`);
      if (this.requestIds.get(id) !== requestId) return;
      this.ensureLayers();
      this.map.getSource(sourceId(id))?.setData(payload);
      this.counts.set(id, payload.features?.length || 0);
      this.statuses.set(id, payload.properties?.status || "ok");
      this.lastFetch.set(id, Date.now());
    } catch (error) {
      if (this.requestIds.get(id) !== requestId) return;
      this.statuses.set(id, "unavailable");
      this.counts.set(id, 0);
      console.warn(`Live layer ${id} failed`, error);
    }
    this.updateRow(id);
    this.updateStatus();
    this.onStateChange();
  }

  refreshVisible(force = false) {
    for (const id of this.visible) this.refresh(id, force);
  }

  scheduleViewportRefresh() {
    window.clearTimeout(this.viewportRefreshTimer);
    this.viewportRefreshTimer = window.setTimeout(() => this.refreshVisible(true), 280);
  }

  updateRow(id) {
    const countElement = this.listElement?.querySelector(`[data-live-count="${id}"]`);
    const row = this.listElement?.querySelector(`[data-live-row="${id}"]`);
    if (!countElement || !row) return;
    const visible = this.visible.has(id);
    const status = this.statuses.get(id);
    const definition = this.definitions.find((item) => item.id === id);
    row.classList.toggle("active", visible);
    row.classList.toggle("unavailable", status === "unavailable");
    countElement.textContent = definition?.enabled === false ? "已停用" : !visible ? "关闭" : status === "loading" ? "更新中" : status === "connecting" ? "连接中" : status === "unavailable" ? "暂不可用" : `${this.counts.get(id) || 0} 个`;
  }

  updateStatus() {
    if (!this.statusElement) return;
    if (!this.visible.size) {
      this.statusElement.textContent = "仅列出无需密钥的公开源";
      return;
    }
    const total = [...this.visible].reduce((sum, id) => sum + (this.counts.get(id) || 0), 0);
    const unavailable = [...this.visible].filter((id) => this.statuses.get(id) === "unavailable").length;
    this.statusElement.textContent = `已开启 ${this.visible.size} 层 · ${total} 个对象${unavailable ? ` · ${unavailable} 层不可用` : ""}`;
  }

  getLegendItems() {
    return this.definitions.filter((item) => this.visible.has(item.id)).map((item) => [`live-${item.id}`, item.label]);
  }

  featureAtPoint(point) {
    const layers = this.definitions.map((item) => layerId(item.id)).filter((id) => this.map.getLayer(id));
    return layers.length ? this.map.queryRenderedFeatures(point, { layers })[0] || null : null;
  }

  bindInteractions() {
    if (this.interactionsBound) return;
    this.interactionsBound = true;
    this.map.on("click", (event) => {
      const feature = this.featureAtPoint(event.point);
      if (!feature) return;
      const properties = feature.properties || {};
      const url = safeHttpUrl(properties.sourceUrl);
      const detail = properties.detail ? `<p>${this.escapeHtml(properties.detail)}</p>` : "";
      const link = url ? `<a href="${this.escapeHtml(url)}" target="_blank" rel="noreferrer">查看原始信源</a>` : "";
      new window.maplibregl.Popup({ closeButton: true, maxWidth: "340px" })
        .setLngLat(event.lngLat)
        .setHTML(`<div class="live-feature-popup"><small>${this.escapeHtml(properties.sourceLabel || "公开信息图层")}</small><strong>${this.escapeHtml(properties.title || "信息对象")}</strong><span>${this.escapeHtml(properties.subtitle || "")}</span><time>${this.escapeHtml(readableTime(properties.observedAt))}</time>${detail}${link}<em>${this.escapeHtml(properties.license || "")}</em></div>`)
        .addTo(this.map);
    });
  }
}

export function createLiveLayersModule(map, options) {
  return new LiveLayersModule(map, options);
}
