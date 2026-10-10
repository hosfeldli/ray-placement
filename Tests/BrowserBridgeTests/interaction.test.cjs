const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../../BrowserBridge/interaction.js"), "utf8");
function element(tag, attributes = {}) {
  const events = [];
  const target = {
    tagName: tag.toUpperCase(), isConnected: true, disabled: false, parentElement: null,
    style: {display: "block", visibility: "visible", opacity: "1"},
    type: attributes.type || "", value: attributes.value || "",
    isContentEditable: attributes.contenteditable === "true",
    getClientRects: () => [{}], getAttribute: key => attributes[key] ?? (key === "aria-label" ? "Fixture" : null),
    hasAttribute: key => key in attributes,
    focus() {}, click() { target.clicked = true; },
    dispatchEvent(event) { events.push(event.type); },
    querySelectorAll() { return attributes.fields || []; },
    requestSubmit() { target.submitted = true; },
    events
  };
  return target;
}
function adapter(targets) {
  let handler;
  const browser = {runtime: {id: "lima-browser-bridge@liamhosfeld.com",
    onMessage: {addListener(callback) { handler = callback; }}}};
  const document = {};
  const refs = new Map(), liveTargets = new Map();
  for (const [name, elements] of Object.entries(targets)) {
    const ref = `c_${refs.size + 1}`;
    refs.set(name, ref); liveTargets.set(ref, elements[0]);
  }
  const session = {document, url: "https://example.com/case", documentID: "fixture-document",
    pageGeneration: 1, snapshotRevision: 1, mutationRevision: 0, targets: liveTargets};
  vm.runInNewContext(source, {browser, document, location: {href: "https://example.com/case"},
    __limaPageSessionV1: session,
    Event: class { constructor(type) { this.type = type; } }, getComputedStyle: node => node.style});
  const sender = {id: browser.runtime.id};
  const run = (command, name, text) => {
    const target = targets[name]?.[0];
    return handler({type: "lima-browser-interaction", command,
      internalRef: refs.get(name) || "c_999", text,
      expected: {action: command.slice(8), tag: target?.tagName.toLowerCase() || "button", label: "Fixture",
        documentID: "fixture-document", pageGeneration: 1, snapshotRevision: 1, mutationRevision: 0}}, sender);
  };
  run.session = session;
  return run;
}

test("discovered non-submit button and nonsensitive input actions execute", () => {
  const button = element("button", {type: "button"});
  const input = element("input", {type: "search"});
  const run = adapter({"button#inspect": [button], 'input[name="query"]': [input]});
  assert.equal(run("browser.click", "button#inspect").performed, "click");
  assert.equal(button.clicked, true);
  assert.equal(run("browser.type", 'input[name="query"]', "hello").performed, "type");
  assert.equal(input.value, "hello");
  assert.deepEqual(input.events, ["input", "change"]);
});

test("page actions reject links and credential fields while direct references disambiguate controls", () => {
  const link = element("a");
  const password = element("input", {type: "password"});
  const card = element("input", {type: "text", autocomplete: "cc-number"});
  const code = element("textarea", {autocomplete: "one-time-code"});
  const duplicate = [element("button", {type: "button"}), element("button", {type: "button"})];
  const run = adapter({"#link": [link], "#password": [password], "#card": [card], "#code": [code],
    "button#duplicate": duplicate});
  assert.equal(run("browser.click", "#link").error, "unsupported_target");
  assert.equal(run("browser.click", "button#duplicate").performed, "click");
  assert.equal(duplicate[0].clicked, true);
  assert.equal(duplicate[1].clicked, undefined);
  assert.equal(run("browser.type", "#password", "secret").error, "sensitive_or_unsupported_target");
  assert.equal(run("browser.type", "#card", "4111111111111111").error, "sensitive_or_unsupported_target");
  assert.equal(run("browser.type", "#code", "123456").error, "sensitive_or_unsupported_target");
  assert.equal(password.value, "");
  assert.equal(card.value, "");
});

test("page actions reject controls disabled or read-only after discovery", () => {
  const disabled = element("button", {type: "button", disabled: ""});
  const locked = element("input", {type: "text", readonly: ""});
  const ariaLocked = element("textarea", {"aria-readonly": "true"});
  const run = adapter({"button#disabled": [disabled], "input#locked": [locked], "textarea#aria-locked": [ariaLocked]});
  assert.equal(run("browser.click", "button#disabled").error, "target_not_interactable");
  assert.equal(run("browser.type", "input#locked", "changed").error, "target_not_interactable");
  assert.equal(run("browser.type", "textarea#aria-locked", "changed").error, "target_not_interactable");
  assert.equal(disabled.clicked, undefined);
  assert.equal(locked.value, "");
  assert.equal(ariaLocked.value, "");
});
test("page actions reject controls hidden or private after discovery", () => {
  const hidden = element("div", {"data-lima-private": ""});
  const button = element("button", {type: "button"});
  button.parentElement = hidden;
  const transparent = element("button", {type: "button"});
  transparent.style.opacity = "0";
  const run = adapter({"button#private": [button], "button#transparent": [transparent]});
  assert.equal(run("browser.click", "button#private").error, "target_not_visible");
  assert.equal(run("browser.click", "button#transparent").error, "target_not_visible");
  assert.equal(button.clicked, undefined);
  assert.equal(transparent.clicked, undefined);
});
test("form submission excludes credentials but accepts a nonsensitive form", () => {
  const safe = element("form", {fields: [element("input", {type: "hidden"}), element("input", {type: "search"})]});
  const login = element("form", {fields: [element("input", {type: "password"})]});
  const payment = element("form", {fields: [element("textarea", {autocomplete: "cc-number"})]});
  const run = adapter({"form#safe": [safe], "form#login": [login], "form#payment": [payment]});
  assert.equal(run("browser.submit", "form#login").error, "sensitive_or_unsupported_target");
  assert.equal(run("browser.submit", "form#payment").error, "sensitive_or_unsupported_target");
  assert.equal(login.submitted, undefined);
  assert.equal(payment.submitted, undefined);
  assert.equal(run("browser.submit", "form#safe").performed, "submit");
  assert.equal(safe.submitted, true);
});

test("a revised, mutated, or rerouted page rejects a captured target", () => {
  for (const change of [
    session => { session.snapshotRevision += 1; },
    session => { session.mutationRevision += 1; },
    session => { session.pageGeneration += 1; },
    session => { session.url = "https://example.com/other"; }
  ]) {
    const button = element("button", {type: "button"});
    const run = adapter({button: [button]});
    change(run.session);
    assert.equal(run("browser.click", "button").error, "target_stale");
    assert.equal(button.clicked, undefined);
  }
});

test("private open-shadow hosts block an otherwise valid direct target", () => {
  const host = element("x-private", {"data-lima-private": ""});
  const button = element("button", {type: "button"});
  button.getRootNode = () => ({host});
  const run = adapter({shadowButton: [button]});
  assert.equal(run("browser.click", "shadowButton").error, "target_not_visible");
  assert.equal(button.clicked, undefined);
});
