"use strict";

const NATIVE_HOST = "dev.liam.lima.browserbridge";
let nativePort = null;
let nativeConnected = false;
let reconnectTimer = null;

function sendEvent(event, payload = {}) {
  if (!nativePort) return;
  try {
    nativePort.postMessage({ type: "event", event, payload });
  } catch (_) {}
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNative();
  }, 2000);
}

function connectNative() {
  try {
    nativePort = browser.runtime.connectNative(NATIVE_HOST);
    nativeConnected = true;
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      nativeConnected = false;
      nativePort = null;
      scheduleReconnect();
    });
    sendEvent("extensionReady", { version: browser.runtime.getManifest().version });
    reportActivePage();
  } catch (_) {
    nativeConnected = false;
    nativePort = null;
    scheduleReconnect();
  }
}

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length) throw new Error("No active browser tab.");
  return tabs[0];
}

function originPattern(rawURL) {
  const url = new URL(rawURL);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Lima only interacts with normal HTTP and HTTPS pages.");
  }
  return `${url.protocol}//${url.host}/*`;
}

async function hasSitePermission(rawURL) {
  return browser.permissions.contains({ origins: [originPattern(rawURL)] });
}

async function ensureContentBridge(tab) {
  if (!tab.url || !(await hasSitePermission(tab.url))) {
    throw new Error("Site access is not approved. Click the Lima extension in Zen and allow this site first.");
  }
  await browser.tabs.executeScript(tab.id, { file: "content.js", runAt: "document_idle" });
}

async function contentRequest(tab, method, params = {}) {
  await ensureContentBridge(tab);
  return browser.tabs.sendMessage(tab.id, { source: "lima-browser-bridge", method, params });
}

function safeWebURL(rawURL) {
  const url = new URL(rawURL);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Only HTTP and HTTPS URLs can be opened.");
  }
  return url.href;
}

async function handleRequest(message) {
  const method = message.method;
  const params = message.params || {};

  if (method === "browser.activePage") {
    const tab = await activeTab();
    return { id: tab.id, title: tab.title || "", url: tab.url || "" };
  }

  if (method === "browser.snapshot") {
    const tab = await activeTab();
    return contentRequest(tab, "snapshot", {
      maxTextCharacters: Math.min(Math.max(Number(params.maxTextCharacters || 60000), 1000), 120000),
      maxElements: Math.min(Math.max(Number(params.maxElements || 250), 20), 500)
    });
  }

  if (method === "browser.click") {
    const tab = await activeTab();
    return contentRequest(tab, "click", { elementID: String(params.elementID || "") });
  }

  if (method === "browser.type") {
    const tab = await activeTab();
    return contentRequest(tab, "type", {
      elementID: String(params.elementID || ""),
      text: String(params.text || "")
    });
  }

  if (method === "browser.scroll") {
    const tab = await activeTab();
    return contentRequest(tab, "scroll", {
      direction: params.direction === "up" ? "up" : "down",
      amount: Number(params.amount || 0)
    });
  }

  if (method === "browser.openTabs") {
    const rawURLs = Array.isArray(params.urls) ? params.urls.slice(0, 50) : [];
    const urls = rawURLs.map(value => safeWebURL(String(value)));
    for (const url of urls) {
      await browser.tabs.create({ url, active: false });
    }
    return { opened: urls.length };
  }

  if (method === "salesforce.openCases") {
    const tab = await activeTab();
    if (!tab.url || !/\.salesforce\.com|\.force\.com|\.salesforce-sites\.com/i.test(new URL(tab.url).hostname)) {
      throw new Error("The active tab does not appear to be a Salesforce page.");
    }
    const caseNumbers = (Array.isArray(params.caseNumbers) ? params.caseNumbers : [])
      .map(value => String(value).trim())
      .filter(value => value.length > 0 && value.length <= 32)
      .slice(0, 50);
    if (!caseNumbers.length) throw new Error("No case numbers were provided.");

    const resolved = await contentRequest(tab, "resolveSalesforceCases", { caseNumbers });
    const opened = [];
    for (const item of resolved.matches || []) {
      const url = safeWebURL(item.url);
      await browser.tabs.create({ url, active: false });
      opened.push(item.caseNumber);
    }
    return {
      opened,
      unresolved: resolved.unresolved || [],
      sourceURL: tab.url
    };
  }

  throw new Error(`Unsupported Lima browser command: ${method}`);
}

async function handleNativeMessage(message) {
  if (!message || message.type !== "request" || !message.id) return;
  try {
    const result = await handleRequest(message);
    nativePort?.postMessage({
      type: "response",
      id: message.id,
      ok: true,
      result: result || {}
    });
  } catch (error) {
    nativePort?.postMessage({
      type: "response",
      id: message.id,
      ok: false,
      error: error && error.message ? error.message : String(error)
    });
  }
}

async function reportActivePage() {
  if (!nativeConnected) return;
  try {
    const tab = await activeTab();
    sendEvent("activePageChanged", {
      id: tab.id,
      title: tab.title || "",
      url: tab.url || ""
    });
  } catch (_) {}
}

browser.tabs.onActivated.addListener(reportActivePage);
browser.tabs.onUpdated.addListener((_, changeInfo) => {
  if (changeInfo.url || changeInfo.title || changeInfo.status === "complete") reportActivePage();
});

browser.runtime.onMessage.addListener(async message => {
  if (!message || message.source !== "lima-browser-popup") return undefined;
  if (message.method === "status") {
    let tab = null;
    try { tab = await activeTab(); } catch (_) {}
    let sitePermission = false;
    if (tab?.url) {
      try { sitePermission = await hasSitePermission(tab.url); } catch (_) {}
    }
    return {
      nativeConnected,
      tab: tab ? { title: tab.title || "", url: tab.url || "" } : null,
      sitePermission
    };
  }
  return undefined;
});

connectNative();
