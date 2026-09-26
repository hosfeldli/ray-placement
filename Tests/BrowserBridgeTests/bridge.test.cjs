const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {randomUUID} = require("node:crypto");
const root = path.join(__dirname, "../../BrowserBridge");
const P = require(path.join(root, "policy.js"));
const request = (command, args = {}, id = randomUUID()) => ({version: 1, kind: "request", id, command, arguments: args});
const flush = () => new Promise(resolve => setImmediate(resolve));
function event() {
  const handlers = [];
  return {addListener: handler => handlers.push(handler),
    emit: (...args) => Promise.all(handlers.map(handler => handler(...args)))};
}
function harness() {
  const ports = [], grants = new Set(["https://example.com/*"]), changes = [], timers = new Map();
  const tabs = new Map([[1, {id: 1, url: "https://example.com/case", title: "Case", windowId: 2, active: true}],
    [2, {id: 2, url: "https://private.example/no", title: "Secret", windowId: 2}],
    [3, {id: 3, url: "https://example.com/private", incognito: true, windowId: 3}]]);
  const browser = {
    runtime: {id: "lima-browser-bridge@liamhosfeld.com", onMessage: event(),
      getURL: name => "moz-extension://fixture/" + name,
      connectNative() {
        const p = {onMessage: event(), onDisconnect: event(), replies: [],
          postMessage(m) { this.replies.push(m); },
          disconnect() { return this.onDisconnect.emit(); }};
        ports.push(p); return p;
      }},
    permissions: {onRemoved: event(), contains: async ({origins}) => origins.every(o => grants.has(o)),
      getAll: async () => ({origins: [...grants]})},
    tabs: {
      get: async id => { if (!tabs.has(id)) throw Error("Unknown tab"); return {...tabs.get(id)}; },
      query: async q => [...tabs.values()].filter(t => !q.active || t.active).map(t => ({...t})),
      executeScript: async () => [{url: tabs.get(1).url, text: "Visible", links: [], untrustedPageContent: true}],
      create: async a => { changes.push(["create", a]); return {id: 9, windowId: 2, ...a}; },
      update: async (id, a) => { changes.push(["update", id, a]); return {...tabs.get(id), ...a}; },
      remove: async id => { changes.push(["remove", id]); }},
    windows: {update: async (...a) => { changes.push(["window", ...a]); }},
    browserAction: {setBadgeText() {}}
  };
  const context = {LimaBridgePolicy: P, browser, TextEncoder, crypto: {randomUUID}, console,
    setTimeout(fn, ms) { const id = randomUUID(); timers.set(id, {fn, ms}); return id; },
    clearTimeout(id) { timers.delete(id); }};
  vm.runInNewContext(fs.readFileSync(path.join(root, "background.js"), "utf8"), context);
  const sender = {id: browser.runtime.id, url: browser.runtime.getURL("popup.html")};
  return {browser, ports, grants, changes, timers, tabs, sender,
    popup: (m, from = sender) => browser.runtime.onMessage.emit(m, from),
    send: m => ports.at(-1).onMessage.emit(m)};
}
test("only exact HTTPS sites and typed command schemas are accepted", () => {
  assert.equal(P.site("https://example.com/a"), "https://example.com/*");
  for (const url of ["http://example.com", "https://u:p@example.com", "file:///tmp/x",
    "https://example.com:8443", "https://*.example.com", "https://example.com/\n", null, {}]) assert.equal(P.site(url), null);
  assert(P.validRequest(request("browser.open", {url: "https://example.com/a", active: false})));
  for (const m of [request("eval", {}), request("browser.tabs", {extra: true}),
    request("browser.read", {tabID: -1}), request("browser.read", {tabID: 1.1}),
    request("browser.open", {url: "https://example.com", active: "false"}),
    request("browser.close", {tabID: 1}), request("browser.tabs", {}, "a".repeat(36))]) assert(!P.validRequest(m));
});
test("tab listing and page reads are limited to explicitly granted non-private tabs", async () => {
  const h = harness();
  await h.send(request("browser.tabs"));
  assert.deepEqual(Array.from(h.ports[0].replies.at(-1).result.tabs, t => t.id), [1]);
  await h.send(request("browser.read", {tabID: 2}));
  assert.equal(h.ports[0].replies.at(-1).error, "site_not_granted");
  await h.send(request("browser.read", {tabID: 3}));
  assert.equal(h.ports[0].replies.at(-1).error, "site_not_granted");
  await h.send(request("browser.read", {tabID: 1}));
  assert.equal(h.ports[0].replies.at(-1).result.text, "Visible");
  assert.equal(h.changes.length, 0);
});
test("mutations require exact popup consent and do not focus background tabs", async () => {
  const h = harness(), m = request("browser.open", {url: "https://example.com/new", active: false});
  const pending = h.send(m);
  await flush(); assert.equal(h.changes.length, 0);
  await h.popup({action: "decision", id: m.id, allow: true}, {...h.sender, url: h.sender.url + ".spoof"});
  await h.popup({action: "decision", id: m.id, allow: true}, {...h.sender, tab: {id: 1}});
  assert.equal(h.changes.length, 0);
  await h.popup({action: "decision", id: m.id, allow: true});
  await pending;
  assert.equal(h.changes.length, 1);
  assert.equal(h.changes[0][1].active, false);
});
test("denial, expiry, and explicit cancellation never mutate tabs", async () => {
  for (const outcome of ["deny", "expire", "cancel"]) {
    const h = harness(), m = request("browser.close", {tabID: 1, expectedURL: h.tabs.get(1).url});
    const pending = h.send(m); await flush();
    if (outcome === "deny") await h.popup({action: "decision", id: m.id, allow: false});
    if (outcome === "expire") [...h.timers.values()].find(t => t.ms === 60000).fn();
    if (outcome === "cancel") await h.send({...m, kind: "cancel"});
    await pending;
    assert.equal(h.changes.length, 0);
    assert(h.ports[0].replies.at(-1).error);
  }
});
test("navigation since approval was requested invalidates the action", async () => {
  const h = harness(), m = request("browser.close", {tabID: 1, expectedURL: h.tabs.get(1).url});
  const pending = h.send(m); await flush();
  h.tabs.get(1).url = "https://example.com/different";
  await h.popup({action: "decision", id: m.id, allow: true}); await pending;
  assert.equal(h.changes.length, 0); assert.equal(h.ports[0].replies.at(-1).error, "page_changed");
});
test("cancellation during asynchronous grant lookup prevents an approved open", async () => {
  const h = harness(), m = request("browser.open", {url: "https://example.com/new", active: false});
  const pending = h.send(m); await flush();
  let finish; h.browser.permissions.contains = () => new Promise(r => { finish = r; });
  const decision = h.popup({action: "decision", id: m.id, allow: true}); await flush();
  await h.send({...m, kind: "cancel"}); finish(true); await decision; await pending;
  assert.equal(h.changes.length, 0); assert.equal(h.ports[0].replies.at(-1).error, "cancelled");
});
test("revocation invalidates in-flight reads even if the grant is restored", async () => {
  const h = harness(); let finish;
  h.browser.tabs.executeScript = () => new Promise(r => { finish = r; });
  const pending = h.send(request("browser.read", {tabID: 1})); await flush();
  await h.browser.permissions.onRemoved.emit({origins: ["https://example.com/*"]});
  finish([{url: h.tabs.get(1).url, text: "must not leak"}]); await pending;
  assert.equal(h.ports[0].replies.at(-1).error, "cancelled");
  assert.equal(h.ports[0].replies.at(-1).result, undefined);
});
test("page navigation during a read discards its snapshot", async () => {
  const h = harness(), original = h.tabs.get(1).url;
  h.browser.tabs.executeScript = async () => {
    h.tabs.get(1).url = "https://example.com/other"; return [{url: original, text: "stale"}];
  };
  await h.send(request("browser.read", {tabID: 1}));
  assert.equal(h.ports[0].replies.at(-1).error, "page_changed");
});
test("late responses and disconnect callbacks cannot cross connection generations", async () => {
  const h = harness(); let finish;
  h.browser.tabs.executeScript = () => new Promise(r => { finish = r; });
  const pending = h.send(request("browser.read", {tabID: 1})); await flush();
  const old = h.ports[0];
  await h.popup({action: "connect"}); assert.equal(h.ports.length, 2);
  await old.onDisconnect.emit();
  finish([{url: h.tabs.get(1).url, text: "old"}]); await pending;
  assert.equal(h.ports[1].replies.length, 1); // Only its hello.
  await h.send(request("bridge.status"));
  assert.equal(h.ports[1].replies.at(-1).result.connected, true);
});
test("pending requests are bounded and grant removal cancels approvals", async () => {
  const h = harness(), waits = [];
  for (let i = 0; i < 16; i++) waits.push(h.send(request("browser.open", {url: "https://example.com", active: false})));
  await flush();
  await h.send(request("browser.tabs"));
  assert.equal(h.ports[0].replies.at(-1).error, "busy");
  await h.browser.permissions.onRemoved.emit({});
  await Promise.all(waits); assert.equal(h.changes.length, 0);
});
test("oversized snapshots and raw browser exceptions are not forwarded", async () => {
  const h = harness();
  h.browser.tabs.executeScript = async () => [{url: h.tabs.get(1).url, text: "x".repeat(910000)}];
  await h.send(request("browser.read", {tabID: 1}));
  assert.equal(h.ports[0].replies.at(-1).error, "response_too_large");
  h.browser.tabs.get = async () => { throw Error("Private title and URL"); };
  await h.send(request("browser.read", {tabID: 1}));
  assert.equal(h.ports[0].replies.at(-1).error, "request_failed");
});
test("manifest has no automatic host grants or externally callable scripts", () => {
  const m = JSON.parse(fs.readFileSync(path.join(root, "manifest.json")));
  assert.deepEqual(m.optional_permissions, ["https://*/*"]);
  assert(!m.permissions.some(p => p.includes("://") || p === "<all_urls>"));
  assert.equal(m.incognito, "not_allowed"); assert(!m.content_scripts);
  assert(!m.externally_connectable); assert(!m.web_accessible_resources);
  assert.equal(m.browser_specific_settings.gecko.id, "lima-browser-bridge@liamhosfeld.com");
});
