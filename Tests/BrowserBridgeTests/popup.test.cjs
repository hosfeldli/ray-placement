const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.join(__dirname, "../../BrowserBridge");
const P = require(path.join(root, "policy.js"));
const flush = () => new Promise(resolve => setImmediate(resolve));
const site = "https://example.com/*";

function popup() {
  const ids = new Map(), sent = [], requested = [], removed = [], interactions = new Set(), grants = new Set([site]);
  let focused, failure = false;
  const node = tag => ({tag, children: [], textContent: "", hidden: false, disabled: false,
    append(...children) { this.children.push(...children); },
    replaceChildren(...children) { this.children = children; },
    focus() { focused = this; }});
  for (const id of ["status", "connect", "site", "grant", "grants", "confirmation", "confirmation-detail",
    "cancel-always", "confirm-always", "pending"]) ids.set(id, node("div"));
  ids.get("confirmation").hidden = true;
  const document = {getElementById: id => ids.get(id), createElement: node};
  const tab = {url: "https://example.com/page", incognito: false};
  const browser = {
    runtime: {sendMessage: async m => {
      sent.push(m);
      if (m.action === "status") return {connected: true, pending: [], interactionOrigins: [...interactions], interactionPolicyAvailable: true};
      if (m.action === "set-interactions") {
        if (failure) return {error: "site_policy_update_failed"};
        if (m.allow) interactions.add(m.origin); else interactions.delete(m.origin);
      }
      return {};
    }},
    tabs: {query: async () => [tab]},
    permissions: {
      getAll: async () => ({origins: [...grants]}),
      request: async m => { requested.push(m); m.origins.forEach(s => grants.add(s)); return true; },
      remove: async m => { removed.push(m); m.origins.forEach(s => { grants.delete(s); interactions.delete(s); }); return true; }
    }
  };
  vm.runInNewContext(fs.readFileSync(path.join(root, "popup.js"), "utf8"), {document, browser, LimaBridgePolicy: P});
  const buttons = () => ids.get("grants").children.flatMap(li => li.children).filter(n => n.tag === "button");
  return {ids, sent, requested, removed, interactions, grants, tab, buttons,
    focused: () => focused, fail: () => { failure = true; }};
}
test("popup labels persistent reading separately and never enables interactions by opening", async () => {
  const h = popup(); await flush();
  assert.equal(h.ids.get("grant").textContent, "Reading: Always allowed");
  assert(h.ids.get("grant").disabled);
  assert(h.ids.get("grants").children[0].children[1].textContent.includes("Ask every time"));
  assert(!h.sent.some(m => m.action === "set-interactions"));
});
test("Always interactions requires a separate site-bound confirmation and Cancel changes nothing", async () => {
  const h = popup(); await flush();
  await h.buttons()[0].onclick();
  assert.equal(h.ids.get("confirmation").hidden, false);
  assert.equal(h.ids.get("confirmation-detail").textContent, site);
  assert.equal(h.focused(), h.ids.get("cancel-always"));
  assert(!h.sent.some(m => m.action === "set-interactions"));
  h.ids.get("cancel-always").onclick();
  await h.ids.get("confirm-always").onclick();
  assert.equal(h.interactions.size, 0);
});
test("confirmed interaction trust can be downgraded independently of reading", async () => {
  const h = popup(); await flush(); await h.buttons()[0].onclick();
  await h.ids.get("confirm-always").onclick();
  assert(h.interactions.has(site));
  assert.equal(h.buttons()[0].textContent, "Ask every time");
  await h.buttons()[0].onclick();
  assert.equal(h.interactions.size, 0); assert(h.grants.has(site));
});
test("revoking all access clears both modes and dismisses any open confirmation", async () => {
  const h = popup(); await flush(); await h.buttons()[0].onclick();
  await h.buttons()[1].onclick();
  await h.ids.get("confirm-always").onclick();
  assert.equal(h.grants.size, 0); assert.equal(h.interactions.size, 0);
  assert.equal(h.removed[0].origins[0], site);
  assert(h.ids.get("confirmation").hidden);
});
test("failed interaction save shows a generic error rather than claiming success", async () => {
  const h = popup(); await flush(); h.fail();
  await h.buttons()[0].onclick(); await h.ids.get("confirm-always").onclick();
  assert.equal(h.interactions.size, 0);
  assert(h.ids.get("status").textContent.includes("could not complete"));
});
test("reading grant requests only the exact selected origin and does not enable interactions", async () => {
  const h = popup(); await flush(); await h.buttons()[1].onclick();
  h.ids.get("grant").onclick(); await flush();
  assert.equal(h.requested[0].origins[0], site);
  assert.equal(h.interactions.size, 0);
});
