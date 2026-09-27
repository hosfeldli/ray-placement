/* Only this bundled adapter can access the page. No eval, dynamic code, or HTTP server. */
"use strict";
const P = LimaBridgePolicy;
const HOST = "com.lima.browser_bridge";
let port = null, reconnectTimer = null, lastError = null;
const active = new Map();
const mutations = new Map();
// Reading uses Firefox's persistent exact-site grants. Tab interactions are a
// separate, local-only opt-in; never infer them from a read grant or page text.
const INTERACTION_KEY = "interactionOriginsV1", MAX_INTERACTION_SITES = 256;
let interactionOrigins = new Set(), policyEpoch = 0, storageAvailable = true;
let policyQueue = loadInteractionPolicy();
async function loadInteractionPolicy() {
  try {
    const stored = (await browser.storage.local.get(INTERACTION_KEY))[INTERACTION_KEY];
    const grantedOrigins = new Set((await browser.permissions.getAll()).origins || []);
    if (stored !== undefined && (!Array.isArray(stored) || stored.length > MAX_INTERACTION_SITES)) {
      error("invalid_site_policy");
    }
    interactionOrigins = new Set((stored || []).filter(site => P.site(site) === site && grantedOrigins.has(site)));
    await browser.storage.local.set({[INTERACTION_KEY]: [...interactionOrigins]});
  } catch { failInteractionStorage(); }
}
function cancelMutations() {
  for (const [id, state] of active) {
    if (["browser.open", "browser.navigate", "browser.focus", "browser.close"].includes(state.command)) cancel(id);
  }
}
function failInteractionStorage() {
  storageAvailable = false; interactionOrigins.clear(); cancelMutations();
}
function enqueuePolicy(change) {
  const result = policyQueue.then(change);
  policyQueue = result.catch(() => {});
  return result;
}
async function persistInteractionPolicy(sites) {
  try { await browser.storage.local.set({[INTERACTION_KEY]: [...sites]}); }
  catch { failInteractionStorage(); error("site_policy_unavailable"); }
}
async function setInteractionPolicy(site, allow) {
  if (P.site(site) !== site || typeof allow !== "boolean") error("invalid_site_policy");
  const epoch = ++policyEpoch;
  cancelMutations();
  // Revocation takes effect before any storage or browser lookup can yield.
  if (!allow) interactionOrigins.delete(site);
  return enqueuePolicy(async () => {
    if (!storageAvailable) error("site_policy_unavailable");
    if (epoch !== policyEpoch) error("cancelled");
    if (allow) {
      const origins = (await browser.permissions.getAll()).origins || [];
      if (!origins.includes(site)) error("site_not_granted");
      if (epoch !== policyEpoch) error("cancelled");
      if (interactionOrigins.size >= MAX_INTERACTION_SITES && !interactionOrigins.has(site)) error("too_many_sites");
    }
    const next = new Set(interactionOrigins);
    if (allow) next.add(site); else next.delete(site);
    await persistInteractionPolicy(next);
    if (epoch !== policyEpoch) error("cancelled");
    interactionOrigins = next;
    return {};
  });
}
function removedSiteAccess(removed) {
  ++policyEpoch;
  for (const id of active.keys()) cancel(id);
  const origins = removed.origins || [];
  const clear = !origins.length || origins.some(site => P.site(site) !== site);
  if (clear) interactionOrigins.clear();
  else for (const site of origins) interactionOrigins.delete(site);
  return enqueuePolicy(async () => {
    // Repeat after loading/older writes so remove-and-regrant never restores trust.
    if (clear) interactionOrigins.clear();
    else for (const site of origins) interactionOrigins.delete(site);
    await persistInteractionPolicy(interactionOrigins);
  }).catch(() => {});
}
async function alwaysAllowsMutation(m, state) {
  await policyQueue;
  check(state);
  const sites = P.mutationSites(m);
  if (!storageAvailable || !sites.length || !sites.every(site => interactionOrigins.has(site))) return false;
  state.interactionSites = sites;
  return true;
}
function error(code) { throw new Error(code); }
function check(state) {
  if (state.cancelled || state.connection !== port) error("cancelled");
  if (state.interactionSites && (!storageAvailable ||
      !state.interactionSites.every(site => interactionOrigins.has(site)))) error("cancelled");
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
      await policyQueue;
      return {connected: true, origins: (await browser.permissions.getAll()).origins || [],
        interactionOrigins: [...interactionOrigins], interactionPolicyAvailable: storageAvailable};
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
      if (await alwaysAllowsMutation(m, state)) return performMutation(m, state);
      check(state);
      // Otherwise require a real popup click bound to this request. Changing a
      // site's mode never retroactively approves a queued action.
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
browser.permissions.onRemoved.addListener(removedSiteAccess);
browser.runtime.onMessage.addListener(async (m, sender) => {
  // Exact popup identity: no content script, tab, or other extension can approve.
  if (!m || sender.id !== browser.runtime.id || sender.tab ||
      sender.url !== browser.runtime.getURL("popup.html")) return;
  if (m.action === "status") {
    await policyQueue;
    return {connected: !!port, error: lastError, interactionOrigins: [...interactionOrigins],
      interactionPolicyAvailable: storageAvailable,
      pending: [...mutations.values()].map(({m}) => ({id: m.id, command: m.command, arguments: m.arguments}))};
  }
  if (m.action === "set-interactions") {
    try { return await setInteractionPolicy(m.origin, m.allow); }
    catch { return {error: "site_policy_update_failed"}; }
  }
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
