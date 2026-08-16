const state = {
  view: "runtime",
  query: "",
  catalog: { layers: [], candidates: [], enabledCount: 0 },
  runtime: { layers: [], readyCount: 0 },
  testing: new Set(),
  testResults: new Map(),
  testEvents: [],
  loading: false,
  testingAll: false,
  poller: null
};

const SOURCE_VISUALS = {
  earthquakes: ["activity", "#dc3e36"],
  wildfires: ["flame", "#e86e19"],
  disasters: ["triangle-alert", "#c99213"],
  "air-quality": ["wind", "#32935f"],
  floods: ["waves", "#1786b3"],
  aircraft: ["plane", "#316bd0"],
  vessels: ["ship", "#13879a"],
  "ocean-buoys": ["radio-tower", "#168fab"],
  cyclones: ["tornado", "#a044b1"]
};

const TEST_QUERIES = {
  earthquakes: "west=-180&south=-90&east=180&north=90&min_magnitude=4",
  wildfires: "west=-180&south=-90&east=180&north=90",
  disasters: "west=-180&south=-90&east=180&north=90",
  "air-quality": "west=120&south=30&east=122&north=32",
  floods: "west=120&south=30&east=122&north=32",
  aircraft: "west=138&south=34&east=141&north=37&limit=500",
  vessels: "west=4&south=57&east=13&north=63&limit=2000",
  "ocean-buoys": "west=-170&south=0&east=-20&north=75&limit=500",
  cyclones: "west=-180&south=-90&east=180&north=90"
};

const VIEW_COPY = {
  runtime: ["全部免密源", "启停会影响地图里的附加图层入口；连接测试只读取公开数据。"],
  p0: ["核心图层 P0", "优先接入的事件、环境、ADS-B 与 AIS 图层。"],
  p1: ["扩展图层 P1", "海洋观测和热带气旋等补充态势信息。"],
  keyed: ["需密钥候选", "只展示认证方式与已公开调用限制，当前不会发起请求或保存密钥。"]
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const icons = () => window.lucide?.createIcons({ attrs: { "stroke-width": 1.8 } });

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[character]);
}

async function api(path, options = {}) {
  const response = await fetch(`/api${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) }
  });
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`;
    try { detail = (await response.json()).detail || detail; } catch {}
    throw new Error(detail);
  }
  return response.status === 204 ? null : response.json();
}

function showNotice(message, error = false) {
  const notice = $("#notice");
  notice.textContent = message;
  notice.classList.toggle("error", error);
  notice.hidden = false;
  clearTimeout(showNotice.timer);
  showNotice.timer = setTimeout(() => { notice.hidden = true; }, error ? 6000 : 3300);
}

function formatTime(value, fallback = "尚未检测") {
  if (!value) return fallback;
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? String(value) : date.toLocaleString("zh-CN", { hour12: false });
}

function formatCount(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number.toLocaleString("zh-CN") : "--";
}

function formatRefresh(seconds) {
  const value = Number(seconds);
  if (value < 60) return `${value} 秒`;
  if (value < 3600) return `${value / 60} 分钟`;
  if (value < 86400) return `${value / 3600} 小时`;
  return `${value / 86400} 天`;
}

function runtimeFor(id) {
  return state.runtime.layers.find((item) => item.id === id) || { id, status: "idle" };
}

function effectiveStatus(id) {
  if (state.testing.has(id)) return "testing";
  return state.testResults.get(id)?.status || runtimeFor(id).status || "idle";
}

function statusLabel(status) {
  return ({ ready: "可用", unavailable: "暂不可用", testing: "测试中", connecting: "连接中", idle: "未检测" })[status] || status;
}

function renderMetrics() {
  const layers = state.catalog.layers || [];
  const candidates = state.catalog.candidates || [];
  const ready = state.runtime.readyCount || 0;
  $("#runtimeMetric").textContent = formatCount(layers.length);
  $("#enabledMetric").textContent = formatCount(layers.filter((item) => item.enabled !== false).length);
  $("#readyMetric").textContent = formatCount(ready);
  $("#candidateMetric").textContent = formatCount(candidates.length);
  $("#runtimeBadge").textContent = layers.length;
  $("#p0Badge").textContent = layers.filter((item) => item.priority === "P0").length;
  $("#p1Badge").textContent = layers.filter((item) => item.priority === "P1").length;
  $("#keyedBadge").textContent = candidates.length;
  $("#healthBadge").textContent = `${ready}/${layers.length || 0}`;
  const serviceState = $("#serviceState");
  serviceState.textContent = state.loading ? "正在连接" : `API 已连接 · ${ready} 个已验证`;
  serviceState.className = `status-pill${state.loading ? " neutral" : ""}`;
}

function matchesQuery(item) {
  const query = state.query.trim().toLocaleLowerCase("zh-CN");
  if (!query) return true;
  return Object.values(item).filter((value) => typeof value === "string").join(" ").toLocaleLowerCase("zh-CN").includes(query);
}

function sourceCard(item) {
  const [icon, color] = SOURCE_VISUALS[item.id] || ["circle-dot", "#4b7161"];
  const runtime = runtimeFor(item.id);
  const test = state.testResults.get(item.id);
  const status = effectiveStatus(item.id);
  const count = test?.count ?? runtime.objectCount;
  const latency = test?.latencyMs ?? runtime.latencyMs;
  const disabled = item.enabled === false;
  return `
    <article class="source-card ${disabled ? "disabled" : ""} ${status === "unavailable" ? "unavailable" : ""}" data-source-card="${escapeHtml(item.id)}">
      <div class="source-main">
        <div class="source-title-row">
          <span class="source-glyph" style="--source-color:${color}"><i data-lucide="${icon}"></i></span>
          <div class="source-title">
            <div class="source-badges">
              <span class="priority-badge ${item.priority === "P1" ? "p1" : ""}">${escapeHtml(item.priority)}</span>
              <span class="runtime-badge ${escapeHtml(status)}" data-runtime-status="${escapeHtml(item.id)}">${statusLabel(status)}</span>
              <span class="source-provider">${escapeHtml(item.source)}</span>
            </div>
            <h3>${escapeHtml(item.label)}</h3>
            <p>${escapeHtml(item.description)}</p>
          </div>
        </div>
        <div class="source-facts">
          <div><span>覆盖范围</span><strong title="${escapeHtml(item.coverage)}">${escapeHtml(item.coverage || "由提供方决定")}</strong></div>
          <div><span>数据延迟</span><strong>${escapeHtml(item.dataLatency || "未说明")}</strong></div>
          <div><span>开放许可</span><strong title="${escapeHtml(item.license)}">${escapeHtml(item.license)}</strong></div>
        </div>
        <p class="source-use">用途边界：${escapeHtml(item.decisionUse || "态势参考")} · 最近测试 ${formatTime(test?.checkedAt || runtime.lastCheckedAt)}</p>
      </div>
      <div class="source-controls">
        <label class="enable-row"><span>${disabled ? "已停用" : "已启用"}</span><span class="switch"><input type="checkbox" data-enabled="${escapeHtml(item.id)}" ${disabled ? "" : "checked"} /><span></span></span></label>
        <label class="refresh-label"><span>地图刷新间隔 · ${formatRefresh(item.refreshSeconds)}</span><span class="refresh-editor"><input type="number" data-refresh="${escapeHtml(item.id)}" value="${Number(item.refreshSeconds)}" min="${Number(item.minRefreshSeconds)}" max="${Number(item.maxRefreshSeconds)}" step="1" /><button class="save-refresh" type="button" data-action="save-refresh" data-source-id="${escapeHtml(item.id)}">保存</button></span></label>
        <div class="source-actions">
          <button class="source-action primary" type="button" data-action="test" data-source-id="${escapeHtml(item.id)}" ${state.testing.has(item.id) ? "disabled" : ""}><i data-lucide="${state.testing.has(item.id) ? "loader-circle" : "plug-zap"}"></i><span>${state.testing.has(item.id) ? "测试中" : "连接测试"}</span></button>
          <a class="source-action" href="${escapeHtml(item.sourceUrl)}" target="_blank" rel="noreferrer" title="打开官方信源" aria-label="打开 ${escapeHtml(item.source)} 官方信源"><i data-lucide="external-link"></i></a>
        </div>
        <div class="control-meta"><span>可设范围 ${formatRefresh(item.minRefreshSeconds)} – ${formatRefresh(item.maxRefreshSeconds)}</span><span data-test-meta="${escapeHtml(item.id)}">${count == null ? "尚无对象计数" : `${formatCount(count)} 个对象`}${latency == null ? "" : ` · ${formatCount(latency)} ms`}</span></div>
      </div>
    </article>`;
}

function candidateCard(item) {
  return `
    <article class="candidate-card" data-candidate-card="${escapeHtml(item.id)}">
      <span class="candidate-icon"><i data-lucide="key-round"></i></span>
      <div class="candidate-main">
        <h3>${escapeHtml(item.label)}</h3>
        <p>${escapeHtml(item.layer)}</p>
        <div class="candidate-facts">
          <span><i data-lucide="shield-keyhole"></i>${escapeHtml(item.authentication)}</span>
          <span><i data-lucide="gauge"></i>${escapeHtml(item.callLimit)}</span>
        </div>
      </div>
      <div class="candidate-side">
        <strong>${escapeHtml(item.recommendation)}</strong>
        <a href="${escapeHtml(item.sourceUrl)}" target="_blank" rel="noreferrer"><i data-lucide="external-link"></i><span>查看官方限制</span></a>
      </div>
    </article>`;
}

function renderSources() {
  const [title, description] = VIEW_COPY[state.view];
  $("#viewTitle").textContent = title;
  $("#viewDescription").textContent = description;
  $$(".section-nav [data-view]").forEach((button) => button.classList.toggle("active", button.dataset.view === state.view));
  let items;
  if (state.view === "keyed") {
    items = (state.catalog.candidates || []).filter(matchesQuery);
    $("#sourceList").innerHTML = items.length ? items.map(candidateCard).join("") : '<div class="empty-state">没有匹配的需密钥候选源</div>';
  } else {
    items = (state.catalog.layers || []).filter((item) => state.view === "runtime" || item.priority.toLowerCase() === state.view).filter(matchesQuery);
    $("#sourceList").innerHTML = items.length ? items.map(sourceCard).join("") : '<div class="empty-state">没有匹配的免密信息源</div>';
  }
  icons();
}

function renderRail() {
  const vessel = runtimeFor("vessels");
  const stream = vessel.stream || {};
  $("#aisState").textContent = stream.connected ? "已连接" : stream.enabled === false ? "已关闭" : stream.lastError ? "重连中" : "连接中";
  $("#aisDetails").innerHTML = `
    <div><span>TCP 状态</span><strong>${stream.connected ? "已连接" : "未连接"}</strong></div>
    <div><span>累计报文</span><strong>${formatCount(stream.receivedCount)}</strong></div>
    <div><span>最近报文</span><strong title="${escapeHtml(formatTime(stream.lastMessageAt))}">${escapeHtml(formatTime(stream.lastMessageAt, "等待数据"))}</strong></div>
    <div><span>开放端点</span><strong title="${escapeHtml(`${stream.host || "--"}:${stream.port || "--"}`)}">${escapeHtml(`${stream.host || "--"}:${stream.port || "--"}`)}</strong></div>`;
  $("#testCount").textContent = `${state.testEvents.length} 项`;
  $("#testEvents").innerHTML = state.testEvents.length ? state.testEvents.slice(0, 10).map((event) => `
    <div class="test-event"><i class="${escapeHtml(event.status)}"></i><span><strong>${escapeHtml(event.label)}</strong><small>${escapeHtml(event.detail)}</small></span><time>${escapeHtml(new Date(event.checkedAt).toLocaleTimeString("zh-CN", { hour12: false }))}</time></div>`).join("") : '<div class="event-empty">尚未在本页面发起连接测试</div>';
}

function renderAll() {
  renderMetrics();
  renderSources();
  renderRail();
  icons();
}

function updateRuntimeCards() {
  for (const item of state.catalog.layers || []) {
    const runtime = runtimeFor(item.id);
    const test = state.testResults.get(item.id);
    const status = effectiveStatus(item.id);
    const badge = document.querySelector(`[data-runtime-status="${CSS.escape(item.id)}"]`);
    if (badge) {
      badge.className = `runtime-badge ${status}`;
      badge.textContent = statusLabel(status);
    }
    const card = document.querySelector(`[data-source-card="${CSS.escape(item.id)}"]`);
    card?.classList.toggle("unavailable", status === "unavailable");
    const meta = document.querySelector(`[data-test-meta="${CSS.escape(item.id)}"]`);
    if (meta) {
      const count = test?.count ?? runtime.objectCount;
      const latency = test?.latencyMs ?? runtime.latencyMs;
      meta.textContent = count == null ? "尚无对象计数" : `${formatCount(count)} 个对象${latency == null ? "" : ` · ${formatCount(latency)} ms`}`;
    }
  }
}

async function loadCatalogAndStatus() {
  state.loading = true;
  renderMetrics();
  try {
    const [catalog, runtime] = await Promise.all([api("/live/catalog"), api("/live/status")]);
    state.catalog = catalog;
    state.runtime = runtime;
    state.loading = false;
    renderAll();
  } catch (error) {
    state.loading = false;
    $("#serviceState").textContent = "API 不可用";
    $("#serviceState").className = "status-pill error";
    showNotice(`无法读取附加信息源：${error.message}`, true);
  }
}

async function refreshRuntime(silent = false) {
  try {
    state.runtime = await api("/live/status");
    renderMetrics();
    updateRuntimeCards();
    renderRail();
    if (!silent) showNotice("运行状态已刷新");
  } catch (error) {
    if (!silent) showNotice(`状态刷新失败：${error.message}`, true);
  }
}

async function updateSetting(id, changes) {
  const original = state.catalog.layers.find((item) => item.id === id);
  if (!original) return;
  try {
    const result = await api(`/live/settings/${encodeURIComponent(id)}`, { method: "PUT", body: JSON.stringify(changes) });
    Object.assign(original, result.layer);
    state.catalog.enabledCount = state.catalog.layers.filter((item) => item.enabled !== false).length;
    renderAll();
    showNotice(`${original.label}设置已保存，返回地图后生效`);
  } catch (error) {
    renderAll();
    showNotice(`保存失败：${error.message}`, true);
  }
}

async function testSource(id) {
  const source = state.catalog.layers.find((item) => item.id === id);
  if (!source || state.testing.has(id)) return;
  state.testing.add(id);
  renderSources();
  const started = performance.now();
  let result;
  try {
    const payload = await api(`/live/${encodeURIComponent(id)}?${TEST_QUERIES[id]}`);
    const latencyMs = Math.round(performance.now() - started);
    const unavailable = payload.properties?.status === "unavailable";
    result = {
      status: unavailable ? "unavailable" : "ready",
      count: payload.features?.length || 0,
      latencyMs,
      checkedAt: new Date().toISOString(),
      message: payload.properties?.message || ""
    };
  } catch (error) {
    result = { status: "unavailable", count: 0, latencyMs: Math.round(performance.now() - started), checkedAt: new Date().toISOString(), message: error.message };
  }
  state.testResults.set(id, result);
  state.testEvents.unshift({
    id,
    label: source.label,
    status: result.status,
    checkedAt: result.checkedAt,
    detail: result.status === "ready" ? `${formatCount(result.count)} 个对象 · ${formatCount(result.latencyMs)} ms` : result.message || "信源暂不可用"
  });
  state.testEvents = state.testEvents.slice(0, 30);
  state.testing.delete(id);
  await refreshRuntime(true);
  renderSources();
  renderRail();
}

async function testAll() {
  if (state.testingAll) return;
  state.testingAll = true;
  $("#testAllButton").disabled = true;
  $("#testAllButton span").textContent = "正在测试";
  const queue = [...state.catalog.layers];
  const workers = Array.from({ length: Math.min(3, queue.length) }, async () => {
    while (queue.length) {
      const source = queue.shift();
      if (source) await testSource(source.id);
    }
  });
  await Promise.all(workers);
  state.testingAll = false;
  $("#testAllButton").disabled = false;
  $("#testAllButton span").textContent = "测试全部免密源";
  showNotice("全部免密信源测试完成");
}

function bindEvents() {
  $(".section-nav nav").addEventListener("click", (event) => {
    const button = event.target.closest("[data-view]");
    if (!button) return;
    state.view = button.dataset.view;
    renderSources();
  });
  $("#sourceSearch").addEventListener("input", (event) => {
    state.query = event.target.value;
    renderSources();
  });
  $("#sourceList").addEventListener("change", (event) => {
    const input = event.target.closest("[data-enabled]");
    if (input) updateSetting(input.dataset.enabled, { enabled: input.checked });
  });
  $("#sourceList").addEventListener("click", (event) => {
    const action = event.target.closest("[data-action]");
    if (!action) return;
    const id = action.dataset.sourceId;
    if (action.dataset.action === "test") testSource(id);
    if (action.dataset.action === "save-refresh") {
      const input = $(`[data-refresh="${CSS.escape(id)}"]`);
      const value = Number(input?.value);
      const min = Number(input?.min);
      const max = Number(input?.max);
      if (!Number.isInteger(value) || value < min || value > max) {
        showNotice(`刷新间隔需为 ${min}–${max} 秒的整数`, true);
        return;
      }
      updateSetting(id, { refreshSeconds: value });
    }
  });
  $("#refreshButton").addEventListener("click", () => refreshRuntime());
  $("#testAllButton").addEventListener("click", testAll);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refreshRuntime(true);
  });
}

bindEvents();
icons();
loadCatalogAndStatus();
state.poller = window.setInterval(() => { if (!document.hidden && !state.testingAll) refreshRuntime(true); }, 15000);
