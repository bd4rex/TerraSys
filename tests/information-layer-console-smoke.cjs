const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const chromeCandidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"
];
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
  || chromeCandidates.find((candidate) => fs.existsSync(candidate));
const outputDir = path.resolve(__dirname, "..", "runtime", "information-layer-console-smoke");
const baseUrl = process.env.TERRASYS_UI_URL || "http://127.0.0.1:8080";
fs.mkdirSync(outputDir, { recursive: true });

(async () => {
  const launchOptions = { headless: true, args: ["--no-proxy-server"] };
  if (executablePath) launchOptions.executablePath = executablePath;
  const browser = await chromium.launch(launchOptions);
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on("console", (message) => { if (message.type() === "error") errors.push(`console: ${message.text()}`); });
  page.on("pageerror", (error) => errors.push(`page: ${error.message}`));
  page.on("requestfailed", (request) => errors.push(`request: ${request.url()} ${request.failure()?.errorText || "failed"}`));

  await page.goto(`${baseUrl}/information-layers.html`, { waitUntil: "load", timeout: 60000 });
  await page.waitForFunction(() => document.querySelectorAll("[data-source-card]").length === 9, null, { timeout: 30000 });
  if ((await page.title()) !== "附加信息源 - TerraSys") throw new Error("The information-source console title is missing.");
  if ((await page.locator("#runtimeMetric").innerText()) !== "9") throw new Error("The keyless runtime-source metric is incorrect.");
  if (await page.locator("[data-source-card]").count() !== 9) throw new Error("The runtime catalog does not render all nine no-key sources.");
  if (!(await page.locator(".activity-rail").isVisible())) throw new Error("The persistent runtime-status rail is missing.");
  if (!(await page.locator("#aisDetails").innerText()).includes("开放端点")) throw new Error("The AIS stream state is not exposed in the status rail.");
  await page.screenshot({ path: path.join(outputDir, "runtime-sources-desktop.png"), fullPage: true });

  await page.locator('[data-view="p1"]').click();
  if (await page.locator("[data-source-card]").count() !== 2) throw new Error("P1 filtering does not show exactly two sources.");
  await page.locator('[data-view="runtime"]').click();
  await page.locator("#sourceSearch").fill("ADS-B");
  if (await page.locator("[data-source-card]").count() !== 1) throw new Error("Source search did not isolate ADS-B.");

  let settingsRequest = null;
  await page.route("**/api/live/settings/aircraft", async (route) => {
    settingsRequest = JSON.parse(route.request().postData() || "{}");
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ status: "updated", layer: { id: "aircraft", enabled: false } }) });
  });
  await page.locator('[data-enabled="aircraft"]').uncheck({ force: true });
  await page.waitForFunction(() => document.querySelector('[data-source-card="aircraft"]')?.classList.contains("disabled"));
  if (settingsRequest?.enabled !== false) throw new Error("Disabling a source did not call the settings endpoint.");

  await page.route("**/api/live/aircraft?*", async (route) => {
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({
      type: "FeatureCollection",
      features: [{ type: "Feature", id: "fixture-aircraft", geometry: { type: "Point", coordinates: [139.7, 35.7] }, properties: {} }],
      properties: { status: "ok", source: "adsb.lol" }
    }) });
  });
  await page.locator('[data-action="test"][data-source-id="aircraft"]').click();
  await page.waitForFunction(() => document.querySelector('[data-test-meta="aircraft"]')?.textContent.includes("1 个对象"));
  await page.screenshot({ path: path.join(outputDir, "adsb-filter-and-test.png"), fullPage: true });

  await page.locator('[data-view="keyed"]').click();
  await page.locator("#sourceSearch").fill("");
  if (await page.locator("[data-candidate-card]").count() !== 5) throw new Error("The keyed-source comparison catalog does not render all five candidates.");
  const candidateText = await page.locator("#sourceList").innerText();
  for (const expected of ["NASA FIRMS", "OpenAQ v3", "AISStream.io", "Global Fishing Watch", "BarentsWatch AIS API"]) {
    if (!candidateText.includes(expected)) throw new Error(`The keyed-source catalog is missing ${expected}.`);
  }
  if (!candidateText.includes("调用") && !candidateText.includes("分钟")) throw new Error("The keyed-source catalog does not show call-limit information.");
  await page.screenshot({ path: path.join(outputDir, "keyed-candidates-desktop.png"), fullPage: true });

  if (errors.length) throw new Error(errors.join("\n"));
  console.log(JSON.stringify({ ok: true, runtimeSources: 9, keyedCandidates: 5, screenshots: outputDir }, null, 2));
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
