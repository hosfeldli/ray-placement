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
    getClientRects: () => [{}], getAttribute: key => attributes[key] ?? null,
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
  const document = {querySelectorAll: selector => targets[selector] || []};
  vm.runInNewContext(source, {browser, document, Event: class { constructor(type) { this.type = type; } },
    getComputedStyle: node => node.style});
  const sender = {id: browser.runtime.id};
  return (command, selector, text) => handler(
    {type: "lima-browser-interaction", command, selector, text}, sender);
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

test("page actions reject links, ambiguous controls, and credential fields", () => {
  const link = element("a");
  const password = element("input", {type: "password"});
  const card = element("input", {type: "text", autocomplete: "cc-number"});
  const code = element("textarea", {autocomplete: "one-time-code"});
  const duplicate = [element("button", {type: "button"}), element("button", {type: "button"})];
  const run = adapter({"#link": [link], "#password": [password], "#card": [card], "#code": [code],
    "button#duplicate": duplicate});
  assert.equal(run("browser.click", "#link").error, "unsupported_target");
  assert.equal(run("browser.click", "button#duplicate").error, "target_ambiguous");
  assert.equal(run("browser.type", "#password", "secret").error, "sensitive_or_unsupported_target");
  assert.equal(run("browser.type", "#card", "4111111111111111").error, "sensitive_or_unsupported_target");
  assert.equal(run("browser.type", "#code", "123456").error, "sensitive_or_unsupported_target");
  assert.equal(password.value, "");
  assert.equal(card.value, "");
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
  const run = adapter({"form#safe": [safe], "form#login": [login]});
  assert.equal(run("browser.submit", "form#login").error, "sensitive_or_unsupported_target");
  assert.equal(login.submitted, undefined);
  assert.equal(run("browser.submit", "form#safe").performed, "submit");
  assert.equal(safe.submitted, true);
});
