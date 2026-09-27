const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../../BrowserBridge/snapshot.js"), "utf8");
// Minimal DOM fixture exercises the production snapshot script, not a copy of its filters.
function text(value) { return {nodeType: 3, textContent: value, parentElement: null}; }
function element(tag, children = [], attributes = {}, style = {}) {
  const e = {nodeType: 1, tagName: tag.toUpperCase(), children, attributes, parentElement: null,
    style: {display: "block", visibility: "visible", opacity: "1", ...style},
    getClientRects: () => [{}], getAttribute: key => attributes[key] || null,
    closest() {
      for (let n = this; n; n = n.parentElement) {
        if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "INPUT", "TEXTAREA", "SELECT"].includes(n.tagName) ||
            ["contenteditable", "hidden", "data-lima-private"].some(key => key in n.attributes) ||
            n.attributes["aria-hidden"] === "true" || n.attributes.role === "textbox") return n;
      }
      return null;
    }};
  for (const child of children) child.parentElement = e;
  if (attributes.href) e.href = attributes.href;
  return e;
}
function snapshot(body, ranges = []) {
  const descendants = root => root.children.flatMap(n => [n, ...(n.children ? descendants(n) : [])]);
  return vm.runInNewContext(source, {
    URL, NodeFilter: {SHOW_TEXT: 4, SHOW_ELEMENT: 1}, location: {href: "https://example.com/case"},
    getComputedStyle: node => node.style,
    document: {body, documentElement: body, title: "Fixture", querySelector: () => body,
      createTreeWalker(root, mask) {
        const nodes = descendants(root).filter(n => n.nodeType === (mask === 4 ? 3 : 1));
        let i = 0; return {nextNode: () => nodes[i++] || null};
      }},
    window: {getSelection: () => ({rangeCount: ranges.length, getRangeAt: index => ranges[index]})}
  });
}
test("link labels and spanning selections exclude hidden/editable descendants", () => {
  const first = text("Visible start"), last = text("Visible end");
  const anchor = element("a", [text("00012345"), element("span", [text("HIDDEN TOKEN")], {hidden: ""}),
    element("span", [text("EDITABLE SECRET")], {contenteditable: "true"}),
    element("input", [text("PASSWORD")]), element("span", [text("TRANSPARENT")], {}, {opacity: "0"})],
    {href: "https://example.com/500000000000001", "aria-label": "Case 00012345"});
  const body = element("main", [first, anchor, last]);
  const result = snapshot(body, [{startContainer: first, startOffset: 0,
    endContainer: last, endOffset: last.textContent.length, intersectsNode: () => true}]);
  for (const secret of ["HIDDEN TOKEN", "EDITABLE SECRET", "PASSWORD", "TRANSPARENT"]) {
    assert(!JSON.stringify(result).includes(secret));
  }
  assert.equal(result.links[0].text, "00012345");
  assert(result.selection.includes("00012345")); assert(result.untrustedPageContent);
});
test("selection boundaries return only selected characters", () => {
  const t = text("before SELECTED after");
  const result = snapshot(element("main", [t]), [{startContainer: t, startOffset: 7,
    endContainer: t, endOffset: 15, intersectsNode: () => true}]);
  assert.equal(result.selection, "SELECTED");
});
test("sensitive ancestors suppress nested text and links", () => {
  const body = element("main", [
    element("div", [element("span", [text("CSS SECRET")])], {}, {visibility: "hidden"}),
    element("div", [element("a", [text("PRIVATE LINK")], {href: "https://example.com"})], {"data-lima-private": ""}),
    element("div", [text("ROLE SECRET")], {role: "textbox"}),
    element("p", [text("Public")])
  ]);
  const result = snapshot(body);
  assert.equal(result.text, "Public"); assert.equal(result.links.length, 0);
});
test("snapshot text and links remain bounded and omit credential-bearing links", () => {
  const body = element("main", [element("p", [text("x".repeat(40000))]),
    element("a", [text("Credential link")], {href: "https://user:password@example.com"}),
    ...Array.from({length: 180}, (_, i) => element("a", [text("Link " + i)], {href: "https://example.com/" + i}))]);
  const result = snapshot(body);
  assert(result.text.length <= 32000); assert.equal(result.links.length, 150);
  assert(!result.links.some(link => link.href.includes("password")));
  assert(result.truncated);
});
