"use strict";

const connection = document.getElementById("connection");
const siteTitle = document.getElementById("siteTitle");
const siteURL = document.getElementById("siteURL");
const grant = document.getElementById("grant");
const permissionDetail = document.getElementById("permissionDetail");

let currentPattern = null;

function patternFor(rawURL) {
  const url = new URL(rawURL);
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  return `${url.protocol}//${url.host}/*`;
}

async function refresh() {
  try {
    const status = await browser.runtime.sendMessage({
      source: "lima-browser-popup",
      method: "status"
    });

    connection.textContent = status.nativeConnected ? "Connected to Lima" : "Waiting for Lima";
    connection.className = status.nativeConnected ? "ok" : "warn";

    if (!status.tab || !status.tab.url) {
      siteTitle.textContent = "No supported page";
      siteURL.textContent = "";
      grant.disabled = true;
      return;
    }

    siteTitle.textContent = status.tab.title || "Current page";
    siteURL.textContent = status.tab.url;
    currentPattern = patternFor(status.tab.url);

    if (!currentPattern) {
      grant.disabled = true;
      grant.textContent = "This page cannot be shared";
      permissionDetail.textContent = "Browser-internal pages are never available to Lima.";
      return;
    }

    grant.disabled = false;
    if (status.sitePermission) {
      grant.textContent = "Lima is allowed on this site";
      grant.disabled = true;
      permissionDetail.textContent = "You can revoke this permission from Zen's extension settings.";
    } else {
      grant.textContent = "Allow Lima on this site";
      permissionDetail.textContent = "Permission is limited to this website's origin.";
    }
  } catch (error) {
    connection.textContent = "Bridge unavailable";
    connection.className = "warn";
    permissionDetail.textContent = error.message || String(error);
  }
}

grant.addEventListener("click", async () => {
  if (!currentPattern) return;
  try {
    const granted = await browser.permissions.request({ origins: [currentPattern] });
    permissionDetail.textContent = granted ? "Site access granted." : "Site access was not granted.";
    await refresh();
  } catch (error) {
    permissionDetail.textContent = error.message || String(error);
  }
});

refresh();
