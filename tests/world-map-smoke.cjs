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
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("/api/")) errors.push(message.text());
  });

  await page.goto(`${baseUrl}/`, { waitUntil: "load" });
  await page.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 90000 });
  if (!await page.locator("body").evaluate((body) => body.classList.contains("panel-collapsed"))) {
    throw new Error("The side panel should be collapsed on first load.");
  }
  await page.getByRole("button", { name: "展开侧栏", exact: true }).click();
  await page.getByRole("button", { name: "系统", exact: true }).click();
  await page.getByRole("button", { name: "管理资源", exact: true }).click();
  await page.waitForURL("**/resources.html");
  await page.waitForFunction(() => document.querySelectorAll("#versionRows tr[data-pack-row]").length >= 2, null, { timeout: 90000 });
  await page.getByRole("button", { name: /添加区域/ }).click();
  await page.locator("#catalogSearch").fill("日本");
  const locate = page.getByRole("button", { name: /在地图中定位 日本/ });
  await locate.waitFor({ state: "visible" });
  await locate.click();

  await page.waitForURL("**/?coverage=gf-japan");
  await page.waitForFunction(() => document.querySelector("#coveragePromptTitle")?.textContent.includes("日本") && !document.querySelector("#coveragePrompt")?.hidden, null, { timeout: 30000 });
  await page.getByRole("button", { name: "展开侧栏", exact: true }).click();
  const overview = await page.evaluate(async () => {
    const image = new Image();
    image.src = "/assets/overview/gray-earth.jpg?v=mercator-4096-20260801";
    await image.decode();
    return { width: image.naturalWidth, height: image.naturalHeight };
  });
  if (overview.width !== 4096 || overview.height !== 4096) {
    throw new Error(`Offline world overview is not a WebGL-safe Web Mercator square: ${overview.width}x${overview.height}.`);
  }
  await page.screenshot({ path: path.join(outputDir, "world-region-prompt.png") });

  await page.locator("#onlineMapShortcut").click();
  await page.locator("#mapSourcePopover").waitFor({ state: "visible" });
  const japanCoverage = await page.locator("#mapCoverageStatus").textContent();
  if (!japanCoverage.includes("日本") || !japanCoverage.includes("未安装")) {
    throw new Error(`Map source control did not reflect Japan offline coverage: ${japanCoverage}`);
  }
  await page.locator("#mapSourceCloseButton").click();
  await page.locator("#legendShortcut").click();
  const overviewLegend = await page.locator("#legendPopover").innerText();
  if (!overviewLegend.includes("离线全球概览") || !overviewLegend.includes("全球低缩放概览") || !overviewLegend.includes("国家边界")) {
    throw new Error(`Global overview legend did not describe the visible low-zoom map: ${overviewLegend}`);
  }
  await page.locator("#legendCloseButton").click();
  await page.locator("#onlineMapShortcut").click();
  await page.screenshot({ path: path.join(outputDir, "map-source-menu-japan.png") });
  await page.locator('#mapSourcePopover [data-online-provider="osm"]').click();
  if (await page.locator("#onlineMapShortcut").getAttribute("aria-pressed") !== "true") {
    throw new Error("Online OSM view did not become active.");
  }
  await page.waitForFunction(() => document.querySelector("#onlineMapShortcut")?.title.includes("已连接"), null, { timeout: 15000 });
  const toastBox = await page.locator("#toast").boundingBox();
  const shortcutBox = await page.locator("#onlineMapShortcut").boundingBox();
  if (toastBox && shortcutBox) {
    const overlaps = toastBox.x < shortcutBox.x + shortcutBox.width
      && toastBox.x + toastBox.width > shortcutBox.x
      && toastBox.y < shortcutBox.y + shortcutBox.height
      && toastBox.y + toastBox.height > shortcutBox.y;
    if (overlaps) throw new Error("Map source toast overlaps the source shortcut.");
  }
  await page.locator("#legendShortcut").click();
  const onlineOsmLegend = await page.locator("#legendPopover").innerText();
  if (!onlineOsmLegend.includes("OSM 标准地图已连接") || !onlineOsmLegend.includes("OSM Carto 栅格样式")) {
    throw new Error(`Online OSM legend did not follow the source switch: ${onlineOsmLegend}`);
  }
  await page.locator("#legendCloseButton").click();
  await page.screenshot({ path: path.join(outputDir, "world-region-online.png") });

  await page.locator("#layersShortcut").click();
  await page.locator('#layersPopover [data-online-provider="openfreemap"]').click();
  await page.waitForFunction(() => document.querySelector("#onlineMapShortcut")?.title.includes("OpenFreeMap") && document.querySelector('[data-online-provider="openfreemap"]')?.classList.contains("active"), null, { timeout: 25000 });
  if (await page.locator('#layersPopover [data-theme].active').count() !== 0) {
    throw new Error("An offline base-map style still appears active while OpenFreeMap is rendering.");
  }
  await page.locator("#legendShortcut").click();
  const openFreeMapLegend = await page.locator("#legendPopover").innerText();
  if (!openFreeMapLegend.includes("OpenFreeMap") || !openFreeMapLegend.includes("交互矢量样式")) {
    throw new Error(`OpenFreeMap legend did not follow the source switch: ${openFreeMapLegend}`);
  }
  await page.locator("#legendCloseButton").click();
  await page.screenshot({ path: path.join(outputDir, "world-region-openfreemap.png") });
  await page.locator("#layersShortcut").click();
  await page.locator('#layersPopover [data-theme="osm-carto"]').click();
  if (await page.locator("#onlineMapShortcut").getAttribute("aria-pressed") !== "false") {
    throw new Error("Selecting local OSM Original did not remove the online layer covering it.");
  }
  if (!(await page.locator('#mapSourcePopover [data-online-provider="offline"]').evaluate((button) => button.classList.contains("active")))) {
    throw new Error("Selecting local OSM Original did not synchronize the offline source control.");
  }
  if (!(await page.locator('#layersPopover [data-theme="osm-carto"]').evaluate((button) => button.classList.contains("active")))) {
    throw new Error("Local OSM Original did not become the visibly active base-map style.");
  }
  await page.locator('#layersPopover [data-online-provider="osm"]').click();
  await page.waitForFunction(() => document.querySelector("#onlineMapShortcut")?.title.includes("OSM 标准地图已连接"), null, { timeout: 15000 });

  await page.locator("#coverageDownloadButton").click();
  await page.waitForURL("**/resources.html?pack=gf-japan");
  await page.waitForFunction(() => document.querySelector('[data-catalog-pack="gf-japan"]'), null, { timeout: 90000 });
  if (await page.getByRole("button", { name: "构建", exact: true }).count() !== 1) {
    throw new Error("World-map download prompt did not hand off to the selected offline package.");
  }

  await page.goto(`${baseUrl}/?coverage=jiangsu`, { waitUntil: "load" });
  await page.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 30000 });
  await page.waitForFunction(() => document.querySelector("#mapCoverageStatus")?.textContent.includes("江苏省已安装并启用"), null, { timeout: 15000 });
  await page.locator("#onlineMapShortcut").click();
  await page.locator('#mapSourcePopover [data-online-provider="offline"]').click();
  if (await page.locator("#onlineMapShortcut").getAttribute("aria-pressed") !== "false") {
    throw new Error("Online OSM view did not turn off.");
  }

  const cartoLagPage = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  let cartoLagTileRequests = 0;
  let cartoLagVectorRequests = 0;
  cartoLagPage.on("request", (request) => {
    if (request.url().includes("/osm-carto/tile/")) cartoLagTileRequests += 1;
    if (request.url().includes("/tiles/jiangsu.pmtiles")) cartoLagVectorRequests += 1;
  });
  await cartoLagPage.route("**/api/map-packs", async (route) => {
    const response = await route.fetch();
    const inventory = await response.json();
    inventory.osmCartoPackIds = [];
    await route.fulfill({ response, json: inventory });
  });
  await cartoLagPage.addInitScript(() => {
    localStorage.setItem("terrasys-theme", "osm-carto");
    localStorage.setItem("terrasys-online-map", "false");
  });
  await cartoLagPage.goto(`${baseUrl}/?lon=118.89574&lat=32.05272&zoom=9`, { waitUntil: "load" });
  await cartoLagPage.waitForFunction(() => document.querySelector("#mapSourceStatus")?.textContent.includes("交互矢量")
    && document.querySelector("#mapCoverageStatus")?.textContent.includes("OSM 原版后台同步中"), null, { timeout: 30000 });
  await cartoLagPage.waitForTimeout(1800);
  if (cartoLagTileRequests !== 0) {
    throw new Error("An out-of-date OSM Carto renderer still requested blank raster tiles with no ready packs.");
  }
  if (cartoLagVectorRequests < 1) {
    throw new Error("A newly installed region did not retain its PMTiles vector fallback while OSM Carto was synchronizing.");
  }
  await cartoLagPage.screenshot({ path: path.join(outputDir, "pending-carto-vector-fallback.png") });
  await cartoLagPage.unrouteAll({ behavior: "wait" });
  await cartoLagPage.close();

  const fallbackPage = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await fallbackPage.route("https://tile.openstreetmap.org/**", (route) => route.abort("internetdisconnected"));
  await fallbackPage.addInitScript(() => {
    localStorage.setItem("terrasys-online-map", "true");
    localStorage.setItem("terrasys-online-provider", "osm");
  });
  await fallbackPage.goto(`${baseUrl}/?coverage=gf-japan`, { waitUntil: "load" });
  await fallbackPage.locator("#coveragePrompt").waitFor({ state: "visible", timeout: 15000 });
  await fallbackPage.waitForFunction(() => {
    const shortcut = document.querySelector("#onlineMapShortcut");
    return shortcut?.title.includes("OpenFreeMap") && shortcut.classList.contains("fallback");
  }, null, { timeout: 25000 });
  if (!(await fallbackPage.locator("#onlineMapShortcut").evaluate((button) => button.classList.contains("fallback")))) {
    throw new Error("OSM failure did not switch to the OpenFreeMap vector fallback.");
  }
  await fallbackPage.screenshot({ path: path.join(outputDir, "world-region-online-vector-fallback.png") });
  await fallbackPage.close();

  const degradedPage = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await degradedPage.route("https://tile.openstreetmap.org/**", (route) => route.abort("internetdisconnected"));
  await degradedPage.route("https://tiles.openfreemap.org/**", (route) => route.abort("internetdisconnected"));
  await degradedPage.addInitScript(() => {
    localStorage.setItem("terrasys-online-map", "true");
    localStorage.setItem("terrasys-online-provider", "osm");
  });
  await degradedPage.goto(`${baseUrl}/?coverage=gf-japan`, { waitUntil: "load" });
  await degradedPage.waitForFunction(() => {
    const shortcut = document.querySelector("#onlineMapShortcut");
    return shortcut?.title.includes("在线不可用") && shortcut.classList.contains("degraded");
  }, null, { timeout: 25000 });
  if (!(await degradedPage.locator("#onlineMapShortcut").evaluate((button) => button.classList.contains("degraded")))) {
    throw new Error("Failure of both online providers did not expose the offline overview fallback state.");
  }
  await degradedPage.screenshot({ path: path.join(outputDir, "world-region-online-fallback.png") });
  await degradedPage.close();

  const boundaryPayload = await page.evaluate(async () => {
    const response = await fetch("/api/map-pack-boundaries", { cache: "no-store" });
    return response.json();
  });
  const pointInRing = (longitude, latitude, ring) => {
    let inside = false;
    for (let current = 0, previous = ring.length - 1; current < ring.length; previous = current++) {
      const [currentLongitude, currentLatitude] = ring[current];
      const [previousLongitude, previousLatitude] = ring[previous];
      if ((currentLatitude > latitude) !== (previousLatitude > latitude)
          && longitude < ((previousLongitude - currentLongitude) * (latitude - currentLatitude)) / (previousLatitude - currentLatitude) + currentLongitude) {
        inside = !inside;
      }
    }
    return inside;
  };
  const boundaryContains = (name, longitude, latitude) => {
    const boundary = boundaryPayload.boundaries[name];
    return boundary.include.some((ring) => pointInRing(longitude, latitude, ring))
      && !boundary.exclude.some((ring) => pointInRing(longitude, latitude, ring));
  };
  if (!boundaryContains("taiwan", 121.56, 25.04) || boundaryContains("fujian", 121.56, 25.04)) {
    throw new Error("Taipei is not distinguished from Fujian by the offline package boundaries.");
  }

  const taiwanPage = await browser.newPage({ viewport: { width: 760, height: 900 } });
  await taiwanPage.goto(`${baseUrl}/?coverage=gf-taiwan`, { waitUntil: "load" });
  await taiwanPage.locator("#coveragePrompt").waitFor({ state: "visible", timeout: 30000 });
  const taiwanPrompt = await taiwanPage.locator("#coveragePromptTitle").textContent();
  if (!taiwanPrompt.includes("台湾省未安装") || /Taiwan/i.test(taiwanPrompt)) {
    throw new Error(`Taiwan offline prompt was not localized: ${taiwanPrompt}`);
  }
  await taiwanPage.locator("#onlineMapShortcut").click();
  const taiwanCoverage = await taiwanPage.locator("#mapCoverageStatus").textContent();
  if (!taiwanCoverage.includes("台湾") || !taiwanCoverage.includes("未安装")) {
    throw new Error(`Map source coverage did not refresh for Taiwan: ${taiwanCoverage}`);
  }
  await taiwanPage.screenshot({ path: path.join(outputDir, "map-source-menu-taiwan.png") });
  await taiwanPage.close();

  const movementPage = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  await movementPage.addInitScript(() => {
    localStorage.setItem("terrasys-online-map", "false");
    localStorage.setItem("terrasys-theme", "osm-carto");
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
  await movementPage.goto(`${baseUrl}/?lon=118.89574&lat=32.05272&zoom=6&overview-regression=1`, { waitUntil: "load" });
  await movementPage.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 30000 });
  await movementPage.waitForTimeout(2200);
  await movementPage.evaluate(() => {
    const originalSetStyle = maplibregl.Map.prototype.setStyle;
    window.__terrasysSetStyleCalls = 0;
    maplibregl.Map.prototype.setStyle = function (...args) {
      window.__terrasysSetStyleCalls += 1;
      return originalSetStyle.apply(this, args);
    };
  });
  const movementCanvas = movementPage.locator("canvas.maplibregl-canvas");
  const movementBox = await movementCanvas.boundingBox();
  if (!movementBox) throw new Error("World overview movement test could not locate the map canvas.");
  const movementY = movementBox.y + movementBox.height / 2;
  const movementLeft = movementBox.x + movementBox.width * 0.2;
  const movementRight = movementBox.x + movementBox.width * 0.82;
  await movementPage.mouse.move(movementRight, movementY);
  await movementPage.mouse.down();
  await movementPage.mouse.move(movementLeft, movementY, { steps: 8 });
  await movementPage.mouse.up();
  await movementPage.waitForTimeout(1800);
  await movementPage.evaluate(() => {
    if (!window.__terrasysMapInstance) throw new Error("The movement test did not capture the active MapLibre map.");
    window.__terrasysMapInstance.jumpTo({ center: [123.29027, 32.05272], zoom: 6 });
  });
  await movementPage.waitForFunction(() => {
    const map = window.__terrasysMapInstance;
    if (!map || map.getLayoutProperty("local-osm-carto-raster", "visibility") !== "visible") return false;
    return map.getStyle().layers.some((layer) => ["jiangsu", "jiangsu-details"].includes(layer.source)
      && map.getLayoutProperty(layer.id, "visibility") !== "none");
  }, null, { timeout: 10000 });
  if (await movementPage.evaluate(() => window.__terrasysSetStyleCalls) !== 0) {
    throw new Error("Panning still rebuilds the complete MapLibre style.");
  }
  if (await movementPage.locator("#coveragePrompt").isVisible()) {
    throw new Error(`China-coast panning produced a false offline-pack prompt: ${await movementPage.locator("#coveragePromptTitle").textContent()}`);
  }
  const eastAttribution = await movementPage.locator(".maplibregl-ctrl-attrib-inner").textContent();
  if (!eastAttribution.includes("Made with Natural Earth")) {
    throw new Error("The offline world overview disappeared after panning away from an installed region.");
  }
  if (!(await movementPage.locator("#mapSourceStatus").textContent()).includes("离线全球概览")) {
    throw new Error("The map source control did not switch to the persistent offline overview.");
  }
  const edgeLayerState = await movementPage.evaluate(() => {
    const map = window.__terrasysMapInstance;
    if (!map) throw new Error("The movement test did not capture the active MapLibre map.");
    const localRasterVisibility = map.getLayoutProperty("local-osm-carto-raster", "visibility");
    const jiangsuLayers = map.getStyle().layers.filter((layer) => ["jiangsu", "jiangsu-details"].includes(layer.source));
    const visibleJiangsuLayers = jiangsuLayers.filter((layer) => map.getLayoutProperty(layer.id, "visibility") !== "none").length;
    const bounds = map.getBounds();
    return {
      localRasterVisibility,
      visibleJiangsuLayers,
      jiangsuLayerCount: jiangsuLayers.length,
      center: map.getCenter().toArray(),
      bounds: [bounds.getWest(), bounds.getSouth(), bounds.getEast(), bounds.getNorth()]
    };
  });
  if (edgeLayerState.localRasterVisibility !== "visible") {
    throw new Error(`Panning the center outside Jiangsu hid OSM Carto while Jiangsu was still inside the viewport: ${JSON.stringify(edgeLayerState)}`);
  }
  if (edgeLayerState.visibleJiangsuLayers < 1) {
    throw new Error(`Panning the center outside Jiangsu hid its vector layers while Jiangsu was still inside the viewport: ${JSON.stringify(edgeLayerState)}`);
  }
  await movementPage.evaluate(() => {
    if (!window.__terrasysMapInstance) throw new Error("The movement test did not capture the active MapLibre map.");
    window.__terrasysMapInstance.jumpTo({ center: [118.89574, 32.05272], zoom: 6 });
  });
  await movementPage.waitForTimeout(1800);
  if (await movementPage.evaluate(() => window.__terrasysSetStyleCalls) !== 0) {
    throw new Error("Returning to an installed region rebuilt the complete MapLibre style.");
  }
  if (!(await movementPage.locator("#mapCoverageStatus").textContent()).includes("江苏省已安装并启用")) {
    throw new Error("Returning from the world overview did not restore Jiangsu coverage.");
  }
  await movementPage.screenshot({ path: path.join(outputDir, "world-overview-pan-return.png") });

  await movementPage.goto(`${baseUrl}/?lon=-30&lat=30&zoom=6&overview-regression=2`, { waitUntil: "load" });
  await movementPage.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 30000 });
  await movementPage.waitForTimeout(1800);
  if (await movementPage.locator("#coveragePrompt").isVisible()) {
    throw new Error(`The North Atlantic inherited a rectangular world-pack prompt: ${await movementPage.locator("#coveragePromptTitle").textContent()}`);
  }
  await movementPage.goto(`${baseUrl}/?lon=-74.006&lat=40.7128&zoom=6&overview-regression=usa`, { waitUntil: "load" });
  await movementPage.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 30000 });
  await movementPage.waitForTimeout(1200);
  if (await movementPage.locator("#coveragePrompt").isVisible()) {
    throw new Error("The 100 km United States overview still displayed an automatic download prompt.");
  }
  await movementPage.evaluate(() => window.__terrasysMapInstance?.jumpTo({ zoom: 8 }));
  await movementPage.locator("#coveragePrompt").waitFor({ state: "visible", timeout: 15000 });
  const automaticUsPrompt = await movementPage.locator("#coveragePromptTitle").textContent();
  if (!automaticUsPrompt.includes("美国")) {
    throw new Error(`New York did not resolve through the United States polygon: ${automaticUsPrompt}`);
  }
  await movementPage.goto(`${baseUrl}/?lon=139.6917&lat=35.6895&zoom=6&overview-regression=3`, { waitUntil: "load" });
  await movementPage.waitForFunction(() => document.querySelector("#systemState")?.textContent === "本地在线", null, { timeout: 30000 });
  await movementPage.waitForFunction(() => {
    const map = window.__terrasysMapInstance;
    if (!map?.loaded()) return false;
    return map.queryRenderedFeatures({ layers: ["world-vector-major-road"] }).length > 0
      && map.queryRenderedFeatures({ layers: ["world-vector-place-label"] }).length > 0;
  }, null, { timeout: 15000 });
  if (await movementPage.locator("#coveragePrompt").isVisible()) {
    throw new Error("The 100 km Japan overview still displayed an automatic download prompt.");
  }
  const japanOverviewState = await movementPage.evaluate(() => {
    const map = window.__terrasysMapInstance;
    const layers = map.getStyle().layers;
    const layerIndex = (id) => layers.findIndex((layer) => layer.id === id);
    return {
      roads: map.queryRenderedFeatures({ layers: ["world-vector-major-road"] }).length,
      places: map.queryRenderedFeatures({ layers: ["world-vector-place-label"] }).length,
      localRasterIndex: layerIndex("local-osm-carto-raster"),
      worldRoadIndex: layerIndex("world-vector-major-road"),
      worldPlaceIndex: layerIndex("world-vector-place-label")
    };
  });
  if (japanOverviewState.roads < 1 || japanOverviewState.places < 1
      || japanOverviewState.worldRoadIndex <= japanOverviewState.localRasterIndex
      || japanOverviewState.worldPlaceIndex <= japanOverviewState.localRasterIndex) {
    throw new Error(`The global vector skeleton was missing or covered at Japan z6: ${JSON.stringify(japanOverviewState)}`);
  }
  await movementPage.evaluate(() => window.__terrasysMapInstance?.jumpTo({ zoom: 8 }));
  await movementPage.locator("#coveragePrompt").waitFor({ state: "visible", timeout: 15000 });
  const automaticJapanPrompt = await movementPage.locator("#coveragePromptTitle").textContent();
  if (!automaticJapanPrompt.includes("日本") || /Kyūshū|Kyushu/i.test(automaticJapanPrompt)) {
    throw new Error(`Tokyo did not resolve through the country polygon: ${automaticJapanPrompt}`);
  }
  await movementPage.goto(`${baseUrl}/?lon=121&lat=23.7&zoom=3&overview-regression=taiwan-label`, { waitUntil: "load" });
  await movementPage.waitForFunction(() => {
    const map = window.__terrasysMapInstance;
    if (!map?.loaded() || !map.getLayer("world-vector-country-label")) return false;
    return map.querySourceFeatures("world-vector-overview", { sourceLayer: "place" })
      .some((feature) => /Taiwan|中华民国|台湾/.test(JSON.stringify(feature.properties)));
  }, null, { timeout: 30000 });
  const taiwanLabelState = await movementPage.evaluate(() => {
    const map = window.__terrasysMapInstance;
    const sourceFeatures = map.querySourceFeatures("world-vector-overview", { sourceLayer: "place" })
      .map((feature) => feature.properties)
      .filter((properties) => /Taiwan|中华民国|台湾/.test(JSON.stringify(properties)));
    return {
      sourceFeatures,
      countryTextField: map.getLayoutProperty("world-vector-country-label", "text-field"),
      placeTextField: map.getLayoutProperty("world-vector-place-label", "text-field")
    };
  });
  if (!taiwanLabelState.sourceFeatures.length
      || !JSON.stringify(taiwanLabelState.countryTextField).includes("台湾省")
      || !JSON.stringify(taiwanLabelState.placeTextField).includes("台湾省")) {
    throw new Error(`Taiwan was not normalized to 台湾省 in every global overview label layer: ${JSON.stringify(taiwanLabelState)}`);
  }
  await movementPage.screenshot({ path: path.join(outputDir, "world-overview-taiwan-province.png") });
  await movementPage.close();

  await browser.close();
  if (errors.length) throw new Error(errors.join("\n"));
  console.log("World map smoke test passed: source menu, live offline coverage, localized prompts, automatic fallback, and package handoff.");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
