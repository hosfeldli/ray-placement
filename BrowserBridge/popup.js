"use strict";
const $ = id => document.getElementById(id);
let origin = null, confirmingSite = null, revision = 0;
function dismissConfirmation() {
  confirmingSite = null; $("confirmation").hidden = true;
}
async function setInteractions(site, allow) {
  const result = await browser.runtime.sendMessage({action: "set-interactions", origin: site, allow});
  if (!result || result.error) throw new Error("site_policy_update_failed");
}
async function refresh() {
  const current = ++revision;
  const state = await browser.runtime.sendMessage({action: "status"});
  const [tab] = await browser.tabs.query({active: true, currentWindow: true});
  const sites = (await browser.permissions.getAll()).origins || [];
  if (current !== revision) return;
  const interactions = new Set(state.interactionOrigins || []);
  $("status").textContent = state.interactionPolicyAvailable === false
    ? "Interaction settings unavailable. Automatic interactions are disabled; try restarting the extension."
    : state.connected ? "Native connection open. Use Test Connection in Lima to verify." : state.error || "Disconnected";
  origin = tab && !tab.incognito ? LimaBridgePolicy.site(tab.url) : null;
  $("site").textContent = origin || "Select a normal HTTPS page to grant access.";
  $("grant").disabled = !origin || sites.includes(origin);
  $("grant").textContent = sites.includes(origin) ? "Reading: Always allowed" : "Always allow reading on this site";
  if (confirmingSite && !sites.includes(confirmingSite)) dismissConfirmation();
  $("grants").replaceChildren();
  for (const site of sites) {
    const li = document.createElement("li");
    const title = document.createElement("strong"); title.textContent = site;
    const detail = document.createElement("p"); detail.className = "detail";
    detail.textContent = "Reading: Always allowed · Interactions: " + (interactions.has(site) ? "Always allowed" : "Ask every time");
    const change = document.createElement("button");
    change.textContent = interactions.has(site) ? "Ask every time" : "Always allow interactions…";
    change.disabled = state.interactionPolicyAvailable === false || LimaBridgePolicy.site(site) !== site;
    change.onclick = async () => {
      try {
        if (interactions.has(site)) {
          dismissConfirmation(); await setInteractions(site, false); await refresh();
        } else {
          confirmingSite = site;
          $("confirmation-detail").textContent = site;
          $("confirmation").hidden = false;
          $("cancel-always").focus();
        }
      } catch { showError(); }
    };
    const revoke = document.createElement("button"); revoke.textContent = "Revoke all access";
    revoke.onclick = async () => {
      dismissConfirmation();
      try {
        // Firefox's removal event also erases interaction trust, including when
        // access is removed outside this popup. Never replace removal with a grant.
        await browser.permissions.remove({origins: [site]}); await refresh();
      } catch { showError(); }
    };
    li.append(title, detail, change, revoke); $("grants").append(li);
  }
  $("pending").replaceChildren();
  if (!state.pending.length) $("pending").textContent = "No actions awaiting review.";
  for (const request of state.pending) {
    const div = document.createElement("div"); div.className = "action";
    const title = document.createElement("strong"); title.textContent = request.command;
    const detail = document.createElement("p"); detail.className = "detail";
    detail.textContent = request.arguments.url || request.arguments.expectedURL || "Selected tab";
    div.append(title, detail);
    for (const allow of [false, true]) {
      const button = document.createElement("button"); button.textContent = allow ? "Allow once" : "Deny";
      button.onclick = async () => {
        try { await browser.runtime.sendMessage({action: "decision", id: request.id, allow}); await refresh(); }
        catch { showError(); }
      };
      div.append(button);
    }
    $("pending").append(div);
  }
}
$("grant").onclick = () => {
  // Request the exact origin directly within this click, before yielding.
  if (origin) browser.permissions.request({origins: [origin]}).then(refresh).catch(showError);
};
$("cancel-always").onclick = dismissConfirmation;
$("confirm-always").onclick = async () => {
  const site = confirmingSite;
  if (!site) return;
  dismissConfirmation();
  try { await setInteractions(site, true); await refresh(); }
  catch { showError(); }
};
$("connect").onclick = () => browser.runtime.sendMessage({action: "connect"}).then(refresh).catch(showError);
function showError() {
  $("status").textContent = "The setting or operation could not complete. Refresh to check the saved state before trying again.";
}
refresh().catch(showError);
