/* Shared, dependency-free validation; also exercised by node tests. */
(function (root) {
  "use strict";
  const commands = new Set(["bridge.status", "browser.tabs", "browser.current", "browser.read",
    "browser.open", "browser.focus", "browser.close", "browser.navigate"]);
  const uuid = value => typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
  function site(value) {
    if (typeof value !== "string" || !value.length || value.length > 4096 || /[\u0000-\u0020\u007f]/.test(value)) return null;
    try {
      const u = new URL(value);
      if (u.protocol !== "https:" || u.username || u.password || u.port ||
          !u.hostname || u.hostname.includes("*")) return null;
      return u.origin + "/*";
    } catch { return null; }
  }
  const tabID = value => Number.isSafeInteger(value) && value >= 0 && value <= 2147483647;
  function validRequest(m) {
    if (!m || m.version !== 1 || m.kind !== "request" || !uuid(m.id) || !commands.has(m.command) ||
        !m.arguments || typeof m.arguments !== "object" || Array.isArray(m.arguments)) return false;
    const a = m.arguments;
    let keys;
    switch (m.command) {
      case "bridge.status": case "browser.tabs": case "browser.current": keys = []; break;
      case "browser.read": keys = ["tabID"]; break;
      case "browser.open": keys = ["url", "active"]; break;
      case "browser.focus": case "browser.close": keys = ["tabID", "expectedURL"]; break;
      case "browser.navigate": keys = ["tabID", "expectedURL", "url"]; break;
    }
    return Object.keys(a).length === keys.length && keys.every(key => Object.hasOwn(a, key)) &&
      (!keys.includes("tabID") || tabID(a.tabID)) &&
      (!keys.includes("expectedURL") || !!site(a.expectedURL)) &&
      (!keys.includes("url") || !!site(a.url)) &&
      (!keys.includes("active") || typeof a.active === "boolean");
  }
  const validCancel = m => m && m.version === 1 && m.kind === "cancel" && uuid(m.id) && commands.has(m.command);
  const policy = { site, validRequest, validCancel, tabID, commands };
  root.LimaBridgePolicy = policy;
  if (typeof module !== "undefined") module.exports = policy;
})(globalThis);
