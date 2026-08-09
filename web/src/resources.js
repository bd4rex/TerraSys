const state = {
  view: "versions",
  packs: [],
  inventory: null,
  maintenance: null,
  selected: new Set(),
  menuPackId: null,
  query: "",
  catalogQuery: "",
  catalogRegionId: "world",
  resourceCatalog: null,
  focusPackId: new URLSearchParams(location.search).get("pack"),
  polling: null,
  jobStatesReady: false,
  knownJobStates: new Map(),
  inventoryDirty: false,
  inventoryWatcher: null,
  maintenancePolling: false,
  refreshing: false
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const icons = () => window.lucide?.createIcons({ attrs: { "stroke-width": 1.8 } });

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[character]);
}

function formatBytes(value) {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes < 0) return "--";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = bytes;
  let index = 0;
  while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index += 1; }
  return `${amount.toFixed(index >= 3 ? 2 : index === 0 ? 0 : 1)} ${units[index]}`;
}

function formatDate(value) {
  if (!value) return "--";
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return String(value);
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
    timeZone: "Asia/Shanghai"
  }).format(date);
}

function packName(pack) {
  if (pack?.kind === "country" && pack.countryId && typeof Intl.DisplayNames === "function") {
    try {
      return new Intl.DisplayNames(["zh-CN"], { type: "region" }).of(pack.countryId) || pack.shortName || pack.name || pack.id;
    } catch {}
  }
  return pack.shortName || pack.name || pack.id;
}

function requestError(error) {
  const message = error?.message || "请求失败";
  showNotice(message, true);
}

function showNotice(message, error = false) {
  const notice = $("#notice");
  notice.textContent = message;
  notice.classList.toggle("error", error);
  notice.hidden = false;
  clearTimeout(showNotice.timer);
  showNotice.timer = setTimeout(() => { notice.hidden = true; }, error ? 6500 : 3600);
}

function announceResourceChange(job) {
  const revision = JSON.stringify({
    at: new Date().toISOString(),
    resourceId: job.resourceId,
    action: job.action,
    status: job.status
  });
  localStorage.setItem("terrasys-resource-revision", revision);
}

function detectJobTransitions(jobs) {
  let terminalTransition = false;
  if (state.jobStatesReady) {
    for (const job of jobs) {
      const previous = state.knownJobStates.get(job.id);
      if (previous && ["queued", "running"].includes(previous) && !["queued", "running"].includes(job.status)) {
        if (job.status === "succeeded") announceResourceChange(job);
        state.inventoryDirty = true;
        terminalTransition = true;
      }
    }
  }
  state.knownJobStates = new Map(jobs.map((job) => [job.id, job.status]));
  state.jobStatesReady = true;
  return terminalTransition;
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

async function loadInventory() {
  try {
    return await api("/resources?cached=true");
  } catch {
    return api("/resources");
  }
}

async function watchInventoryRefresh(previousGeneratedAt) {
  if (state.inventoryWatcher) return state.inventoryWatcher;
  state.inventoryWatcher = (async () => {
    for (let attempt = 0; attempt < 150; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 2000));
      try {
        const inventory = await api("/resources?cached=true");
        if (inventory.generatedAt && inventory.generatedAt !== previousGeneratedAt) {
          state.inventory = inventory;
          state.inventoryDirty = false;
          render();
          showNotice("本地资源状态已刷新");
          return;
        }
      } catch {}
    }
  })().finally(() => {
    state.inventoryWatcher = null;
  });
  return state.inventoryWatcher;
}

async function refresh({ upstream = false, quiet = false, freshInventory = false } = {}) {
  if (state.refreshing) {
    if (!quiet) showNotice("资源信息正在加载，请稍候");
    return;
  }
  state.refreshing = true;
  const refreshButton = $("#refreshButton");
  const upstreamButton = $("#upstreamButton");
  (upstream ? upstreamButton : refreshButton).disabled = true;
  (upstream ? upstreamButton : refreshButton).classList.add("loading");
  if (!quiet) {
    showNotice(upstream ? "正在后台检查上游版本" : "正在后台盘点本地资源，现有页面可以继续使用");
  }
  try {
    if (upstream) await api("/resources?check_upstream=true");
    const shouldRefreshInventory = freshInventory || state.inventoryDirty;
    const [packs, inventory, maintenance] = await Promise.all([
      api("/map-packs"),
      upstream ? api("/resources?cached=true") : shouldRefreshInventory ? api("/resources") : loadInventory(),
      api("/maintenance")
    ]);
    state.inventoryDirty = false;
    state.packs = packs.packs || [];
    const installedIds = new Set(state.packs.filter((pack) => pack.installed).map((pack) => pack.id));
    for (const packId of state.selected) {
      if (!installedIds.has(packId)) state.selected.delete(packId);
    }
    state.inventory = inventory;
    state.maintenance = maintenance;
    detectJobTransitions(maintenance.jobs || []);
    if (state.focusPackId) {
      const focusedPack = state.packs.find((pack) => pack.id === state.focusPackId);
      if (focusedPack && !focusedPack.installed) {
        state.view = "catalog";
        state.catalogQuery = packName(focusedPack);
        $("#catalogSearch").value = packName(focusedPack);
      }
    }
    render();
    if (["refreshing", "stale-refreshing", "building"].includes(inventory.cache?.state)) {
      watchInventoryRefresh(inventory.generatedAt);
    } else if (!quiet) {
      showNotice(upstream ? "上游版本检查完成" : "本地资源状态已刷新");
    }
  } catch (error) {
    requestError(error);
  } finally {
    refreshButton.disabled = false;
    upstreamButton.disabled = false;
    refreshButton.classList.remove("loading");
    upstreamButton.classList.remove("loading");
    state.refreshing = false;
    icons();
  }
}

function renderStorage() {
  const storage = state.inventory?.storage || {};
  const total = Number(storage.diskTotalBytes) || 0;
  const used = Number(storage.diskUsedBytes) || 0;
  const free = Number(storage.diskFreeBytes) || 0;
  const managed = Number(storage.managedBytes) || 0;
  const managedPending = storage.managedBytes === null || storage.managedBytes === undefined;
  $("#storageFree").textContent = `${formatBytes(free)} 可用`;
  const cacheState = state.inventory?.cache?.state;
  const cacheLabel = ["building", "refreshing", "stale-refreshing"].includes(cacheState) ? "后台刷新中" : formatDate(state.inventory?.generatedAt);
  $("#storageMeta").textContent = `磁盘总计 ${formatBytes(total)} · 资源清单 ${cacheLabel}`;
  $("#storageUsedBar").style.width = `${total ? Math.min(100, used / total * 100) : 0}%`;
  $("#storageManagedBar").style.width = `${total ? Math.min(100, managed / total * 100) : 0}%`;
  $("#storageTrack").setAttribute("aria-label", `磁盘已用 ${formatBytes(used)}，其中 TerraSys 占用 ${formatBytes(managed)}`);
  $("#managedSize").textContent = managedPending ? "计算中" : formatBytes(managed);
  $("#diskUsed").textContent = formatBytes(used);
}

function renderNavigation() {
  const installed = state.packs.filter((pack) => pack.installed);
  const active = (state.maintenance?.jobs || []).filter((job) => ["queued", "running"].includes(job.status));
  $("#versionBadge").textContent = installed.length;
  $("#catalogBadge").textContent = state.packs.filter((pack) => !pack.installed).length;
  $("#localBadge").textContent = state.inventory?.localGroups?.reduce((sum, group) => sum + (group.items?.length || 0), 0) || 0;
  $("#taskBadge").textContent = active.length;
  const commonPack = installed.find((pack) => pack.currentSourceSequence);
  $("#sourceSequence").textContent = commonPack?.currentSourceSequence || "--";
  $("#sourceTimestamp").textContent = commonPack?.currentSourceUpdatedAt ? formatDate(commonPack.currentSourceUpdatedAt) : "没有可信状态";
  const worker = state.maintenance?.worker || {};
  $("#workerState").textContent = worker.online ? "维护服务在线" : "维护服务离线";
  $("#workerState").className = `status-pill ${worker.online ? "" : "error"}`;
  $$("[data-view]").forEach((button) => button.classList.toggle("active", button.dataset.view === state.view));
  $$(".view").forEach((view) => view.classList.toggle("active", view.id === `${state.view}View`));
}

function updateState(pack) {
  if (!pack.installed) return { label: "未安装", tone: "disabled" };
  if (pack.updateAvailable) return { label: "有新版本", tone: "update" };
  if (!pack.sourceSequence) return { label: "版本未知", tone: "error" };
  return { label: "已是最新", tone: "" };
}

function taskForPack(packId) {
  return (state.maintenance?.jobs || []).find((job) =>
    job.resourceId === packId && ["queued", "running"].includes(job.status)
  );
}

async function pollMaintenance() {
  if (state.refreshing || state.maintenancePolling) return;
  state.maintenancePolling = true;
  try {
    const maintenance = await api("/maintenance");
    const terminalTransition = detectJobTransitions(maintenance.jobs || []);
    state.maintenance = maintenance;
    renderNavigation();
    renderVersions();
    renderCatalog();
    renderTasks();
    icons();
    if (terminalTransition) await refresh({ quiet: true, freshInventory: true });
  } catch (error) {
    console.warn("Maintenance polling failed", error);
  } finally {
    state.maintenancePolling = false;
  }
}

function highlightActivityRail() {
  const rail = $("#activityRail");
  rail.classList.remove("attention");
  void rail.offsetWidth;
  rail.classList.add("attention");
  clearTimeout(highlightActivityRail.timer);
  highlightActivityRail.timer = setTimeout(() => rail.classList.remove("attention"), 1600);
}

function renderVersions() {
  const normalized = state.query.trim().toLocaleLowerCase("zh-CN");
  const installed = state.packs.filter((pack) => pack.installed && (
    !normalized || `${packName(pack)} ${pack.name} ${pack.id} ${pack.groupName || ""}`.toLocaleLowerCase("zh-CN").includes(normalized)
  ));
  const advancedActionsReady = Number(state.maintenance?.worker?.schemaVersion || 0) >= 2;
  $("#versionRows").innerHTML = installed.length ? installed.map((pack) => {
    const status = updateState(pack);
    const job = taskForPack(pack.id);
    const focused = state.focusPackId === pack.id;
    const menuOpen = state.menuPackId === pack.id;
    return `<tr data-pack-row="${escapeHtml(pack.id)}" class="${focused ? "focused" : ""}">
      <td><input type="checkbox" data-select-pack="${escapeHtml(pack.id)}" ${state.selected.has(pack.id) ? "checked" : ""} /></td>
      <td><div class="pack-cell">
        <span class="pack-name"><i data-lucide="map"></i><strong>${escapeHtml(packName(pack))}</strong></span>
        <small>${pack.enabled === false ? "已停用，文件保留" : "已启用，参与渲染与索引"}</small>
      </div></td>
      <td><div class="version-cell">
        <span class="mono">序列 ${escapeHtml(pack.sourceSequence || "--")}</span>
        <small>源 ${escapeHtml(formatDate(pack.sourceUpdatedAt))}</small>
        <small>构建 ${escapeHtml(formatDate(pack.generatedAt))}</small>
      </div></td>
      <td><div class="version-cell">
        <span class="state-label ${status.tone}">${escapeHtml(job ? (job.status === "running" ? "执行中" : "等待中") : status.label)}</span>
        <small class="mono">${escapeHtml(pack.upstreamSourceSequence || pack.currentSourceSequence || "--")}</small>
        <small>${escapeHtml(formatDate(pack.upstreamSourceUpdatedAt || pack.currentSourceUpdatedAt))}</small>
      </div></td>
      <td><div class="rollback-cell">
        ${pack.rollbackReady
          ? `<span class="mono">序列 ${escapeHtml(pack.rollbackSourceSequence || "--")}</span><small>${escapeHtml(formatDate(pack.rollbackGeneratedAt))}</small><small>${escapeHtml(formatBytes(pack.rollbackBytes))}</small>`
          : "<span>没有回退副本</span><small>生成新版本后按需保留</small>"}
      </div></td>
      <td><strong>${escapeHtml(formatBytes(pack.bytes))}</strong></td>
      <td><div class="row-actions">
        ${pack.updateAvailable && !job ? `<button class="primary" type="button" data-pack-action="update" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="refresh-cw"></i><span>更新</span></button>` : ""}
        <button type="button" data-pack-menu="${escapeHtml(pack.id)}" title="更多操作" aria-label="${escapeHtml(packName(pack))}更多操作"><i data-lucide="more-vertical"></i></button>
        ${menuOpen ? `<div class="menu">
          <button type="button" data-pack-action="info" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="history"></i><span>版本详情</span></button>
          <button type="button" data-pack-action="verify" data-pack-id="${escapeHtml(pack.id)}" ${advancedActionsReady ? "" : "disabled"}><i data-lucide="shield-check"></i><span>校验完整性</span></button>
          <button type="button" data-pack-action="toggle" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="power"></i><span>${pack.enabled === false ? "启用地图包" : "停用地图包"}</span></button>
          <button type="button" data-pack-action="rebuild" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="hammer"></i><span>重新生成</span></button>
          <button type="button" data-pack-action="rollback" data-pack-id="${escapeHtml(pack.id)}" ${pack.rollbackReady && advancedActionsReady ? "" : "disabled"}><i data-lucide="rotate-ccw"></i><span>回退并保留当前版</span></button>
          <button type="button" data-pack-action="manifest" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="file-down"></i><span>导出清单</span></button>
          <button type="button" data-pack-action="browse" data-pack-id="${escapeHtml(pack.id)}" ${pack.enabled === false ? "disabled" : ""}><i data-lucide="map-pinned"></i><span>在地图中浏览</span></button>
          <button class="danger" type="button" data-pack-action="remove" data-pack-id="${escapeHtml(pack.id)}"><i data-lucide="trash-2"></i><span>受保护删除</span></button>
        </div>` : ""}
      </div></td>
    </tr>`;
  }).join("") : '<tr><td colspan="7"><div class="empty">没有匹配的已安装地图包</div></td></tr>';
  const selectedCount = state.selected.size;
  $("#selectedLabel").textContent = selectedCount ? `已选 ${selectedCount} 项` : "选择地图包";
  $("#selectAllPacks").checked = installed.length > 0 && installed.every((pack) => state.selected.has(pack.id));
  $$("[data-bulk-action]").forEach((button) => {
    button.disabled = selectedCount === 0 || (button.dataset.bulkAction === "verify" && !advancedActionsReady);
  });
}

function resourceStatus(item) {
  if (item.status === "ready") return ["就绪", ""];
  if (item.status === "warning") return ["需检查", "update"];
  if (item.status === "archive") return ["归档", "disabled"];
  if (item.status === "cache") return ["可再生", "disabled"];
  if (item.status === "external") return [item.storageClass === "external-runtime" ? "系统能力" : "外部卷", "disabled"];
  return ["未安装", "disabled"];
}

function localResourceControl(item) {
  const mode = item.managementMode || "system";
  if (mode === "map-packs") {
    return `<button class="command-button" type="button" data-local-view="versions"><i data-lucide="settings-2"></i><span>${escapeHtml(item.managementLabel || "管理")}</span></button>`;
  }
  if (mode === "maintenance") {
    const resourceId = item.managementResourceId || item.id;
    const job = taskForPack(resourceId);
    const check = state.inventory?.updateChecks?.find((entry) => entry.id === resourceId);
    const label = job ? (job.status === "running" ? "执行中" : "等待中")
      : check?.updateAvailable ? (check.action === "rebuild" ? "重建" : "更新")
      : item.managementLabel || "重新获取";
    return `<button class="command-button" type="button" data-local-maintenance="${escapeHtml(resourceId)}" data-local-heavy="${item.managementHeavy ? "true" : "false"}" data-local-resource-name="${escapeHtml(item.name)}" ${job ? "disabled" : ""}><i data-lucide="${job ? "loader-circle" : check?.updateAvailable ? "refresh-cw" : "rotate-ccw"}"></i><span>${escapeHtml(label)}</span></button>`;
  }
  if (mode === "application") {
    return `<a class="command-button local-link-button" href="${escapeHtml(item.managementHref || "/")}"><i data-lucide="external-link"></i><span>${escapeHtml(item.managementLabel || "打开")}</span></a>`;
  }
  return "";
}

function localResourceRow(item, groupName) {
  const [label, tone] = resourceStatus(item);
  const control = localResourceControl(item);
  const subtitle = [groupName, item.subtitle].filter(Boolean).join(" · ");
  return `<div class="resource-row" data-local-resource="${escapeHtml(item.id)}">
    <span class="resource-icon"><i data-lucide="${escapeHtml(item.icon || "database")}"></i></span>
    <span class="resource-copy"><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(subtitle)}</span></span>
    <span class="resource-size">${item.bytes == null ? "Docker 卷" : formatBytes(item.bytes)}</span>
    <span class="resource-controls"><span class="state-label ${tone}">${label}</span>${control}</span>
  </div>`;
}

function renderLocal() {
  const summary = state.inventory?.summary || {};
  const hasActiveJobs = (state.maintenance?.jobs || []).some((job) => ["queued", "running"].includes(job.status));
  $("#resourceSummary").innerHTML = [
    ["当前地图", summary.currentMapBytes],
    ["地图回退", summary.rollbackMapBytes],
    ["源快照回退", summary.rollbackSourceBytes],
    ["可再生缓存", summary.regenerableCacheBytes]
  ].map(([label, bytes]) => `<div class="metric"><span>${label}</span><strong>${formatBytes(bytes || 0)}</strong></div>`).join("");
  const entries = (state.inventory?.localGroups || []).flatMap((group) => (group.items || []).map((item) => ({ item, groupName: group.name })))
    .filter(({ item }) => item.id !== "regenerable-caches" && !(item.status === "missing" && !Number(item.bytes || 0)));
  const manageable = entries.filter(({ item }) => ["map-packs", "maintenance", "application"].includes(item.managementMode));
  const systemManaged = entries.filter(({ item }) => !["map-packs", "maintenance", "application"].includes(item.managementMode));
  const legacyRows = (state.inventory?.legacyPackages || []).map((legacy) => `<div class="resource-row" data-local-resource="legacy:${escapeHtml(legacy.id)}">
    <span class="resource-icon"><i data-lucide="split"></i></span>
    <span class="resource-copy"><strong>${escapeHtml(legacy.name)}</strong><span>${escapeHtml(legacy.reason)} · 建议改用 ${(legacy.replacementPacks || []).map((item) => escapeHtml(item.name)).join("、")}</span></span>
    <span class="resource-size">${formatBytes(legacy.bytes || 0)}</span>
    <span class="resource-controls"><span class="state-label ${legacy.readyToRemove ? "update" : "disabled"}">${legacy.readyToRemove ? "可替代" : "先安装替代包"}</span></span>
  </div>`);
  $("#localGroups").innerHTML = `<section class="resource-group" data-local-management-group="manageable">
      <div class="section-title"><h3>可管理资源</h3><span>${manageable.length + (state.inventory?.caches || []).length} 项</span></div>
      ${manageable.map(({ item, groupName }) => localResourceRow(item, groupName)).join("")}
      ${(state.inventory?.caches || []).map((cache) => `<div class="resource-row" data-local-resource="cache:${escapeHtml(cache.id)}">
        <span class="resource-icon"><i data-lucide="database-zap"></i></span>
        <span class="resource-copy"><strong>${escapeHtml(cache.name)}</strong><span>可再生缓存 · ${escapeHtml(cache.description || cache.pathLabel)}</span></span>
        <span class="resource-size">${formatBytes(cache.bytes || 0)}</span>
        <span class="resource-controls"><span class="state-label disabled">可再生</span><button class="command-button" type="button" data-clear-cache="${escapeHtml(cache.id)}" ${cache.bytes && !(cache.id === "build-temp" && hasActiveJobs) ? "" : "disabled"}><i data-lucide="trash-2"></i><span>${cache.id === "build-temp" && hasActiveJobs ? "使用中" : "清理"}</span></button></span>
      </div>`).join("")}
    </section>
    <section class="resource-group" data-local-management-group="system">
      <div class="section-title"><h3>系统托管与只读资源</h3><span>${systemManaged.length + legacyRows.length} 项</span></div>
      ${systemManaged.map(({ item, groupName }) => localResourceRow(item, groupName)).join("")}
      ${legacyRows.join("")}
    </section>`;
}

function installEstimate(pack) {
  const estimate = Array.isArray(pack.estimatedInstallGiB) ? pack.estimatedInstallGiB : [];
  if (!estimate.length) return pack.sourceSizeMiB ? `源约 ${pack.sourceSizeMiB} MB` : "构建后计量";
  return estimate.length > 1 ? `${estimate[0]}-${estimate.at(-1)} GB` : `${estimate[0]} GB`;
}

function mergeResourceCatalog(baseCatalog, worldCatalog) {
  const regions = new Map((baseCatalog.regions || []).map((region) => [region.id, { ...region }]));
  Object.entries(worldCatalog?.regionPatches || {}).forEach(([regionId, patch]) => {
    if (regions.has(regionId)) regions.set(regionId, { ...regions.get(regionId), ...patch });
  });
  (worldCatalog?.regions || []).forEach((region) => regions.set(region.id, { ...region }));

  const rootOrder = ["north-america", "oceania", "africa", "antarctica", "south-america", "europe", "gf:russia", "asia", "gf:central-america"];
  const root = regions.get(baseCatalog.rootRegion || "world");
  if (root) root.children = rootOrder.filter((id) => regions.has(id));
  for (const [parentId, promotedId] of [["europe", "gf:russia"], ["north-america", "gf:central-america"]]) {
    const parent = regions.get(parentId);
    if (parent) parent.children = (parent.children || []).filter((id) => id !== promotedId);
    const promoted = regions.get(promotedId);
    if (promoted) promoted.parent = root?.id || "world";
  }
  return { ...baseCatalog, worldCatalogVersion: worldCatalog?.version, regions: [...regions.values()] };
}

async function loadResourceCatalog() {
  const [baseResponse, worldResponse] = await Promise.all([
    fetch("/config/resource-catalog.json", { cache: "no-store" }),
    fetch("/config/world-region-catalog.json", { cache: "no-store" })
  ]);
  if (!baseResponse.ok || !worldResponse.ok) throw new Error("资源目录加载失败");
  state.resourceCatalog = mergeResourceCatalog(await baseResponse.json(), await worldResponse.json());
}

function catalogRegion(regionId) {
  return state.resourceCatalog?.regions?.find((region) => region.id === regionId) || null;
}

function catalogRegionName(region) {
  if (!region) return "";
  const fallback = { JP: "日本", TW: "台湾省", HK: "香港特别行政区", MO: "澳门特别行政区", RU: "俄罗斯" };
  if (fallback[region.isoCode]) return fallback[region.isoCode];
  if (region.isoCode && typeof Intl.DisplayNames === "function") {
    try { return new Intl.DisplayNames(["zh-CN"], { type: "region" }).of(region.isoCode) || region.name; } catch {}
  }
  return region.name;
}

function catalogRegionPath(regionId) {
  let current = catalogRegion(regionId);
  const path = [];
  const seen = new Set();
  while (current && !seen.has(current.id)) {
    seen.add(current.id);
    path.unshift(current);
    current = current.parent ? catalogRegion(current.parent) : null;
  }
  return path;
}

function catalogRegionPackIds(region, seen = new Set()) {
  if (!region || seen.has(region.id)) return [];
  seen.add(region.id);
  const ids = [...(region.datasetIds || [])];
  for (const childId of region.children || []) ids.push(...catalogRegionPackIds(catalogRegion(childId), seen));
  return [...new Set(ids)];
}

function renderCatalogBreadcrumb() {
  const path = state.catalogQuery.trim()
    ? [{ id: "world", name: "资源目录" }, { id: "search", name: "搜索结果" }]
    : catalogRegionPath(state.catalogRegionId).map((region, index) => ({ id: region.id, name: index ? catalogRegionName(region) : "资源目录" }));
  $("#catalogBreadcrumb").innerHTML = path.map((item, index) => `${index ? '<i data-lucide="chevron-right"></i>' : ""}<button type="button" data-catalog-region="${escapeHtml(item.id)}" ${item.id === "search" ? "disabled" : ""}>${escapeHtml(item.name)}</button>`).join("");
}

function catalogFolderRow(region) {
  const packs = catalogRegionPackIds(region).map((id) => state.packs.find((pack) => pack.id === id)).filter(Boolean);
  const installed = packs.filter((pack) => pack.installed).length;
  const directCount = (region.children?.length || 0) + (region.datasetIds?.length || 0);
  const meta = packs.length ? `${packs.length} 个地图包 · 已安装 ${installed}` : `${directCount} 个下级区域`;
  return `<button class="catalog-folder-row" type="button" data-catalog-region="${escapeHtml(region.id)}">
    <span class="catalog-folder-icon"><i data-lucide="${escapeHtml(region.icon || "globe-2")}"></i></span>
    <span class="catalog-folder-copy"><strong>${escapeHtml(catalogRegionName(region))}</strong><span>${escapeHtml(meta)}</span></span>
    <span class="catalog-folder-state">${Math.max(0, packs.length - installed)} 可获取</span>
    <i data-lucide="chevron-right"></i>
  </button>`;
}

function catalogPackRow(pack) {
  const job = taskForPack(pack.id);
  return `<div class="catalog-row" data-catalog-pack="${escapeHtml(pack.id)}">
    <span class="pack-cell"><span class="pack-name"><i data-lucide="map"></i><strong>${escapeHtml(packName(pack))}</strong></span><small>${escapeHtml(pack.description || pack.administrativeType || "独立离线地图包")}</small></span>
    <span class="catalog-source"><strong>${escapeHtml(pack.sourceProvider || "开放地图来源")}</strong><span>${escapeHtml(pack.sourceMode === "direct" ? "区域快照" : "从共享快照提取")}</span></span>
    <span class="catalog-estimate"><strong>${escapeHtml(pack.installed ? formatBytes(pack.bytes) : installEstimate(pack))}</strong><span>${pack.installed ? (pack.enabled === false ? "已安装 · 已停用" : "已安装并启用") : "预计安装"}</span></span>
    <span class="catalog-actions">
      <button class="icon-button" type="button" data-locate-pack="${escapeHtml(pack.id)}" title="在地图中定位" aria-label="在地图中定位 ${escapeHtml(packName(pack))}"><i data-lucide="scan-search"></i></button>
      ${pack.installed ? '<span class="state-label">已安装</span>' : `<button class="command-button" type="button" data-catalog-build="${escapeHtml(pack.id)}" ${job || !pack.buildReady ? "disabled" : ""}><i data-lucide="${job ? "loader-circle" : "download"}"></i><span>${job ? "处理中" : pack.buildReady ? "构建" : "源未就绪"}</span></button>`}
    </span>
  </div>`;
}

function catalogResourceState(type) {
  const check = state.inventory?.updateChecks?.find((item) => item.id === type.installResourceId);
  const local = state.inventory?.localGroups?.flatMap((group) => group.items || []).find((item) => item.id === type.inventoryId);
  if (check) {
    if (check.updateAvailable) return { label: check.statusKind === "missing" ? "未安装" : "可处理", tone: "update", action: check.action || "update" };
    return { label: check.statusKind === "current" ? "最新" : "已安装", tone: "ready" };
  }
  if (local) return { label: local.status === "ready" ? (local.bytes ? formatBytes(local.bytes) : "已就绪") : "部分可用", tone: local.status === "ready" ? "ready" : "update" };
  if (type.support === "planned") return { label: "尚未接入", tone: "disabled" };
  return { label: type.support === "ready" ? "已就绪" : "部分可用", tone: type.support === "ready" ? "ready" : "update" };
}

function catalogResourceRow(type) {
  const status = catalogResourceState(type);
  const job = type.installResourceId ? taskForPack(type.installResourceId) : null;
  return `<div class="catalog-resource-row" data-catalog-resource="${escapeHtml(type.id)}">
    <span class="catalog-resource-icon"><i data-lucide="${escapeHtml(type.icon || "layers")}"></i></span>
    <span class="catalog-folder-copy"><strong>${escapeHtml(type.name)}</strong><span>${escapeHtml(type.description || "独立资源")}</span></span>
    <span class="state-label ${status.tone === "update" ? "update" : status.tone === "disabled" ? "disabled" : ""}">${escapeHtml(job ? "处理中" : status.label)}</span>
    ${status.action ? `<button class="icon-button" type="button" data-catalog-resource-update="${escapeHtml(type.installResourceId)}" data-catalog-resource-action="${escapeHtml(status.action)}" ${job ? "disabled" : ""} title="${job ? "处理中" : "安装或更新"}${escapeHtml(type.name)}" aria-label="${job ? "处理中" : "安装或更新"}${escapeHtml(type.name)}"><i data-lucide="${job ? "loader-circle" : "download"}"></i></button>` : '<span class="catalog-resource-spacer"></span>'}
  </div>`;
}

function catalogGroup(title, rows, meta = "") {
  if (!rows.length) return "";
  return `<section class="catalog-group"><div class="section-title"><h3>${escapeHtml(title)}</h3><span>${escapeHtml(meta || `${rows.length} 项`)}</span></div>${rows.join("")}</section>`;
}

function renderCatalog() {
  const query = state.catalogQuery.trim().toLocaleLowerCase("zh-CN");
  renderCatalogBreadcrumb();
  if (!state.resourceCatalog) {
    $("#catalogResults").innerHTML = '<div class="empty">资源目录正在加载</div>';
    return;
  }
  if (query) {
    const packs = state.packs.filter((pack) => `${packName(pack)} ${pack.name} ${pack.id} ${pack.groupName || ""} ${pack.countryId || ""}`.toLocaleLowerCase("zh-CN").includes(query));
    const packIds = new Set(packs.map((pack) => pack.id));
    const regions = state.resourceCatalog.regions.filter((item) => item.id !== "world"
      && `${catalogRegionName(item)} ${item.name || ""} ${item.sourceName || ""} ${item.isoCode || ""}`.toLocaleLowerCase("zh-CN").includes(query)
      && !(item.datasetIds || []).some((id) => packIds.has(id)));
    const types = state.resourceCatalog.resourceTypes.filter((type) => `${type.name} ${type.description || ""}`.toLocaleLowerCase("zh-CN").includes(query));
    const rows = [
      catalogGroup("区域", [...regions.map(catalogFolderRow), ...packs.map(catalogPackRow)], `${regions.length + packs.length} 项`),
      catalogGroup("资源类型", types.map(catalogResourceRow))
    ].join("");
    $("#catalogResults").innerHTML = rows || '<div class="empty">没有匹配的区域或资源</div>';
    return;
  }

  const region = catalogRegion(state.catalogRegionId) || catalogRegion("world");
  if (region.id === "world") {
    const continents = (region.children || []).map(catalogRegion).filter(Boolean);
    const typeById = new Map(state.resourceCatalog.resourceTypes.map((type) => [type.id, type]));
    $("#catalogResults").innerHTML = [
      catalogGroup("地图", continents.map(catalogFolderRow), `${continents.length} 个区域目录`),
      ...(state.resourceCatalog.downloadSections || []).map((section) => catalogGroup(section.name, (section.resourceTypeIds || []).map((id) => typeById.get(id)).filter(Boolean).map(catalogResourceRow)))
    ].join("");
    return;
  }

  const children = (region.children || []).map(catalogRegion).filter(Boolean);
  const packs = (region.datasetIds || []).map((id) => state.packs.find((pack) => pack.id === id)).filter(Boolean)
    .sort((a, b) => Number(a.groupOrder || 0) - Number(b.groupOrder || 0) || Number(a.order || 0) - Number(b.order || 0) || packName(a).localeCompare(packName(b), "zh-CN"));
  $("#catalogResults").innerHTML = [
    catalogGroup("下级区域", children.map(catalogFolderRow), `${children.length} 项`),
    catalogGroup("地图包", packs.map(catalogPackRow), `${packs.length} 项`)
  ].join("") || '<div class="empty">这个目录目前没有可获取的地图包</div>';
}

function activityText(job) {
  const activity = job.progress?.activity;
  if (job.progress?.serviceContinuity) return "当前地图继续可用";
  if (activity && Number.isFinite(Number(activity.processed)) && Number.isFinite(Number(activity.total))) {
    const unit = activity.processedUnit === "tiles" ? "瓦片" : activity.processedUnit || "项";
    return `${Number(activity.processed).toLocaleString("zh-CN")} / ${Number(activity.total).toLocaleString("zh-CN")} ${unit}`;
  }
  if (!activity || !Number.isFinite(Number(activity.rate))) {
    if (job.status === "queued") return `队列第 ${job.progress?.queuePosition || "--"} 位`;
    return job.progress?.kind === "indeterminate" ? "处理中" : "正在计算速率";
  }
  const rate = Number(activity.rate);
  if (rate <= 0) return "正在准备地图要素";
  if (activity.unit === "bytes/s") return `${formatBytes(rate)}/s`;
  const unit = activity.unit === "tiles/s" ? "瓦片/秒" : activity.unit === "features/s" ? "要素/秒" : activity.unit;
  return `${rate.toLocaleString("zh-CN", { maximumFractionDigits: 1 })} ${unit}`;
}

function jobActionText(job) {
  return ({
    build: "安装", update: "更新", rebuild: "重建", rollback: "回退",
    verify: "校验", remove: "移除"
  })[job.action] || job.action || "维护";
}

function jobResultText(job) {
  if (job.status === "cancelled") return "已取消";
  if (job.status === "failed") return "失败";
  if (job.action === "remove") return "已移除";
  if (job.action === "build") return "已安装";
  return "完成";
}

function taskRow(job, active = true) {
  const progress = job.progress || {};
  const determinate = progress.percent !== null && progress.percent !== undefined && Number.isFinite(Number(progress.percent));
  const percent = determinate ? Math.max(0, Math.min(100, Number(progress.percent))) : 0;
  return `<div class="task-row">
    <span class="task-copy"><strong>${escapeHtml(job.label || job.resourceId)} · ${escapeHtml(jobActionText(job))}</strong><span>${escapeHtml(progress.stage || job.message || job.action)}</span></span>
    ${active ? `<span class="progress-cell">
      <span class="progress-track ${determinate ? "" : "indeterminate"}"><span style="width:${determinate ? percent : 36}%"></span></span>
      <span class="progress-meta"><span>${determinate ? `${percent}% · ` : ""}${escapeHtml(activityText(job))}</span><span>${escapeHtml(formatDate(job.startedAt || job.requestedAt))}</span></span>
    </span>` : `<span class="version-cell"><span>${escapeHtml(job.message || job.progress?.stage || "")}</span><small>开始 ${escapeHtml(formatDate(job.startedAt || job.requestedAt))}</small><small>结束 ${escapeHtml(formatDate(job.finishedAt))}</small></span>`}
    ${active
      ? `<button class="command-button cancel" type="button" data-cancel-job="${escapeHtml(job.id)}" ${job.cancelRequested ? "disabled" : ""}><i data-lucide="circle-x"></i><span>${job.cancelRequested ? "停止中" : "取消"}</span></button>`
      : job.status === "failed"
        ? `<button class="command-button" type="button" data-retry-job="${escapeHtml(job.id)}"><i data-lucide="rotate-ccw"></i><span>重试</span></button>`
        : `<span class="state-label ${job.status === "cancelled" ? "disabled" : ""}">${escapeHtml(jobResultText(job))}</span>`}
  </div>`;
}

function renderTasks() {
  const jobs = state.maintenance?.jobs || [];
  const active = jobs.filter((job) => ["queued", "running"].includes(job.status));
  const history = jobs.filter((job) => !["queued", "running"].includes(job.status)).slice(0, 8);
  const checks = state.inventory?.updateChecks || [];
  const orderedChecks = [...checks].sort((left, right) => {
    const leftActive = active.some((job) => job.resourceId === left.id);
    const rightActive = active.some((job) => job.resourceId === right.id);
    return Number(rightActive) - Number(leftActive)
      || Number(right.updateAvailable) - Number(left.updateAvailable)
      || String(left.name).localeCompare(String(right.name), "zh-CN");
  });
  $("#activeTaskCount").textContent = `${active.length} 项`;
  $("#activeTasks").innerHTML = active.length ? active.map((job) => taskRow(job)).join("") : '<div class="empty">当前没有运行或排队的任务</div>';
  $("#updateCount").textContent = `${checks.filter((item) => item.updateAvailable).length} 项可处理`;
  $("#updateRows").innerHTML = orderedChecks.length ? orderedChecks.map((item) => {
    const running = active.find((job) => job.resourceId === item.id);
    return `<div class="task-row">
      <span class="task-copy"><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.reason || "")}</span></span>
      <span class="version-cell">
        <span>源数据 ${escapeHtml(formatDate(item.sourceUpdatedAt || item.installedVersion))}</span>
        <small>本地构建 ${escapeHtml(formatDate(item.builtAt))}</small>
        <small>上游版本 ${escapeHtml(formatDate(item.availableVersion))}</small>
        <small>上次检查 ${escapeHtml(formatDate(item.lastCheckedAt))} · 下次 ${escapeHtml(formatDate(item.nextCheckAt))}</small>
      </span>
      ${running ? '<span class="state-label update">处理中</span>' : item.updateAvailable
        ? `<button class="command-button" type="button" data-resource-update="${escapeHtml(item.id)}" data-resource-action="${escapeHtml(item.action || "update")}"><i data-lucide="${item.action === "rebuild" ? "hammer" : "refresh-cw"}"></i><span>${item.action === "rebuild" ? "重建" : "处理"}</span></button>`
        : '<span class="state-label">最新</span>'}
    </div>`;
  }).join("") : '<div class="empty">没有版本检查记录</div>';
  $("#historyTasks").innerHTML = history.length ? history.map((job) => taskRow(job, false)).join("") : '<div class="empty">尚无任务历史</div>';
}

function render() {
  renderStorage();
  renderNavigation();
  renderVersions();
  renderCatalog();
  renderLocal();
  renderTasks();
  icons();
  if (state.focusPackId) {
    requestAnimationFrame(() => {
      const selector = state.view === "catalog" ? `[data-catalog-pack="${CSS.escape(state.focusPackId)}"]` : `[data-pack-row="${CSS.escape(state.focusPackId)}"]`;
      document.querySelector(selector)?.scrollIntoView({ block: "center" });
    });
    state.focusPackId = null;
  }
}

async function createJob(packId, action) {
  try {
    const confirmToken = action === "remove" ? packId : undefined;
    await api("/maintenance/jobs", {
      method: "POST",
      body: JSON.stringify({ resourceId: packId, action, confirmToken })
    });
    state.menuPackId = null;
    await refresh({ quiet: true });
    render();
    highlightActivityRail();
    showNotice(`${packName(state.packs.find((pack) => pack.id === packId) || { id: packId })}已加入任务队列`);
  } catch (error) {
    requestError(error);
  }
}

async function createBulkJobs(packIds, action) {
  try {
    for (const packId of packIds) {
      await api("/maintenance/jobs", {
        method: "POST",
        body: JSON.stringify({
          resourceId: packId,
          action,
          confirmToken: action === "remove" ? packId : undefined
        })
      });
    }
    state.selected.clear();
    await refresh({ quiet: true });
    render();
    highlightActivityRail();
    showNotice(`${packIds.length} 项任务已加入队列`);
  } catch (error) {
    requestError(error);
  }
}

async function showVersions(pack) {
  try {
    const versions = await api(`/map-packs/${encodeURIComponent(pack.id)}/versions`);
    $("#detailTitle").textContent = `${packName(pack)}版本`;
    $("#detailSubtitle").textContent = "当前、回退与历史清单";
    $("#detailBody").innerHTML = `
      <dl class="version-detail">
        <dt>当前源序列</dt><dd class="mono">${escapeHtml(versions.current.sourceSequence || "--")}</dd>
        <dt>当前构建时间</dt><dd>${escapeHtml(formatDate(versions.current.generatedAt))}</dd>
        <dt>当前文件</dt><dd>${escapeHtml(formatBytes(versions.current.bytes))} · ${versions.current.sizeMatches ? "大小校验通过" : "需要校验"}</dd>
        <dt>回退源序列</dt><dd class="mono">${escapeHtml(versions.rollback.sourceSequence || "--")}</dd>
        <dt>回退构建时间</dt><dd>${escapeHtml(formatDate(versions.rollback.generatedAt))}</dd>
        <dt>回退文件</dt><dd>${versions.rollback.ready ? `${escapeHtml(formatBytes(versions.rollback.bytes))} · ${versions.rollback.sizeMatches ? "大小校验通过" : "需要校验"}` : "没有完整回退版本"}</dd>
      </dl>
      <h3 class="history-heading">历史清单</h3>
      ${(versions.history || []).length ? versions.history.map((item) => `<div class="history-entry">
        <span class="mono">${escapeHtml(item.sourceSequence || "--")}</span>
        <span>${escapeHtml(formatDate(item.generatedAt))}</span>
        <span>${escapeHtml(formatBytes(item.bytes))}</span>
      </div>`).join("") : '<div class="empty">历史清单会在下一次版本替换时开始保留</div>'}`;
    $("#detailDialog").showModal();
    icons();
  } catch (error) {
    requestError(error);
  }
}

async function showManifest(pack) {
  try {
    const manifest = await api(`/map-packs/${encodeURIComponent(pack.id)}/manifest`);
    const blob = new Blob([JSON.stringify(manifest, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `${pack.id}.manifest.json`;
    link.click();
    URL.revokeObjectURL(url);
    showNotice(`${packName(pack)}清单已导出`);
  } catch (error) {
    requestError(error);
  }
}

async function runPackAction(packId, action) {
  const pack = state.packs.find((item) => item.id === packId);
  if (!pack) return;
  if (action === "info") return showVersions(pack);
  if (action === "manifest") return showManifest(pack);
  if (action === "browse") { location.href = `/?pack=${encodeURIComponent(pack.id)}`; return; }
  if (action === "toggle") {
    try {
      await api(`/map-packs/${encodeURIComponent(pack.id)}/activation`, {
        method: "PUT", body: JSON.stringify({ enabled: pack.enabled === false })
      });
      announceResourceChange({ resourceId: pack.id, action: "activation", status: "succeeded" });
      await refresh({ quiet: true });
      showNotice(`${packName(pack)}已${pack.enabled === false ? "启用" : "停用"}`);
    } catch (error) { requestError(error); }
    return;
  }
  if (action === "verify") {
    return createJob(pack.id, "verify");
  }
  if (action === "remove" && !confirm(`移除 ${packName(pack)} 的当前和回退地图文件？源数据会保留，可重新构建。`)) return;
  if (action === "rollback" && !confirm(`将 ${packName(pack)} 切换到回退版本？当前版本会保留为新的回退副本。`)) return;
  if (action === "rebuild" && !confirm(`使用现有源重新生成 ${packName(pack)}？这不会重新下载源数据。`)) return;
  return createJob(pack.id, action);
}

function wireEvents() {
  $$("[data-view]").forEach((button) => button.addEventListener("click", () => {
    state.view = button.dataset.view;
    renderNavigation();
    icons();
  }));
  $("#refreshButton").addEventListener("click", () => refresh({ freshInventory: true }));
  $("#upstreamButton").addEventListener("click", () => refresh({ upstream: true }));
  $("#packSearch").addEventListener("input", (event) => { state.query = event.target.value; renderVersions(); icons(); });
  $("#catalogSearch").addEventListener("input", (event) => {
    state.catalogQuery = event.target.value;
    renderCatalog();
    icons();
  });
  $("#selectAllPacks").addEventListener("change", (event) => {
    const normalized = state.query.trim().toLocaleLowerCase("zh-CN");
    const visible = state.packs.filter((pack) => pack.installed && (
      !normalized || `${packName(pack)} ${pack.name} ${pack.id} ${pack.groupName || ""}`.toLocaleLowerCase("zh-CN").includes(normalized)
    ));
    visible.forEach((pack) => event.target.checked ? state.selected.add(pack.id) : state.selected.delete(pack.id));
    renderVersions(); icons();
  });
  document.addEventListener("click", async (event) => {
    const select = event.target.closest("[data-select-pack]");
    if (select) {
      select.checked ? state.selected.add(select.dataset.selectPack) : state.selected.delete(select.dataset.selectPack);
      renderVersions(); icons(); return;
    }
    const menu = event.target.closest("[data-pack-menu]");
    if (menu) {
      state.menuPackId = state.menuPackId === menu.dataset.packMenu ? null : menu.dataset.packMenu;
      renderVersions(); icons(); return;
    }
    const action = event.target.closest("[data-pack-action]");
    if (action) { state.menuPackId = null; await runPackAction(action.dataset.packId, action.dataset.packAction); return; }
    const cancel = event.target.closest("[data-cancel-job]");
    if (cancel) {
      try { await api(`/maintenance/jobs/${encodeURIComponent(cancel.dataset.cancelJob)}`, { method: "DELETE" }); await refresh({ quiet: true }); }
      catch (error) { requestError(error); }
      return;
    }
    const retry = event.target.closest("[data-retry-job]");
    if (retry) {
      try {
        await api(`/maintenance/jobs/${encodeURIComponent(retry.dataset.retryJob)}/retry`, { method: "POST" });
        await refresh({ quiet: true });
        highlightActivityRail();
      } catch (error) { requestError(error); }
      return;
    }
    const resourceUpdate = event.target.closest("[data-resource-update]");
    if (resourceUpdate) { await createJob(resourceUpdate.dataset.resourceUpdate, resourceUpdate.dataset.resourceAction || "update"); return; }
    const catalogRegionButton = event.target.closest("[data-catalog-region]");
    if (catalogRegionButton && catalogRegionButton.dataset.catalogRegion !== "search") {
      state.catalogRegionId = catalogRegionButton.dataset.catalogRegion;
      state.catalogQuery = "";
      $("#catalogSearch").value = "";
      renderCatalog();
      icons();
      return;
    }
    const catalogResourceUpdate = event.target.closest("[data-catalog-resource-update]");
    if (catalogResourceUpdate) {
      await createJob(catalogResourceUpdate.dataset.catalogResourceUpdate, catalogResourceUpdate.dataset.catalogResourceAction || "update");
      return;
    }
    const localView = event.target.closest("[data-local-view]");
    if (localView) {
      state.view = localView.dataset.localView;
      renderNavigation();
      icons();
      return;
    }
    const localMaintenance = event.target.closest("[data-local-maintenance]");
    if (localMaintenance) {
      const resourceName = localMaintenance.dataset.localResourceName || "该资源";
      if (localMaintenance.dataset.localHeavy === "true" && !confirm(`${resourceName}属于大型资源，重新处理可能耗时较长并占用额外磁盘空间。继续吗？`)) return;
      await createJob(localMaintenance.dataset.localMaintenance, "update");
      return;
    }
    const clearCache = event.target.closest("[data-clear-cache]");
    if (clearCache) {
      const cacheId = clearCache.dataset.clearCache;
      if (!confirm("清理该可再生缓存？需要时系统会重新生成。")) return;
      try {
        await api(`/caches/${encodeURIComponent(cacheId)}?confirm=${encodeURIComponent(cacheId)}`, { method: "DELETE" });
        await refresh({ quiet: true, freshInventory: true });
        showNotice("缓存已清理");
      } catch (error) { requestError(error); }
      return;
    }
    const catalogBuild = event.target.closest("[data-catalog-build]");
    if (catalogBuild) { await createJob(catalogBuild.dataset.catalogBuild, "build"); return; }
    const locatePack = event.target.closest("[data-locate-pack]");
    if (locatePack) { location.href = `/?coverage=${encodeURIComponent(locatePack.dataset.locatePack)}`; return; }
    const bulk = event.target.closest("[data-bulk-action]");
    if (bulk) {
      const packIds = [...state.selected].filter((packId) => {
        const pack = state.packs.find((item) => item.id === packId);
        return pack && (bulk.dataset.bulkAction !== "update" || pack.updateAvailable);
      });
      if (!packIds.length) {
        showNotice("所选地图包均已是最新版本");
        return;
      }
      if (bulk.dataset.bulkAction === "remove" && !confirm(`移除所选 ${packIds.length} 个地图包的当前与回退文件？源数据会保留。`)) return;
      await createBulkJobs(packIds, bulk.dataset.bulkAction);
      return;
    }
    if (!event.target.closest(".menu")) {
      if (state.menuPackId) { state.menuPackId = null; renderVersions(); icons(); }
    }
  });
  $$("[data-close-dialog]").forEach((button) => button.addEventListener("click", () => $("#detailDialog").close()));
}

wireEvents();
icons();
await loadResourceCatalog();
await refresh({ quiet: true });
state.polling = setInterval(() => pollMaintenance(), 3000);
window.addEventListener("beforeunload", () => clearInterval(state.polling));
