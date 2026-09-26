/* Only this bundled adapter can access the page. No eval, dynamic code, or HTTP server. */
"use strict";
const P = LimaBridgePolicy;
const HOST = "com.lima.browser_bridge";
let port = null, reconnectTimer = null, lastError = null;
const active = new Map();
const mutations = new Map();
function error(code) { throw new Error(code); }
function check(state) {
  if (state.cancelled || state.connection !== port) error("cancelled");
}
function response(connection, m, result, code) {
  if (connection !== port) return;
  const reply = {version: 1, id: m.id, kind: "response", command: m.command,
    arguments: {}, ...(code ? {error: code} : {result})};
  if (new TextEncoder().encode(JSON.stringify(reply)).length > 900000) {
    reply.result = null; reply.error = "response_too_large";
  }
  try { connection.postMessage(reply); } catch {}
}
async function granted(url) {
  const origin = P.site(url);
  return !!origin && await browser.permissions.contains({origins: [origin]});
}
async function allowedTab(id) {
  if (!P.tabID(id)) error("invalid_tab");
  const tab = await browser.tabs.get(id);
  if (tab.incognito || !await granted(tab.url)) error("site_not_granted");
  return tab;
}
function info(tab) {
  return {id: tab.id, title: (tab.title || "").slice(0, 256), url: tab.url,
    active: !!tab.active, windowID: tab.windowId};
}
async function execute(m, state) {
  const a = m.arguments;
  check(state);
  switch (m.command) {
    case "bridge.status":
      return {connected: true, origins: (await browser.permissions.getAll()).origins || []};
    case "browser.tabs": {
      const result = [];
      for (const tab of (await browser.tabs.query({})).slice(0, 500)) {
        if (!tab.incognito && await granted(tab.url)) result.push(info(tab));
        check(state);
      }
      return {tabs: result, restrictedToGrantedSites: true};
    }
    case "browser.current": {
      const [tab] = await browser.tabs.query({active: true, lastFocusedWindow: true});
      if (!tab) error("no_active_tab");
      return info(await allowedTab(tab.id));
    }
    case "browser.read": {
      const tab = await allowedTab(a.tabID);
      check(state);
      const [snapshot] = await browser.tabs.executeScript(tab.id,
        {file: "snapshot.js", allFrames: false, runAt: "document_idle"});
      const current = await allowedTab(tab.id);
      check(state);
      if (!snapshot || snapshot.url !== tab.url || current.url !== tab.url) error("page_changed");
      return snapshot;
    }
    default:
      // Approval is a real click in the companion popup, bound to this request.
      return await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { mutations.delete(m.id); badge(); reject(new Error("approval_expired")); }, 60000);
        mutations.set(m.id, {m, state, resolve, reject, timer});
        badge();
      });
  }
}
async function performMutation(m, state) {
  check(state);
  const a = m.arguments;
  if (m.command === "browser.open") {
    if (!await granted(a.url)) error("site_not_granted");
    check(state);
    return info(await browser.tabs.create({url: a.url, active: a.active}));
  }
  // Resolve destination grants first, then re-read the source immediately before
  // mutation. No asynchronous approval survives cancellation or grant removal.
  if (m.command === "browser.navigate" && !await granted(a.url)) error("site_not_granted");
  const tab = await allowedTab(a.tabID);
  if (tab.url !== a.expectedURL) error("page_changed");
  check(state);
  if (m.command === "browser.navigate") return info(await browser.tabs.update(tab.id, {url: a.url}));
  if (m.command === "browser.focus") {
    await browser.tabs.update(tab.id, {active: true});
    check(state);
    await browser.windows.update(tab.windowId, {focused: true});
    return {focused: true};
  }
  if (m.command === "browser.close") { await browser.tabs.remove(tab.id); return {closed: true}; }
  error("unsupported_command");
}
function badge() { browser.browserAction.setBadgeText({text: mutations.size ? "!" : ""}); }
function cancel(id) {
  const state = active.get(id);
  if (state) state.cancelled = true;
  const pending = mutations.get(id);
  if (pending) {
    clearTimeout(pending.timer); mutations.delete(id); pending.reject(new Error("cancelled")); badge();
  }
}
function disconnect(connection) {
  if (port !== connection) return;
  port = null;
  for (const id of active.keys()) cancel(id);
  active.clear();
  lastError = "Open Lima, enable Browser Bridge, and install its native helper in Settings.";
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connect, 5000);
}
function connect() {
  clearTimeout(reconnectTimer);
  if (port) return;
  try {
    const connection = browser.runtime.connectNative(HOST);
    port = connection;
    connection.onMessage.addListener(async m => {
      if (port !== connection) return;
      if (P.validCancel(m)) {
        if (active.get(m.id)?.command === m.command) cancel(m.id);
        return;
      }
      if (!P.validRequest(m)) return;
      if (active.has(m.id) || active.size >= 16) { response(connection, m, null, "busy"); return; }
      Object.freeze(m.arguments); Object.freeze(m);
      const state = {cancelled: false, connection, command: m.command}; active.set(m.id, state);
      try {
        const result = await execute(m, state);
        check(state);
        response(connection, m, result);
      } catch (e) {
        response(connection, m, null, /^[a-z_]{1,64}$/.test(e.message) ? e.message : "request_failed");
      } finally {
        if (active.get(m.id) === state) active.delete(m.id);
      }
    });
    connection.onDisconnect.addListener(() => disconnect(connection));
    connection.postMessage({version: 1, id: crypto.randomUUID(), kind: "hello", command: "connect",
      arguments: {extensionID: browser.runtime.id}});
    lastError = null;
  } catch {
    if (port) disconnect(port);
    else { lastError = "Native helper is unavailable."; reconnectTimer = setTimeout(connect, 5000); }
  }
}
// Even remove-and-regrant must invalidate pending reads and approvals.
browser.permissions.onRemoved.addListener(() => { for (const id of active.keys()) cancel(id); });
browser.runtime.onMessage.addListener(async (m, sender) => {
  // Exact popup identity: no content script, tab, or other extension can approve.
  if (!m || sender.id !== browser.runtime.id || sender.tab ||
      sender.url !== browser.runtime.getURL("popup.html")) return;
  if (m.action === "status") return {connected: !!port, error: lastError,
    pending: [...mutations.values()].map(({m}) => ({id: m.id, command: m.command, arguments: m.arguments}))};
  if (m.action === "connect") {
    if (port) { const old = port; disconnect(old); old.disconnect(); }
    connect(); return {};
  }
  if (m.action === "decision") {
    const pending = mutations.get(m.id);
    if (!pending) return {};
    mutations.delete(m.id); clearTimeout(pending.timer); badge();
    if (m.allow !== true) { pending.reject(new Error("denied")); return {}; }
    try { pending.resolve(await performMutation(pending.m, pending.state)); }
    catch (e) { pending.reject(e); }
    return {};
  }
});
connect();
