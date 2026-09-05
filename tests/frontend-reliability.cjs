const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

// Exercise the shipped functions with controlled requests, clocks and map/DOM adapters.
// No HTTP requests, installed map data, browser or maintenance worker are needed.
const appSource = fs.readFileSync(path.join(__dirname, "../web/src/app.js"), "utf8");
const liveSource = fs.readFileSync(path.join(__dirname, "../web/src/live-layers.js"), "utf8");
const informationSource = fs.readFileSync(path.join(__dirname, "../web/src/information-layers.js"), "utf8");
const noop = () => {};
const collection = (id) => ({ type: "FeatureCollection", features: [{ id }], properties: { status: "ok" } });
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const flush = async () => { for (let index = 0; index < 6; index += 1) await Promise.resolve(); };

function appFunction(name) {
  const start = appSource.search(new RegExp(`^(?:async )?function ${name}\\(`, "m"));
  assert.notEqual(start, -1, `Missing app function ${name}`);
  const remainder = appSource.slice(start);
  const next = remainder.slice(1).search(/\n(?:async )?function \w+\(/);
  return next < 0 ? remainder : remainder.slice(0, next + 1);
}

function loadFunctions(context, names) {
  vm.runInContext(names.map(appFunction).join("\n"), context);
}

async function liveFixture() {
  let now = 1_000_000;
  let bounds = [0, 0, 1, 1];
  let catalog = { layers: [] };
  let nextTimer = 0;
  const timers = new Map();
  const requests = [];
  const sources = new Map();
  const layers = new Map();
  const map = {
    on: noop,
    hasImage: () => true,
    isStyleLoaded: () => true,
    getBounds: () => ({ getWest: () => bounds[0], getSouth: () => bounds[1], getEast: () => bounds[2], getNorth: () => bounds[3] }),
    getSource: (id) => sources.get(id),
    addSource: (id, spec) => sources.set(id, { data: spec.data, writes: 0, setData(data) { this.data = data; this.writes += 1; } }),
    getLayer: (id) => layers.get(id),
    addLayer: (layer) => layers.set(layer.id, layer),
    setLayoutProperty: (id, key, value) => { layers.get(id).layout[key] = value; }
  };
  const context = vm.createContext({
    console: { warn: noop }, URLSearchParams, AbortController,
    Date: class extends Date { static now() { return now; } },
    window: {
      setInterval: (fn) => { timers.set(++nextTimer, fn); return nextTimer; },
      clearInterval: (id) => timers.delete(id),
      setTimeout: (fn) => { timers.set(++nextTimer, fn); return nextTimer; },
      clearTimeout: (id) => timers.delete(id)
    }
  });
  vm.runInContext(liveSource.replace(/^export /gm, ""), context);
  const LiveLayersModule = vm.runInContext("LiveLayersModule", context);
  const live = new LiveLayersModule(map, {
    escapeHtml: String,
    api: (url, options = {}) => {
      if (url === "/live/catalog") return Promise.resolve(catalog);
      const request = { url, ...options, ...deferred() };
      requests.push(request);
      // Intentionally ignore abort so response guards are tested independently of fetch.
      return request.promise;
    }
  });
  await flush();
  return {
    live, map, requests, sources, layers, timers,
    advance: (milliseconds) => { now += milliseconds; },
    viewport: (value) => { bounds = value; },
    configure: (value) => { catalog = value; },
    resetStyle: () => { sources.clear(); layers.clear(); }
  };
}

test("live polling accepts a slow successful response without overlapping requests", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("aircraft", true);
  fixture.advance(5000);
  await fixture.live.refresh("aircraft");
  assert.equal(fixture.requests.length, 1);
  assert.equal(fixture.requests[0].signal.aborted, false);
  fixture.advance(1000);
  fixture.requests[0].resolve(collection("accepted"));
  await flush();
  assert.equal(fixture.sources.get("live-aircraft-source").data.features[0].id, "accepted");
  assert.equal(fixture.live.statuses.get("aircraft"), "ok");
  assert.equal(fixture.live.requests.size, 0);
});

test("server-side disable hides a live layer and stops its polling", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("vessels", true);
  fixture.requests[0].resolve({ type: "FeatureCollection", features: [], properties: { status: "disabled" } });
  await flush();
  assert.equal(fixture.live.visible.has("vessels"), false);
  assert.equal(fixture.live.definitions.find((item) => item.id === "vessels").enabled, false);
  assert.equal(fixture.live.timer, null);
  fixture.advance(600_000);
  fixture.live.refreshVisible();
  assert.equal(fixture.requests.length, 1);
});

test("information-source tests preserve connecting and disabled states", async () => {
  const source = informationSource.slice(informationSource.indexOf("async function testSource("), informationSource.indexOf("async function testAll("));
  for (const status of ["disabled", "connecting", "unavailable", "ok"]) {
    const state = { catalog: { layers: [{ id: "vessels", label: "AIS" }] }, testing: new Set(), testResults: new Map(), testEvents: [] };
    const context = vm.createContext({
      state, TEST_QUERIES: { vessels: "bounds" }, performance: { now: () => 0 }, Date, encodeURIComponent,
      renderSources: noop, renderRail: noop, formatCount: String, refreshRuntime: async () => {},
      api: async () => ({ type: "FeatureCollection", features: [], properties: { status } })
    });
    vm.runInContext(source, context);
    await context.testSource("vessels");
    assert.equal(state.testResults.get("vessels").status, status === "ok" ? "ready" : status);
    assert.equal(state.testing.size, 0);
  }
});

test("a changed viewport cancels the old request and rejects its late response", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("aircraft", true);
  fixture.viewport([10, 10, 11, 11]);
  const latest = fixture.live.refresh("aircraft", true);
  assert.equal(fixture.requests.length, 2);
  assert.equal(fixture.requests[0].signal.aborted, true);
  fixture.requests[0].resolve(collection("old"));
  await flush();
  assert.equal(fixture.sources.get("live-aircraft-source").writes, 0);
  fixture.requests[1].resolve(collection("new"));
  await latest;
  assert.equal(fixture.sources.get("live-aircraft-source").data.features[0].id, "new");
});

test("style reload reuses in-flight work and restores cached layer data", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("aircraft", true);
  fixture.resetStyle();
  fixture.live.ensureLayers();
  fixture.live.refreshVisible(true);
  assert.equal(fixture.requests.length, 1);
  fixture.requests[0].resolve(collection("restored"));
  await flush();
  fixture.resetStyle();
  fixture.live.ensureLayers();
  assert.equal(fixture.sources.get("live-aircraft-source").data.features[0].id, "restored");
  assert.equal(fixture.layers.get("live-aircraft").layout.visibility, "visible");
});

test("closing a live layer cancels requests and viewport refresh, including late success", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("aircraft", true);
  fixture.live.scheduleViewportRefresh();
  fixture.live.setVisible("aircraft", false);
  assert.equal(fixture.requests[0].signal.aborted, true);
  assert.equal(fixture.timers.size, 0);
  fixture.live.scheduleViewportRefresh();
  assert.equal(fixture.timers.size, 0, "hidden layers must not schedule new viewport work");
  fixture.requests[0].resolve(collection("closed"));
  await flush();
  assert.equal(fixture.sources.get("live-aircraft-source").writes, 0);
  fixture.live.setVisible("aircraft", true);
  assert.equal(fixture.requests.length, 2);
});

test("catalog disable cancels a visible live layer and stops its polling", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("aircraft", true);
  fixture.configure({ layers: [{ id: "aircraft", enabled: false }] });
  await fixture.live.loadCatalog();
  assert.equal(fixture.requests[0].signal.aborted, true);
  assert.equal(fixture.live.visible.has("aircraft"), false);
  assert.equal(fixture.timers.size, 0);
  fixture.requests[0].resolve(collection("disabled"));
  await flush();
  assert.equal(fixture.sources.get("live-aircraft-source").writes, 0);
});

test("failed live requests respect the configured interval before retry", async () => {
  const fixture = await liveFixture();
  fixture.live.setVisible("aircraft", true);
  fixture.requests[0].reject(new Error("offline"));
  await flush();
  fixture.advance(5000);
  await fixture.live.refresh("aircraft");
  assert.equal(fixture.requests.length, 1);
  fixture.advance(5000);
  fixture.live.refresh("aircraft");
  assert.equal(fixture.requests.length, 2);
});

function routeFixture() {
  const requests = [];
  const state = {
    route: {
      locations: [{ longitude: 1, latitude: 1, name: "A" }, { longitude: 2, latitude: 2, name: "B" }],
      costing: "auto", result: null, resultInput: null, requestId: 0, controller: null, locationSearchIds: [0, 0], drafts: [null, null]
    },
    map: { fitBounds: noop, easeTo: noop, getZoom: () => 10, getCenter: () => ({ lng: 1, lat: 1 }) }
  };
  const elements = Object.fromEntries(["routeResult", "routeEmpty", "routeSaveButton", "routeSpeakButton", "routePanel", "routeButton", "routeStartLabel", "routeEndLabel"]
    .map((id) => [id, { classList: { remove: noop }, value: "" }]));
  const context = vm.createContext({
    console, state, elements, AbortController,
    icons: noop, updateRoutePanel: noop, updateRouteSource: noop, updateRouteCoverageStatus: noop,
    rememberRouteLocation: noop, setMode: noop, showToast: noop, refreshData: async () => {},
    renderRouteResult: () => { elements.routeSaveButton.disabled = false; },
    maplibregl: { LngLatBounds: class { extend() { return this; } } },
    document: { body: { classList: { contains: () => false, remove: noop } }, querySelectorAll: () => [] },
    api: (url, options = {}) => {
      const request = { url, ...options, ...deferred() };
      requests.push(request);
      return request.promise;
    }
  });
  loadFunctions(context, ["invalidateRoute", "clearRoute", "setRouteLocation", "runRoute", "saveRouteTrack", "routePointLabel", "setRouteCosting", "editRouteLocation", "closeRoutePanel", "searchRouteLocation"]);
  return { context, state, elements, requests, call: (name, ...args) => context[name](...args) };
}

const routeResult = (end) => ({ geometry: { type: "LineString", coordinates: [[1, 1], end] }, summary: {} });

test("endpoint changes invalidate the old route before reverse lookup and save one input snapshot", async () => {
  const fixture = routeFixture();
  const oldCalculation = fixture.call("runRoute");
  const selection = fixture.call("setRouteLocation", 1, [3, 3]);
  const routes = fixture.requests.filter((item) => item.url === "/route");
  const reverse = fixture.requests.find((item) => item.url.startsWith("/reverse"));
  assert.equal(routes.length, 2, "new geometry calculation must not await reverse lookup");
  assert.equal(routes[0].signal.aborted, true);
  routes[0].resolve(routeResult([2, 2]));
  await oldCalculation;
  assert.equal(fixture.state.route.result, null);
  assert.equal(fixture.elements.routeSaveButton.disabled, true);
  routes[1].resolve(routeResult([3, 3]));
  await flush();
  reverse.resolve({ name: "C" });
  await selection;
  assert.equal(fixture.state.route.locations[1].name, "C");
  assert.equal(fixture.state.route.resultInput.locations[1].longitude, 3);
  const saving = fixture.call("saveRouteTrack");
  const saved = fixture.requests.find((item) => item.url === "/tracks");
  const body = JSON.parse(saved.body);
  assert.equal(body.name, "A 至 3.00000, 3.00000");
  assert.deepEqual(body.geometry.coordinates.at(-1), [3, 3]);
  assert.equal(body.activity, "driving");
  saved.resolve({});
  await saving;
});

test("changing costing clears the old result while the replacement request fails", async () => {
  const fixture = routeFixture();
  const first = fixture.call("runRoute");
  fixture.requests[0].resolve(routeResult([2, 2]));
  await first;
  const replacement = fixture.call("setRouteCosting", "pedestrian");
  assert.equal(fixture.state.route.result, null);
  assert.equal(fixture.state.route.resultInput, null);
  assert.equal(fixture.elements.routeSaveButton.disabled, true);
  assert.equal(JSON.parse(fixture.requests[1].body).costing, "pedestrian");
  fixture.requests[1].reject(new Error("no route"));
  await replacement;
  await fixture.call("saveRouteTrack");
  assert.equal(fixture.requests.filter((item) => item.url === "/tracks").length, 0);
});

test("editing and closing route inputs discard in-flight route and location search results", async () => {
  const fixture = routeFixture();
  const calculation = fixture.call("runRoute");
  fixture.call("editRouteLocation", 1);
  assert.equal(fixture.requests[0].signal.aborted, true);
  fixture.requests[0].resolve(routeResult([2, 2]));
  await calculation;
  assert.equal(fixture.state.route.result, null);
  fixture.elements.routeEndLabel.value = "C";
  const search = fixture.call("searchRouteLocation", 1);
  fixture.call("closeRoutePanel");
  for (const request of fixture.requests.slice(1)) request.resolve({ results: [{ longitude: 3, latitude: 3, name: "C" }] });
  await search;
  assert.equal(fixture.state.route.locations[1], null);
  assert.equal(fixture.requests.filter((item) => item.url === "/route").length, 1);
});

test("unresolved route input survives costing changes and clears with the route", async () => {
  const fixture = routeFixture();
  loadFunctions(fixture.context, ["updateRoutePanel"]);
  fixture.elements.routeEndLabel.value = "上海";
  fixture.call("editRouteLocation", 1);
  await fixture.call("setRouteCosting", "pedestrian");
  assert.equal(fixture.elements.routeEndLabel.value, "上海");
  assert.equal(fixture.state.route.locations[1], null);
  assert.equal(fixture.requests.length, 0);
  fixture.call("clearRoute");
  assert.equal(fixture.elements.routeEndLabel.value, "");
});

test("removing the last installed pack clears the style catalog and its layers", () => {
  let appliedStyle;
  const state = {
    catalog: { datasets: [{ id: "only-pack", installed: true }] },
    mapPacks: [{ id: "only-pack", installed: false }], renderedPackIds: ["only-pack"],
    map: { isStyleLoaded: () => true, setStyle: (style) => { appliedStyle = style; } }
  };
  const context = vm.createContext({ state, indexRenderedPackLayers: noop, window: {
    TerraSysMapStyle: { create: (catalog) => ({ style: { layers: catalog.datasets.map((pack) => ({ id: pack.id })) }, groups: new Map() }) }
  } });
  loadFunctions(context, ["renderingMapCatalog", "mapStyleCatalog", "syncInstalledCatalogDatasets", "syncMapStyleForInstalledPacks"]);
  context.syncInstalledCatalogDatasets();
  assert.equal(context.syncMapStyleForInstalledPacks(), true);
  assert.equal(state.catalog.datasets.length, 0);
  assert.equal(appliedStyle.layers.length, 0);
  assert.equal(state.renderedPackIds.length, 0);
});

function searchFixture() {
  const requests = [];
  const timers = new Map();
  let nextTimer = 0;
  const state = { searchSuggestionTimer: null, searchSuggestionRequestId: 0, searchSuggestionController: null };
  const elements = { searchInput: { value: "", setAttribute: noop }, searchSuggestions: { hidden: true } };
  const context = vm.createContext({
    state, elements, AbortController,
    setTimeout: (callback) => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: (id) => timers.delete(id),
    unifiedSearch: (query, limit, options) => { const request = { query, ...options, ...deferred() }; requests.push(request); return request.promise; },
    localSearchExtras: (query) => [{ id: `fallback-${query}` }],
    renderSearchSuggestions: (results) => { elements.searchSuggestions.results = results; elements.searchSuggestions.hidden = !results.length; }
  });
  loadFunctions(context, ["closeSearchSuggestions", "scheduleSearchSuggestions"]);
  return {
    context, requests, elements,
    input: (value) => { elements.searchInput.value = value; context.scheduleSearchSuggestions(); },
    start: () => { const callback = timers.get(state.searchSuggestionTimer); timers.delete(state.searchSuggestionTimer); return callback(); }
  };
}

test("search suggestions ignore reversed responses for different queries", async () => {
  const fixture = searchFixture();
  fixture.input("南京");
  const old = fixture.start();
  fixture.input("上海");
  const latest = fixture.start();
  assert.equal(fixture.requests[0].signal.aborted, true);
  fixture.requests[1].resolve([{ id: "shanghai" }]);
  await latest;
  fixture.requests[0].resolve([{ id: "nanjing" }]);
  await old;
  assert.equal(fixture.elements.searchSuggestions.results[0].id, "shanghai");
});

test("clearing or dismissing suggestions prevents both late results and error fallbacks", async () => {
  const fixture = searchFixture();
  fixture.input("南京");
  const old = fixture.start();
  fixture.input("");
  fixture.requests[0].resolve([{ id: "nanjing" }]);
  await old;
  assert.equal(fixture.elements.searchSuggestions.hidden, true);
  fixture.input("上海");
  const dismissed = fixture.start();
  fixture.context.closeSearchSuggestions();
  fixture.requests[1].reject(new Error("late failure"));
  await dismissed;
  assert.equal(fixture.elements.searchSuggestions.hidden, true);
  assert.equal(fixture.requests[1].signal.aborted, true);
});
