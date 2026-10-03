const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../../BrowserBridge/snapshot.js"), "utf8");
// Minimal DOM fixture exercises the production snapshot script, not a copy of its filters.
function text(value) { return {nodeType: 3, textContent: value, parentElement: null}; }
function descendants(root) { return root.children.flatMap(n => [n, ...(n.children ? descendants(n) : [])]); }
function select(root, selector, includeRoot = false) {
  const match = /^(button|input|textarea|form)?(?:(#|\.)([A-Za-z_][A-Za-z0-9_-]*)|\[name="([A-Za-z_][A-Za-z0-9_-]*)"\])?$/.exec(selector);
  if (!match) return [];
  return (includeRoot ? [root, ...descendants(root)] : descendants(root)).filter(node => {
    if (node.nodeType !== 1 || (match[1] && node.tagName.toLowerCase() !== match[1])) return false;
    if (match[2] === "#" && node.getAttribute("id") !== match[3]) return false;
    if (match[2] === "." && !(node.getAttribute("class") || "").split(/\s+/).includes(match[3])) return false;
    if (match[4] && node.getAttribute("name") !== match[4]) return false;
    return true;
  });
}
function element(tag, children = [], attributes = {}, style = {}) {
  const e = {nodeType: 1, tagName: tag.toUpperCase(), children, attributes, parentElement: null,
    style: {display: "block", visibility: "visible", opacity: "1", ...style},
    getClientRects: () => [{}], getAttribute: key => attributes[key] ?? null,
    hasAttribute: key => key in attributes,
    disabled: "disabled" in attributes, isContentEditable: attributes.contenteditable === "true",
    querySelectorAll(selector) {
      if (selector === "input,textarea,select,[contenteditable]") {
        return descendants(this).filter(node => node.nodeType === 1 &&
          (["INPUT", "TEXTAREA", "SELECT"].includes(node.tagName) || node.hasAttribute("contenteditable")));
      }
      return select(this, selector);
    },
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
  return vm.runInNewContext(source, {
    URL, NodeFilter: {SHOW_TEXT: 4, SHOW_ELEMENT: 1}, location: {href: "https://example.com/case"},
    getComputedStyle: node => node.style,
    document: {body, documentElement: body, baseURI: "https://example.com/case", title: "Fixture", querySelector: () => body,
      querySelectorAll: selector => select(body, selector, true),
      createTreeWalker(root, mask) {
        const nodes = descendants(root).filter(n => n.nodeType === 1 ? (mask & 1) : (mask & 4));
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
function shadow(host, children) {
  const root = {children, host};
  host.shadowRoot = root;
  for (const child of children) child.getRootNode = () => root;
  return host;
}
test("Lightning-style shadow links retain real URLs and visible row context", () => {
  const link = element("a", [text("00012345")], {href: "/lightning/r/Case/500000000000001/view"});
  const row = element("tr", [element("td", [link]), element("td", [text("Open shipment")])]);
  const component = shadow(element("lightning-datatable"), [row]);
  const result = snapshot(element("main", [component]));
  assert.equal(result.links[0].href, "https://example.com/lightning/r/Case/500000000000001/view");
  assert(result.links[0].rowContext.includes("Open shipment"));
  assert(result.text.includes("00012345"));
});
test("hidden and private shadow hosts cannot leak text or URLs", () => {
  for (const attributes of [{hidden: ""}, {"data-lima-private": ""}, {contenteditable: "true"}]) {
    const host = shadow(element("x-private", [], attributes), [
      element("a", [text("SHADOW SECRET")], {href: "https://example.com/secret"})
    ]);
    const result = snapshot(element("main", [host]));
    assert(!JSON.stringify(result).includes("SHADOW SECRET"));
    assert.equal(result.links.length, 0);
  }
});
test("role links expose declared HTTPS destinations but never invented record IDs or onclick", () => {
  const result = snapshot(element("main", [
    element("span", [text("Report")], {role: "link", "data-href": "/lightning/r/Report/00O000000000001/view"}),
    element("a", [text("Not navigable")], {href: "javascript:void(0)", "data-recordid": "500000000000002"}),
    element("button", [text("Mutation")], {"data-url": "/delete", onclick: "save()"}),
    element("a", [text("Bad")], {href: "http://example.com"}),
    element("h2", [text("Report results")])
  ]));
  assert.equal(result.links.length, 1);
  assert.equal(result.links[0].source, "data-href");
  assert(result.links[0].href.endsWith("/lightning/r/Report/00O000000000001/view"));
  assert.equal(result.headings[0], "Report results");
});
test("duplicate rendered links are deduplicated", () => {
  const result = snapshot(element("main", Array.from({length: 4}, () =>
    element("a", [text("Same report")], {href: "/report"}))));
  assert.equal(result.links.length, 1);
});
test("role-button links remain navigable links, not advertised click controls", () => {
  const result = snapshot(element("main", [
    element("a", [text("Continue")], {id: "continue-link", role: "button", href: "https://example.com/next"})
  ]));
  assert.equal(result.links.length, 1);
  assert.equal(result.links[0].href, "https://example.com/next");
  assert.equal(result.controls.length, 0);
});
test("a sole unlabeled-selector button uses a verified unique tag selector", () => {
  const result = snapshot(element("main", [element("button", [text("Continue")], {type: "button"})]));
  assert.equal(result.controls.length, 1);
  assert.equal(result.controls[0].selector, "button");
  assert.equal(result.controls[0].label, "Continue");
});
test("snapshot returns the exact IANA hyperlink and only uniquely selectable safe controls", () => {
  const body = element("main", [
    element("a", [text("Learn more")], {href: "https://iana.org/help/example-domains"}),
    element("button", [text("Inspect")], {id: "inspect", type: "button"}),
    element("input", [], {name: "query", type: "search", placeholder: "Search", value: "PRIVATE QUERY"}),
    element("input", [], {id: "locked", type: "text", readonly: "", placeholder: "Read-only"}),
    element("textarea", [], {id: "aria-locked", "aria-readonly": "true", placeholder: "Read-only"}),
    element("form", [element("input", [], {type: "hidden", value: "CSRF SECRET"})],
      {id: "send", "aria-label": "Send message"}),
    element("form", [element("input", [], {type: "password", value: "SECRET"})],
      {id: "login", "aria-label": "Sign in"}),
    element("form", [element("textarea", [], {autocomplete: "cc-number"})],
      {id: "payment", "aria-label": "Pay"}),
    element("button", [text("Ambiguous")], {id: "duplicate", type: "button"}),
    element("button", [text("Ambiguous")], {id: "duplicate", type: "button"}),
    element("div", [element("button", [text("Private button")], {id: "private", type: "button"})],
      {"data-lima-private": ""})
  ]);
  const result = snapshot(body);
  assert(result.links.some(link => link.href === "https://iana.org/help/example-domains"));
  assert.deepEqual(Array.from(result.controls, ({selector, action, label}) => [selector, action, label]), [
    ["button#inspect", "click", "Inspect"],
    ['input[name="query"]', "type", "Search"],
    ["form#send", "submit", "Send message"]
  ]);
  assert(!JSON.stringify(result).includes("PRIVATE QUERY"));
  assert(!JSON.stringify(result).includes("CSRF SECRET"));
  assert(!JSON.stringify(result).includes("SECRET"));
  assert(!JSON.stringify(result).includes("Private button"));
});
