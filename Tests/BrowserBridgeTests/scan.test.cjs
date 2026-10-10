const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const bridge = path.join(__dirname, "../../BrowserBridge");
const stepSource = fs.readFileSync(path.join(bridge, "scan_step.js"), "utf8");
const restoreSource = fs.readFileSync(path.join(bridge, "scan_restore.js"), "utf8");

function element({role = "", rect = {width: 1000, height: 800}, scrollHeight = 800,
  clientHeight = 800, scrollTop = 0, privateElement = false, children = []} = {}) {
  const node = {
    role, rect, scrollHeight, clientHeight, scrollTop, privateElement, children,
    parentElement: null, isConnected: true, shadowRoot: null,
    style: {display: "block", visibility: "visible", opacity: "1", overflowY: "auto"},
    getClientRects() { return [this.rect]; },
    getBoundingClientRect() { return this.rect; },
    getRootNode() { return this.rootNode; },
    matches(selector) { return selector.includes("[role='grid']") && this.role === "grid"; },
    closest(selector) {
      for (let current = this; current; current = current.parentElement) {
        if (selector.includes("[data-lima-private]") && current.privateElement) return current;
        if (selector.includes("[role='grid']") && current.role === "grid") return current;
      }
      return null;
    }
  };
  for (const child of children) child.parentElement = node;
  return node;
}
function descendants(root) {
  return (root.children || []).flatMap(child => [child, ...descendants(child)]);
}
function fixture({privateHost = false} = {}) {
  const grid = element({role: "grid", rect: {width: 800, height: 600},
    scrollHeight: 5000, clientHeight: 600, scrollTop: 100});
  const host = element({privateElement: privateHost, rect: {width: 800, height: 600}});
  const shadow = {host, children: [grid]};
  host.shadowRoot = shadow;
  grid.rootNode = shadow;
  const root = element({scrollHeight: 1600, clientHeight: 800, scrollTop: 10,
    children: [host]});
  const document = {
    documentElement: root, scrollingElement: root,
    createTreeWalker(treeRoot) {
      const nodes = descendants(treeRoot);
      let index = 0;
      return {nextNode: () => nodes[index++] || null};
    }
  };
  root.rootNode = document;
  host.rootNode = document;
  const location = {href: "https://example.com/report"};
  const context = vm.createContext({
    document, location, innerWidth: 1000, innerHeight: 800,
    NodeFilter: {SHOW_ELEMENT: 1}, getComputedStyle: node => node.style,
    __limaPageSessionV1: {document, documentID: "fixture-document", pageGeneration: 1}
  });
  return {
    root, grid, host, location, context,
    step: () => vm.runInContext(stepSource, context),
    restore: () => vm.runInContext(restoreSource, context)
  };
}
test("generic scan selects and restores a virtualized grid inside an open shadow root", () => {
  const f = fixture();
  const start = f.step();
  assert.equal(start.initialized, true);
  assert.equal(start.position, 100);
  const moved = f.step();
  assert.equal(moved.moved, true);
  assert.equal(moved.position, 580);
  assert.equal(f.root.scrollTop, 10);
  assert.equal(f.restore().restored, true);
  assert.equal(f.grid.scrollTop, 100);
  assert.equal(f.context.__limaScanSessionV1, undefined);
});
test("generic scan never scrolls a private shadow host", () => {
  const f = fixture({privateHost: true});
  const start = f.step();
  assert.equal(start.position, 10);
  f.step();
  assert.equal(f.grid.scrollTop, 100);
  assert(f.root.scrollTop > 10);
  assert.equal(f.restore().restored, true);
});
test("scan preserves a user's intervening scroll instead of forcing restoration", () => {
  const f = fixture();
  f.step();
  f.step();
  f.grid.scrollTop = 900;
  assert.equal(f.step().error, "scroll_changed");
  assert.equal(f.restore().restored, false);
  assert.equal(f.grid.scrollTop, 900);
});
test("scan never restores an old page generation or route", () => {
  const f = fixture();
  f.step();
  f.step();
  f.context.__limaPageSessionV1.pageGeneration += 1;
  assert.equal(f.restore().restored, false);
  assert.equal(f.grid.scrollTop, 580);
});
