const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const chromeCandidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"
];
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
  || chromeCandidates.find((candidate) => fs.existsSync(candidate));

const outputDir = path.resolve(__dirname, "..", "runtime", "resource-console-smoke");
const baseUrl = process.env.TERRASYS_UI_URL || "http://127.0.0.1:8080";
fs.mkdirSync(outputDir, { recursive: true });

(async () => {
  const launchOptions = { headless: true, args: ["--no-proxy-server"] };
  if (executablePath) launchOptions.executablePath = executablePath;
  const browser = await chromium.launch(launchOptions);
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(`console: ${message.text()}`);
  });
  page.on("pageerror", (error) => errors.push(`page: ${error.message}`));
  page.on("requestfailed", (request) => errors.push(`request: ${request.url()} ${request.failure()?.errorText || "failed"}`));

  await page.goto(`${baseUrl}/resources.html`, { waitUntil: "load", timeout: 60000 });
  await page.waitForFunction(() => document.querySelectorAll("#versionRows tr[data-pack-row]").length >= 2, null, { timeout: 60000 });
  const packSummary = await page.evaluate(async () => {
    const response = await fetch("/api/map-packs", { cache: "no-store" });
    if (!response.ok) throw new Error(`Map pack inventory returned ${response.status}.`);
    return response.json();
  });
  await page.waitForFunction(
    (expected) => document.querySelectorAll("#versionRows tr[data-pack-row]").length === expected,
    packSummary.installed,
    { timeout: 60000 }
  );

  if ((await page.title()) !== "资源与版本 - TerraSys") throw new Error("The TerraSys resource-console title is missing.");
  const brandAsset = await page.locator(".header-brand-mark").evaluate((image) => ({
    complete: image.complete,
    naturalWidth: image.naturalWidth,
    naturalHeight: image.naturalHeight
  }));
  if (!brandAsset.complete || brandAsset.naturalWidth < 1 || brandAsset.naturalHeight < 1) {
    throw new Error("The TerraSys resource-console mark did not load.");
  }
  if (!(await page.locator(".storage-key").innerText()).includes("TerraSys 占用")) {
    throw new Error("The resource-console storage label still uses the legacy product name.");
  }
  const managedBarWidth = await page.locator("#storageManagedBar").evaluate((element) => element.getBoundingClientRect().width);
  if (managedBarWidth <= 0) throw new Error("The blue TerraSys storage segment is not rendered in the usage track.");

  const rows = await page.locator("#versionRows tr[data-pack-row]").count();
  if (rows !== packSummary.installed) throw new Error(`Expected ${packSummary.installed} installed packs, found ${rows}.`);
  if (!/维护服务(在线|离线)/.test(await page.locator("#workerState").innerText())) {
    throw new Error("Maintenance worker state was not rendered.");
  }
  if (!(await page.locator("#activityRail").isVisible())) {
    throw new Error("The persistent task and update rail is not visible.");
  }
  if (await page.locator(".version-table").evaluate((element) => element.scrollWidth > element.clientWidth + 2)) {
    throw new Error("Version table overflows its container.");
  }
  const workspaceTopBeforeNotice = await page.locator(".workspace").evaluate((element) => element.getBoundingClientRect().top);
  await page.locator("#refreshButton").click();
  await page.locator("#notice").waitFor({ state: "visible", timeout: 5000 });
  const noticeLayout = await page.locator("#notice").evaluate((element) => ({
    position: getComputedStyle(element).position,
    right: getComputedStyle(element).right,
    workspaceTop: document.querySelector(".workspace").getBoundingClientRect().top
  }));
  if (noticeLayout.position !== "fixed" || noticeLayout.right === "auto" || noticeLayout.workspaceTop !== workspaceTopBeforeNotice) {
    throw new Error("Resource notices still occupy a full layout row instead of floating above the page.");
  }
  await page.screenshot({ path: path.join(outputDir, "floating-notice-desktop.png"), fullPage: true });
  await page.locator('[data-pack-menu="jiangsu"]').click();
  await page.locator('[data-pack-action="info"][data-pack-id="jiangsu"]').click();
  await page.locator("#detailDialog").waitFor({ state: "visible" });
  if ((await page.locator("#detailBody").innerText()).includes("当前源序列\n--")) {
    throw new Error("Version detail does not expose a trusted current source sequence.");
  }
  await page.locator("[data-close-dialog]").click();

  await page.screenshot({ path: path.join(outputDir, "versions-desktop.png"), fullPage: true });
  await page.getByRole("button", { name: /添加区域/ }).click();
  const catalogText = await page.locator("#catalogResults").innerText();
  for (const expected of ["地图", "世界地图", "全球概览地图", "全球海拔校正", "天气预报", "航海地图", "旅行指南", "其他地图", "语音提示（TTS）", "地图字体"]) {
    if (!catalogText.includes(expected)) throw new Error(`OsmAnd-style resource catalog is missing: ${expected}`);
  }
  if (await page.locator('[data-catalog-region="china"]').count()) {
    throw new Error("China should not be promoted to the root resource directory.");
  }
  if (await page.locator("#catalogResults .catalog-folder-row").count() !== 9) {
    throw new Error("The root catalog does not expose the expected continent and world-region entries.");
  }
  await page.screenshot({ path: path.join(outputDir, "catalog-root-desktop.png"), fullPage: true });
  await page.locator('[data-catalog-region="asia"]').click();
  await page.locator('[data-catalog-region="china"]').click();
  if (await page.locator('[data-catalog-pack]').count() !== packSummary.provinceCount) {
    throw new Error("Asia > China does not show every independent province-level map package.");
  }
  if (!(await page.locator("#catalogBreadcrumb").innerText()).includes("亚洲") || !(await page.locator("#catalogBreadcrumb").innerText()).includes("中国")) {
    throw new Error("The hierarchical catalog breadcrumb is incomplete.");
  }
  await page.screenshot({ path: path.join(outputDir, "catalog-china-desktop.png"), fullPage: true });
  await page.locator("#catalogSearch").fill("日本");
  if (await page.locator('[data-catalog-pack="gf-japan"]').count() !== 1) {
    throw new Error("Global catalog search did not find Japan.");
  }
  await page.screenshot({ path: path.join(outputDir, "catalog-desktop.png"), fullPage: true });
  await page.getByRole("button", { name: /本地资源/ }).click();
  await page.waitForFunction(() => document.querySelectorAll(".resource-row").length >= 8);
  const localText = await page.locator("#localGroups").innerText();
  for (const expected of [
    "完整恢复包",
    "可再生",
    "系统能力",
    "地址检索索引",
    "本地 OSM 原版渲染"
  ]) {
    if (!localText.includes(expected)) {
      throw new Error(`Local resource classification is missing: ${expected}`);
    }
  }
  if (!/\d+ 个已验证/.test(localText)) {
    throw new Error("Verified recovery-kit accounting was not rendered.");
  }
  if (!localText.includes("外部卷") && !localText.includes("需检查")) {
    throw new Error("Search-index validity state was not rendered.");
  }
  for (const group of ["manageable", "system"]) {
    if (!(await page.locator(`[data-local-management-group="${group}"]`).isVisible())) {
      throw new Error(`Local resource management group is missing: ${group}`);
    }
  }
  const manageableRows = page.locator('[data-local-management-group="manageable"] .resource-row');
  if (await manageableRows.count() < 8) throw new Error("Too few local resources expose real management actions.");
  if (await manageableRows.locator(".command-button").count() !== await manageableRows.count()) {
    throw new Error("A manageable local resource is missing its management control.");
  }
  if (await page.locator('[data-local-resource="map-build-staging"]').count()) {
    throw new Error("Empty staging resources should not appear in the Local tab.");
  }
  const terrainMaintenance = page.locator('[data-local-resource="terrain"] [data-local-maintenance="terrain"]');
  if (await terrainMaintenance.count() !== 1 || !(await terrainMaintenance.textContent()).includes("同步")) {
    throw new Error("Elevation grids do not expose their non-destructive synchronization action.");
  }
  if (await terrainMaintenance.locator('[data-lucide="trash-2"]').count()) {
    throw new Error("Elevation synchronization is incorrectly presented as a destructive action.");
  }
  if (await page.locator('[data-local-resource="osm-carto-renderer"]').count() !== 1) {
    throw new Error("The local OSM Carto renderer is missing from Local resources.");
  }
  await page.screenshot({ path: path.join(outputDir, "local-resources-desktop.png"), fullPage: true });
  if (!(await page.locator("#activityRail").isVisible()) || !(await page.locator("#localView").isVisible())) {
    throw new Error("The task rail did not remain visible beside the selected resource view.");
  }
  if (await page.locator("[data-view=tasks]").count()) {
    throw new Error("Tasks still replace the resource browsing workspace.");
  }
  await page.screenshot({ path: path.join(outputDir, "local-with-task-rail-desktop.png"), fullPage: true });

  if (errors.length) throw new Error(errors.join("\n"));
  console.log(JSON.stringify({ ok: true, rows, screenshots: outputDir }, null, 2));
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
