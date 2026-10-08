/* Shared, dependency-free validation; also exercised by node tests. */
(function (root) {
  "use strict";
  const commands = new Set(["bridge.status", "browser.tabs", "browser.current", "browser.read",
    "browser.open", "browser.open_tabs", "browser.focus", "browser.close", "browser.navigate",
    "browser.click", "browser.type", "browser.submit"]);
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
  function selector(value) {
    if (typeof value !== "string" || !value.length || value.length > 256 ||
        /[\u0000-\u0020\u007f]/.test(value) || !/^[A-Za-z0-9_.#\[\]="'-]+$/.test(value)) return false;
    if (value.startsWith("#") || value.startsWith(".")) return value.length > 1;
    if (!["button", "input", "textarea", "form", "select"].some(prefix => value === prefix ||
        (value.startsWith(prefix) && ["#", ".", "["].includes(value.charAt(prefix.length))))) return false;
    return true;
  }
  const interactionText = value => typeof value === "string" && value.length <= 4000 &&
    !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);
  function validRequest(m) {
    if (!m || m.version !== 1 || m.kind !== "request" || !uuid(m.id) || !commands.has(m.command) ||
        !m.arguments || typeof m.arguments !== "object" || Array.isArray(m.arguments)) return false;
    const a = m.arguments;
    let keys;
    switch (m.command) {
      case "bridge.status": case "browser.tabs": case "browser.current": keys = []; break;
      case "browser.read": keys = ["tabID"]; break;
      case "browser.open": keys = ["url", "active"]; break;
      case "browser.open_tabs": keys = ["urls", "background", "reuseExisting"]; break;
      case "browser.focus": case "browser.close": keys = ["tabID", "expectedURL"]; break;
      case "browser.navigate": keys = ["tabID", "expectedURL", "url"]; break;
      case "browser.click": case "browser.submit": keys = ["tabID", "expectedURL", "selector"]; break;
      case "browser.type": keys = ["tabID", "expectedURL", "selector", "text"]; break;
    }
    return Object.keys(a).length === keys.length && keys.every(key => Object.hasOwn(a, key)) &&
      (!keys.includes("tabID") || tabID(a.tabID)) &&
      (!keys.includes("expectedURL") || !!site(a.expectedURL)) &&
      (!keys.includes("url") || !!site(a.url)) &&
      (!keys.includes("urls") || Array.isArray(a.urls) && a.urls.length >= 1 && a.urls.length <= 50 && a.urls.every(url => !!site(url))) &&
      (!keys.includes("selector") || selector(a.selector)) &&
      (!keys.includes("text") || interactionText(a.text)) &&
      (!keys.includes("active") || typeof a.active === "boolean") &&
      (!keys.includes("background") || typeof a.background === "boolean") &&
      (!keys.includes("reuseExisting") || typeof a.reuseExisting === "boolean");
  }
  const validCancel = m => m && m.version === 1 && m.kind === "cancel" && uuid(m.id) && commands.has(m.command);
  function mutationSites(m) {
    const a = m.arguments;
    let urls;
    switch (m.command) {
      case "browser.open": urls = [a.url]; break;
      case "browser.open_tabs": urls = a.urls; break;
      case "browser.navigate": urls = [a.expectedURL, a.url]; break;
      case "browser.focus": case "browser.close":
      case "browser.click": case "browser.type": case "browser.submit": urls = [a.expectedURL]; break;
      default: return [];
    }
    const sites = urls.map(site);
    return sites.every(Boolean) ? [...new Set(sites)] : [];
  }
  const policy = { site, selector, interactionText, validRequest, validCancel, tabID, commands, mutationSites };
  root.LimaBridgePolicy = policy;
  if (typeof module !== "undefined") module.exports = policy;
})(globalThis);
