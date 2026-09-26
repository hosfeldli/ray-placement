"use strict";
const $ = id => document.getElementById(id);
let origin = null;
async function refresh() {
  const state = await browser.runtime.sendMessage({action: "status"});
  $("status").textContent = state.connected ? "Native connection open. Use Test Connection in Lima to verify." : state.error || "Disconnected";
  const [tab] = await browser.tabs.query({active: true, currentWindow: true});
  origin = tab && !tab.incognito ? LimaBridgePolicy.site(tab.url) : null;
  $("site").textContent = origin || "Select a normal HTTPS page to grant access.";
  $("grant").disabled = !origin;
  $("grants").replaceChildren();
  for (const site of (await browser.permissions.getAll()).origins || []) {
    const li = document.createElement("li");
    li.append(document.createTextNode(site));
    const button = document.createElement("button"); button.textContent = "Revoke";
    button.onclick = async () => { await browser.permissions.remove({origins: [site]}); await refresh(); };
    li.append(button); $("grants").append(li);
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
      button.onclick = async () => { await browser.runtime.sendMessage({action:"decision", id:request.id, allow}); await refresh(); };
      div.append(button);
    }
    $("pending").append(div);
  }
}
$("grant").onclick = () => {
  // Call directly in this user gesture, not after an asynchronous lookup.
  if (origin) browser.permissions.request({origins: [origin]}).then(refresh).catch(showError);
};
$("connect").onclick = () => browser.runtime.sendMessage({action:"connect"}).then(refresh).catch(showError);
function showError() { $("status").textContent = "The operation could not complete. Check browser permissions and try again."; }
refresh().catch(showError);
