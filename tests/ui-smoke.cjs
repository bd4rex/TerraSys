const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const chromeCandidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"
];
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
  || chromeCandidates.find((candidate) => fs.existsSync(candidate));

const outputDir = path.resolve(__dirname, "..", "runtime", "ui-smoke");
const baseUrl = process.env.TERRASYS_UI_URL || "http://127.0.0.1:8080";
fs.mkdirSync(outputDir, { recursive: true });

(async () => {
  const launchOptions = { headless: true, args: ["--no-proxy-server"] };
  if (executablePath) launchOptions.executablePath = executablePath;
  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const errors = [];
  let localCartoRequestCount = 0;
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(`console: ${message.text()}`);
  });
  page.on("pageerror", (error) => errors.push(`page: ${error.message}`));
  page.on("requestfailed", (request) => {
    const errorText = request.failure()?.errorText || "failed";
    const isExpectedTileAbort = request.url().endsWith(".pmtiles") && errorText.includes("ERR_ABORTED");
    const isExpectedCartoTileAbort = request.url().includes("/osm-carto/tile/") && errorText.includes("ERR_ABORTED");
    const isExpectedApiAbort = request.url().includes("/api/") && request.method() === "GET"
      && (errorText.includes("ERR_ABORTED") || errorText.includes("ERR_NETWORK_CHANGED"));
    if (!isExpectedTileAbort && !isExpectedCartoTileAbort && !isExpectedApiAbort) errors.push(`request: ${request.url()} ${errorText}`);
  });
  page.on("request", (request) => {
    if (request.url().includes("/osm-carto/tile/")) localCartoRequestCount += 1;
  });
  await page.addInitScript(() => {
    localStorage.setItem("giss-route-recents", "[]");
    window.__terrasysMapInstance = null;
    Object.defineProperty(window, "maplibregl", {
      configurable: true,
      set(value) {
        const MapLibreMap = value.Map;
        value.Map = class TestMap extends MapLibreMap {
          constructor(...args) {
            super(...args);
            window.__terrasysMapInstance = this;
          }
        };
        Object.defineProperty(window, "maplibregl", { configurable: true, writable: true, value });
      }
    });
  });
  await page.route("**/api/maintenance", async (route) => {
    if (route.request().method() === "POST" && route.request().url().endsWith("/jobs")) {
      const payload = route.request().postDataJSON();
      return route.fulfill({
        status: 202,
        contentType: "application/json",
        body: JSON.stringify({
          id: "ui-verify-job", resourceId: payload.resourceId, action: payload.action,
          label: `${payload.resourceId}地图包`, status: "queued"
        })
      });
    }
    if (route.request().method() !== "GET") return route.continue();
    const now = Date.now();
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        settings: { enabled: false, resources: {} },
        worker: { online: true, status: "running", heartbeatAt: new Date(now).toISOString() },
        jobs: [
          {
            id: "ui-running-anhui", resourceId: "anhui", action: "update", label: "安徽省地图包",
            status: "running", startedAt: new Date(now - 94000).toISOString(), requestedAt: new Date(now - 96000).toISOString(),
            cancelRequested: false, progress: {
              kind: "staged", percent: 68, stage: "生成地图瓦片", step: 4, steps: 5, queuePosition: null,
              activity: { kind: "generation", rate: 1900, unit: "tiles/s", processed: 853000, processedUnit: "tiles", bytes: 470810624 }
            }
          },
          {
            id: "ui-queued-jiangsu", resourceId: "jiangsu", action: "update", label: "江苏地图包",
            status: "queued", startedAt: null, requestedAt: new Date(now - 78000).toISOString(),
            cancelRequested: false, progress: { kind: "queued", percent: 0, stage: "等待本机维护服务", step: 0, steps: 5, queuePosition: 1 }
          }
        ]
      })
    });
  });

  await page.goto(`${baseUrl}/?lon=118.89574&lat=32.05272&zoom=16`, { waitUntil: "load" });
  await page.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 90000 });
  await page.waitForTimeout(2500);

  if ((await page.title()) !== "TerraSys 个人离线地图") throw new Error("The TerraSys browser title is missing.");
  const brandAsset = await page.locator(".brand-mark").evaluate((image) => ({
    complete: image.complete,
    naturalWidth: image.naturalWidth,
    naturalHeight: image.naturalHeight
  }));
  if (!brandAsset.complete || brandAsset.naturalWidth < 1 || brandAsset.naturalHeight < 1) {
    throw new Error("The TerraSys application mark did not load.");
  }
  if (!(await page.locator('link[rel="icon"]').getAttribute("href"))?.includes("terrasys-app-icon.png")) {
    throw new Error("The TerraSys browser icon is missing.");
  }
  const storageMigration = await page.evaluate(() => ({
    current: localStorage.getItem("terrasys-route-recents"),
    legacy: localStorage.getItem("giss-route-recents")
  }));
  if (storageMigration.current !== "[]" || storageMigration.legacy !== null) {
    throw new Error(`Legacy browser settings were not migrated: ${JSON.stringify(storageMigration)}`);
  }
  if (!(await page.locator("body").evaluate((body) => body.classList.contains("panel-collapsed")))) {
    throw new Error("The side panel is not collapsed on first load.");
  }
  if (await page.locator("#sidePanel").getAttribute("aria-hidden") !== "true") {
    throw new Error("The initially collapsed side panel remains exposed to assistive technology.");
  }

  const canvas = page.locator("canvas.maplibregl-canvas");
  if (await canvas.count() !== 1) throw new Error("MapLibre canvas was not created.");
  const box = await canvas.boundingBox();
  if (!box || box.width < 1000 || box.height < 700) throw new Error("Map canvas has an unexpected size.");
  const metricScales = await page.locator(".maplibregl-ctrl-scale").allTextContents();
  if (metricScales.length !== 1 || /ft|mi|nm/.test(metricScales[0])) {
    throw new Error(`The scale control is not metric-only: ${JSON.stringify(metricScales)}`);
  }

  const attribution = page.getByRole("link", { name: "OpenStreetMap contributors" });
  if (await attribution.count() < 1) throw new Error("OpenStreetMap attribution is missing.");
  if (await page.getByRole("link", { name: /OpenStreetMap Carto/ }).count() !== 1) {
    throw new Error("The local OpenStreetMap Carto layer is not active by default.");
  }
  if (localCartoRequestCount < 1) {
    throw new Error("The selected local OpenStreetMap Carto layer requested no rendered tiles.");
  }
  if (await page.locator('#sidePanel [data-tab="layers"], #sidePanel [data-tab-panel="layers"]').count()) {
    throw new Error("The duplicate layer panel is still present in the left sidebar.");
  }
  const cartoTile = await page.evaluate(async () => {
    const response = await fetch("/osm-carto/tile/16/54394/26600.png", { cache: "no-store" });
    return { status: response.status, type: response.headers.get("content-type"), bytes: (await response.blob()).size };
  });
  if (cartoTile.status !== 200 || cartoTile.type !== "image/png" || cartoTile.bytes < 1000) {
    throw new Error(`The local OSM Carto tile endpoint is invalid: ${JSON.stringify(cartoTile)}`);
  }
  if (!(await page.locator("#modeBanner").isHidden())) throw new Error("Mode banner is visible while no tool is active.");

  await page.locator("#layersShortcut").click();
  await page.locator("#layersPopover").waitFor({ state: "visible" });
  const layerPanelText = await page.locator("#layersPopover").innerText();
  for (const heading of ["覆盖层", "显示设置"]) {
    if (!layerPanelText.includes(heading)) throw new Error(`Layer panel is missing ${heading}.`);
  }
  if (layerPanelText.includes("底图") || layerPanelText.includes("工具")) {
    throw new Error("The layer panel still contains source or tool controls.");
  }
  const consolidatedLayerGroups = await page.locator("#layersPopover [data-layer-toggle]").evaluateAll((inputs) => inputs.map((input) => input.dataset.layerToggle));
  for (const group of ["land", "roads", "buildings", "poi", "labels", "boundaries", "personalPoints", "tracks", "photos", "terrain", "contours", "weather", "nautical", "emergency"]) {
    if (!consolidatedLayerGroups.includes(group)) throw new Error(`The consolidated right-side panel is missing ${group}.`);
  }
  await page.locator('#layersPopover [data-layer-toggle="emergency"]').check();
  if (!(await page.locator("#emergencyFilters").isVisible()) || await page.locator("#emergencyFilters input").count() !== 5) {
    throw new Error("Emergency resource filters were not migrated to the right-side panel.");
  }
  await page.screenshot({ path: path.join(outputDir, "layers-panel.png"), fullPage: false });
  await page.locator('#layersPopover [data-layer-toggle="emergency"]').uncheck();
  await page.locator('#layersPopover [data-scale-unit="imperial"]').click();
  await page.waitForFunction(() => /ft|mi/.test(document.querySelector(".maplibregl-ctrl-scale")?.textContent || ""));
  await page.locator('#layersPopover [data-scale-unit="nautical"]').click();
  await page.waitForFunction(() => /nm/.test(document.querySelector(".maplibregl-ctrl-scale")?.textContent || ""));
  await page.locator('#layersPopover [data-scale-unit="metric"]').click();
  await page.waitForFunction(() => !/ft|mi|nm/.test(document.querySelector(".maplibregl-ctrl-scale")?.textContent || ""));
  const onlineSources = await page.evaluate(() => {
    const map = window.__terrasysMapInstance;
    return ["online-osm", "online-openfreemap", "online-esri-imagery", "online-opentopomap"]
      .map((id) => ({ id, source: Boolean(map.getSource(id)) }));
  });
  if (onlineSources.some((item) => !item.source)) {
    throw new Error(`Online base-map sources are incomplete: ${JSON.stringify(onlineSources)}`);
  }
  if (await page.locator("#layersPopover [data-theme], #layersPopover [data-online-provider]").count()) {
    throw new Error("The layer panel still duplicates base-map source controls.");
  }
  await page.getByRole("button", { name: "关闭图层" }).click();
  if (await page.locator("#mapShortcuts [data-map-tool], #layersPopover [data-map-tool]").count()) {
    throw new Error("The redundant map-tool menu is still present.");
  }
  await page.locator("#onlineMapShortcut").click();
  if (await page.locator("#mapSourcePopover .map-source-options > button").count() !== 6
      || await page.locator("#mapSourcePopover [data-theme]").count() !== 2
      || await page.locator("#mapSourcePopover [data-online-provider]").count() !== 4) {
    throw new Error("The source menu does not contain the two offline and four online base maps.");
  }
  await page.locator("#mapSourceCloseButton").click();

  await page.locator("#searchInput").fill("118.89574, 32.05272");
  await page.locator("#searchSuggestions").waitFor({ state: "visible" });
  if (!(await page.locator("#searchSuggestions").innerText()).includes("坐标")) {
    throw new Error("Unified search did not recognize a coordinate query.");
  }
  await page.locator("#searchInput").fill("");
  await page.locator("#searchInput").press("Escape");

  await page.getByRole("button", { name: "路线", exact: true }).first().click();
  await page.locator("#routePanel").waitFor({ state: "visible" });
  const routePanelText = await page.locator("#routePanel").innerText();
  for (const label of ["起点", "终点", "交换", "当前位置", "本次使用 Valhalla 离线路由引擎"]) {
    if (!routePanelText.includes(label)) throw new Error(`Route planner is missing ${label}.`);
  }
  for (const mode of ["驾车", "骑行", "步行"]) {
    if (await page.locator(`#routePanel [data-route-costing]`).filter({ hasText: mode }).count() !== 1) {
      throw new Error(`Route planner is missing ${mode}.`);
    }
  }
  await page.getByRole("button", { name: "关闭路线" }).click();

  await page.screenshot({ path: path.join(outputDir, "desktop.png"), fullPage: false });

  await page.getByRole("button", { name: "展开侧栏", exact: true }).click();
  await page.waitForFunction(() => !document.body.classList.contains("panel-collapsed"));

  if (await page.locator("#collectionFilter option").count() < 4) throw new Error("Default collection filters are missing.");
  await page.getByRole("button", { name: "管理集合" }).click();
  await page.locator("#collectionDialog").waitFor({ state: "visible" });
  if (await page.locator(".collection-manager-item").count() < 3) throw new Error("Collection manager did not list default collections.");
  await page.screenshot({ path: path.join(outputDir, "collection-manager.png"), fullPage: false });
  await page.getByRole("button", { name: "关闭集合管理" }).click();

  await page.locator('[data-kind="place"]').first().click();
  await page.locator("#detailPanel").waitFor({ state: "visible" });
  if ((await page.locator("#detailEyebrow").textContent()) !== "我的个人点位") {
    throw new Error("Personal place did not open the unified detail panel.");
  }
  if (!(await page.locator("#detailMediaSection").isVisible())) throw new Error("Personal media section is hidden.");
  await page.waitForTimeout(1500);
  await page.screenshot({ path: path.join(outputDir, "personal-detail.png"), fullPage: false });
  await page.locator("#detailSaveButton").click();
  await page.locator("#placeDialog").waitFor({ state: "visible" });
  await page.locator("#placeDialog [data-dialog-close]").first().click({ force: true });
  await page.getByRole("button", { name: "关闭详情" }).click();

  await page.locator("#searchInput").fill("南京");
  await page.locator("#searchInput").press("Enter");
  await page.waitForFunction(() => document.querySelectorAll('[data-search-id]').length > 0, null, { timeout: 30000 });
  const referenceResult = page.locator('[data-search-id]').filter({ hasText: "离线 OSM" }).first();
  if (await referenceResult.count() !== 1) throw new Error("Offline OSM reference search returned no result.");
  await referenceResult.click({ force: true });
  await page.getByRole("button", { name: "保存为个人点位" }).waitFor({ state: "visible" });
  const referenceDetailText = await page.locator("#detailPanel").innerText();
  if (!referenceDetailText.includes("开放资料") || !referenceDetailText.includes("完整 OSM 标签")
      || !referenceDetailText.includes("附近地点") || !referenceDetailText.includes("到这里")) {
    throw new Error(`Reference detail is missing exploration context: ${referenceDetailText}`);
  }
  await page.waitForTimeout(3000);
  await page.screenshot({ path: path.join(outputDir, "search-results.png"), fullPage: false });
  await page.getByRole("button", { name: "保存为个人点位" }).click();
  await page.locator("#placeDialog").waitFor({ state: "visible" });
  if ((await page.locator("#placeDialogTitle").textContent()) !== "保存参考地点") {
    throw new Error("Reference result did not open the copy-as-personal workflow.");
  }
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.locator("#searchInput").fill("");
  await page.locator("#searchInput").press("Enter");
  await page.waitForFunction(() => document.querySelector("#searchSummary")?.textContent === "最近更新");
  await page.waitForTimeout(500);

  // Raster Carto matches the OSM website; switch to the interactive vector style for feature collection.
  await page.locator("#onlineMapShortcut").click();
  await page.locator('#mapSourcePopover [data-theme="vector"]').click();
  await page.waitForTimeout(1200);

  // The search leaves the map centered on Nanjing South; click a stable POI-dense area east of the station.
  await page.mouse.click(1050, 275);
  await page.locator("#detailPanel").waitFor({ state: "visible", timeout: 5000 });
  if (!(await page.locator("#detailTitle").textContent()).trim()) throw new Error("Base-map feature detail has no title.");
  await page.getByRole("button", { name: "附近地点" }).click();
  await page.waitForFunction(() => document.querySelector("#searchSummary")?.textContent.includes("附近"));
  if (await page.locator('[data-search-id]').count() < 1) throw new Error("Nearby reference lookup returned no visible results.");
  await page.waitForTimeout(1500);
  await page.screenshot({ path: path.join(outputDir, "feature-detail.png"), fullPage: false });
  await page.locator("#detailSaveButton").click();
  await page.locator("#placeDialog").waitFor({ state: "visible" });
  if ((await page.locator("#placeDialogTitle").textContent()) !== "保存参考地点") {
    throw new Error("Base-map feature did not open the collection workflow.");
  }
  if (!(await page.locator('#placeCollectionChoices input[value="default-favorites"]').isChecked())) {
    throw new Error("Collected base-map feature did not default to the favorites collection.");
  }
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  await page.getByRole("button", { name: "关闭详情" }).click();
  await page.locator("#searchInput").press("Enter");
  await page.waitForFunction(() => document.querySelector("#searchSummary")?.textContent === "最近更新");

  await page.getByRole("button", { name: "系统" }).click();
  const referenceCount = Number((await page.locator("#referenceCount").textContent()).replace(/\D/g, ""));
  if (referenceCount < 100000) throw new Error("Reference index readiness count is missing or too small.");
  if ((await page.locator("#mapSnapshot").textContent()) === "--") throw new Error("Map snapshot date is missing.");
  if ((await page.locator("#backupState").textContent()) === "--") throw new Error("Backup readiness is missing.");
  if (await page.locator(".region-pack-item").count() < 2) throw new Error("Region pack center did not list installed province packs.");
  if ((await page.locator("#activePackName").textContent()) !== "全部已安装区域") {
    throw new Error("Installed regions are not displayed together by default.");
  }
  if (await page.locator("#viewSwitcher").count()) throw new Error("The redundant bottom region navigation is still present.");
  const mapPackInventory = await page.evaluate(async () => {
    const response = await fetch("/api/map-packs", { cache: "no-store" });
    if (!response.ok) throw new Error(`Map pack inventory returned ${response.status}.`);
    return response.json();
  });
  if (mapPackInventory.provinceCount !== 34 || mapPackInventory.independentProvinceCount < 2) {
    throw new Error("Province installation summary is incomplete.");
  }
  if (mapPackInventory.packs.length < 500 || mapPackInventory.packs.filter((pack) => pack.kind !== "province").length < 500) {
    throw new Error("Global map-pack catalog is incomplete.");
  }
  const availableProvinceCount = mapPackInventory.provinceCount - mapPackInventory.independentProvinceCount;
  if (!(await page.locator("#availablePackSummary").textContent()).includes(`${availableProvinceCount} 省可独立获取`)) {
    throw new Error("Resource availability summary is missing.");
  }
  const resourcePage = await context.newPage();
  await resourcePage.goto(`${baseUrl}/resources.html`, { waitUntil: "load", timeout: 90000 });
  await resourcePage.waitForFunction(() => document.querySelectorAll("#versionRows tr[data-pack-row]").length >= 2);
  if (await resourcePage.locator("#versionRows tr[data-pack-row]").count() < 2) {
    throw new Error("Standalone resource console does not show every installed map pack.");
  }
  await resourcePage.getByRole("button", { name: /本地资源/ }).click();
  if (await resourcePage.locator(".resource-row").count() < 15) {
    throw new Error("Standalone local resource inventory is incomplete.");
  }
  if (await resourcePage.locator('[data-local-resource="osm-carto-renderer"]').count() !== 1) {
    throw new Error("The local OSM Carto renderer is missing from resource management.");
  }
  if (!(await resourcePage.locator("#activityRail").isVisible()) || !(await resourcePage.locator("#localView").isVisible())) {
    throw new Error("The persistent task rail did not remain visible beside local resources.");
  }
  if (await resourcePage.locator("#updateRows .task-row").count() < 8) {
    throw new Error("Standalone resource update checks are incomplete.");
  }
  await resourcePage.screenshot({ path: path.join(outputDir, "resource-console.png"), fullPage: false });
  await resourcePage.close();
  const verifyRequest = page.waitForRequest((request) => request.url().endsWith("/api/maintenance/jobs")
    && request.method() === "POST" && request.postDataJSON()?.action === "verify");
  await page.getByRole("button", { name: "校验 江苏省" }).click();
  const queuedVerification = await verifyRequest;
  if (queuedVerification.postDataJSON()?.resourceId !== "jiangsu") {
    throw new Error("Jiangsu verification did not use the maintenance queue.");
  }
  await page.waitForFunction(() => document.querySelector("#toast")?.textContent.includes("后台队列"), null, { timeout: 30000 });
  await page.getByRole("button", { name: "聚焦 江苏省" }).click();
  await page.waitForFunction(() => document.querySelector("#activePackName")?.textContent === "江苏省");
  await page.waitForTimeout(2200);
  if (!(await page.getByRole("button", { name: "江苏" }).count())) throw new Error("Jiangsu province view was not rendered.");
  await page.screenshot({ path: path.join(outputDir, "region-pack-center.png"), fullPage: false });
  await page.getByRole("button", { name: "系统", exact: true }).click();
  await page.getByRole("button", { name: "聚焦 安徽省" }).click();
  await page.waitForFunction(() => document.querySelector("#activePackName")?.textContent === "安徽省");
  await page.waitForTimeout(2200);
  await page.screenshot({ path: path.join(outputDir, "system-readiness.png"), fullPage: false });
  await page.getByRole("button", { name: "我的地图" }).click();

  await page.getByRole("button", { name: "添加点位" }).click();
  if (!(await page.locator("#modeBanner").isVisible())) throw new Error("Add-place mode banner did not appear.");
  await page.mouse.click(900, 450);
  const dialog = page.locator("#placeDialog");
  await dialog.waitFor({ state: "visible" });
  if (!(await page.locator("#placeCoordinates").textContent())) throw new Error("Place coordinates were not populated.");
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  if (!(await page.locator("#modeBanner").isHidden())) throw new Error("Closing the editor did not leave add-place mode.");

  const contourShortcut = page.getByRole("button", { name: "等高线", exact: true });
  if (await contourShortcut.count() !== 1) throw new Error("Contour shortcut is missing.");
  await contourShortcut.click();
  if (await contourShortcut.getAttribute("aria-pressed") !== "true") throw new Error("Contour shortcut did not enable contours.");
  const contourLabelStyles = await page.evaluate(() => {
    const map = window.__terrasysMapInstance;
    return {
      minorFilter: map.getFilter("terrain-contour-labels-minor"),
      minorSize: map.getLayoutProperty("terrain-contour-labels-minor", "text-size"),
      minorOpacity: map.getPaintProperty("terrain-contour-labels-minor", "text-opacity"),
      majorSize: map.getLayoutProperty("terrain-contour-labels", "text-size"),
      minorVisibility: map.getLayoutProperty("terrain-contour-labels-minor", "visibility")
    };
  });
  if (!JSON.stringify(contourLabelStyles.minorFilter).includes('"level"')
      || !JSON.stringify(contourLabelStyles.minorFilter).includes(",0]")
      || !Array.isArray(contourLabelStyles.minorSize)
      || contourLabelStyles.majorSize !== 10
      || !Array.isArray(contourLabelStyles.minorOpacity)
      || contourLabelStyles.minorVisibility === "none") {
    throw new Error(`Minor contour labels are not styled independently: ${JSON.stringify(contourLabelStyles)}`);
  }

  const legendShortcut = page.getByRole("button", { name: "图例", exact: true });
  await legendShortcut.click();
  if (!(await page.locator("#legendPopover").isVisible())) throw new Error("Legend shortcut did not open the legend.");
  const vectorLegend = await page.locator("#legendPopover").innerText();
  if (!vectorLegend.includes("离线交互矢量") || !vectorLegend.includes("符号可随图层开关") || !vectorLegend.includes("植被与绿地")) {
    throw new Error(`Vector legend did not reflect the rendered base map: ${vectorLegend}`);
  }
  if (!vectorLegend.includes("已开启的独立叠加层") || !vectorLegend.includes("主等高线") || !vectorLegend.includes("次等高线高度")) {
    throw new Error(`Legend did not separate enabled overlays from the base map: ${vectorLegend}`);
  }
  await page.locator("#legendDetails summary").click();
  const vectorDetailLegend = await page.locator("#legendDetails").innerText();
  if (!vectorDetailLegend.includes("住宅用地") || !vectorDetailLegend.includes("自行车道") || !vectorDetailLegend.includes("门牌号码")) {
    throw new Error(`Expanded vector legend is incomplete: ${vectorDetailLegend}`);
  }
  await page.getByRole("button", { name: "关闭图例", exact: true }).click();
  if (!(await page.locator("#legendPopover").isHidden())) throw new Error("Legend did not close.");

  await page.locator("#onlineMapShortcut").click();
  await page.locator('#mapSourcePopover [data-theme="osm-carto"]').click();
  await page.waitForTimeout(1800);
  await legendShortcut.click();
  const originalLegend = await page.locator("#legendPopover").innerText();
  if (!originalLegend.includes("离线 OSM 原版") || !originalLegend.includes("OSM Carto 栅格样式") || !originalLegend.includes("公园与绿地")) {
    throw new Error(`OSM Original legend did not follow the base-map switch: ${originalLegend}`);
  }
  const originalDetailLegend = await page.locator("#legendDetails").innerText();
  if (!originalDetailLegend.includes("普通道路 / 支路") || !originalDetailLegend.includes("工业用地") || !originalDetailLegend.includes("餐饮 / 常用设施")) {
    throw new Error(`Expanded OSM legend did not follow the base-map switch: ${originalDetailLegend}`);
  }
  if (originalLegend === vectorLegend) throw new Error("Legend content stayed static after switching the base map.");
  await page.getByRole("button", { name: "关闭图例", exact: true }).click();
  await page.locator("#onlineMapShortcut").click();
  await page.locator('#mapSourcePopover [data-theme="vector"]').click();
  await page.waitForTimeout(1800);
  const richDetails = await page.evaluate(async () => {
    const response = await fetch("/api/map-packs", { cache: "no-store" });
    const inventory = await response.json();
    const installed = inventory.packs.filter((pack) => pack.installed);
    const fields = new Set();
    for (const pack of installed) {
      if (!pack.richDetailsReady || !pack.detailsUrl) throw new Error(`${pack.id} rich details are unavailable.`);
      const metadata = await new pmtiles.PMTiles(`${location.origin}${pack.detailsUrl}`).getMetadata();
      const layer = metadata.vector_layers?.find((item) => item.id === "poi_detail");
      if (!layer) throw new Error(`${pack.id} has no poi_detail layer.`);
      Object.keys(layer.fields || {}).forEach((field) => fields.add(field));
    }
    return { count: installed.length, fields: [...fields] };
  });
  for (const field of ["opening_hours", "phone", "website", "wheelchair", "brand", "operator"]) {
    if (!richDetails.fields.includes(field)) throw new Error(`Rich-detail tiles are missing ${field}.`);
  }
  const coordinateBox = await page.locator("#coordinateReadout").boundingBox();
  const desktopAttributionBox = await page.locator(".maplibregl-ctrl-attrib").boundingBox();
  if (coordinateBox && desktopAttributionBox) {
    const overlaps = coordinateBox.x < desktopAttributionBox.x + desktopAttributionBox.width
      && coordinateBox.x + coordinateBox.width > desktopAttributionBox.x
      && coordinateBox.y < desktopAttributionBox.y + desktopAttributionBox.height
      && coordinateBox.y + coordinateBox.height > desktopAttributionBox.y;
    if (overlaps) throw new Error("Coordinate readout overlaps map attribution.");
  }
  await page.screenshot({ path: path.join(outputDir, "desktop-explore.png"), fullPage: false });

  await page.setViewportSize({ width: 760, height: 900 });
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 30000 });
  await page.waitForTimeout(1800);
  const narrowBox = await page.locator("canvas.maplibregl-canvas").boundingBox();
  if (!narrowBox || narrowBox.width !== 760 || narrowBox.height !== 900) throw new Error("Narrow viewport map is not full screen.");
  await page.screenshot({ path: path.join(outputDir, "narrow.png"), fullPage: false });

  await page.setViewportSize({ width: 560, height: 900 });
  await page.getByRole("button", { name: "展开侧栏", exact: true }).click();
  await page.getByRole("button", { name: "系统" }).click();
  await page.screenshot({ path: path.join(outputDir, "system-narrow.png"), fullPage: false });

  await browser.close();
  if (errors.length) throw new Error(errors.join("\n"));
  console.log("UI smoke test passed: TerraSys branding, default-collapsed sidebar, map, details, collections, readiness, theme, and narrow layout.");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
