(() => {
  // Isolated world, main frame. Never reads form values, closed shadow roots,
  // frames, passwords, cookies, storage, scripts, or hidden/private content.
  const ignored = "script,style,noscript,template,input,textarea,select,[contenteditable],[role='textbox'],[hidden],[aria-hidden='true'],[data-lima-private]";
  const visibility = new WeakMap();
  const parent = element => element?.parentElement || element?.getRootNode?.()?.host || null;
  const visible = element => {
    if (!element) return false;
    if (visibility.has(element)) return visibility.get(element);
    let current = element, depth = 0, result = element.getClientRects().length > 0;
    while (result && current && depth++ < 128) {
      if (current.closest(ignored)) { result = false; break; }
      const style = getComputedStyle(current);
      if (style.display === "none" || style.visibility === "hidden" ||
          style.visibility === "collapse" || Number(style.opacity) === 0) result = false;
      current = parent(current);
    }
    if (current) result = false;
    visibility.set(element, result);
    return result;
  };
  let exhausted = false, remainingNodes = 60000;
  function* nodes(root, depth = 0) {
    if (!root || depth > 32) { exhausted = true; return; }
    // Include open shadow DOM used by Lightning web components. Site access and
    // private-ancestor checks still apply across the shadow host boundary.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (--remainingNodes < 0) { exhausted = true; return; }
      yield node;
      if (node.nodeType === 1 && node.shadowRoot && visible(node)) yield* nodes(node.shadowRoot, depth + 1);
    }
    if (root.shadowRoot && visible(root)) yield* nodes(root.shadowRoot, depth + 1);
  }
  function textWithin(root, limit, ranges = null) {
    if (!root) return "";
    const parts = [];
    let length = 0;
    for (const node of nodes(root)) {
      if (length >= limit) { exhausted = true; break; }
      if (node.nodeType !== 3 || !visible(parent(node))) continue;
      const slices = ranges ? ranges.flatMap(range => {
        try {
          if (!range.intersectsNode(node)) return [];
          const start = range.startContainer === node ? range.startOffset : 0;
          const end = range.endContainer === node ? range.endOffset : node.textContent.length;
          return [node.textContent.slice(start, end)];
        } catch { return []; }
      }) : [node.textContent];
      for (const slice of slices) {
        const text = slice.replace(/\s+/g, " ").trim();
        if (!text) continue;
        if (parts.length) length += 1;
        const part = text.slice(0, Math.max(0, limit - length));
        if (part.length < text.length) exhausted = true;
        if (part) { parts.push(part); length += part.length; }
      }
    }
    return parts.join("\n");
  }
  function linkURL(element) {
    if (element.tagName !== "A" && element.getAttribute("role") !== "link") return null;
    for (const attribute of ["href", "data-href", "data-url"]) {
      const raw = element.getAttribute(attribute)?.trim();
      if (!raw || raw.startsWith("#") || raw.length > 2048) continue;
      let url;
      try { url = new URL(raw, document.baseURI || location.href); } catch { continue; }
      if (url.protocol !== "https:" || url.username || url.password || url.href.length > 2048) continue;
      return {href: url.href, source: attribute};
    }
    return null; // Never synthesize Salesforce record IDs or execute onclick.
  }
  function rowContext(element) {
    for (let node = parent(element), depth = 0; node && depth++ < 8; node = parent(node)) {
      if (node.tagName === "TR" || node.getAttribute("role") === "row") return textWithin(node, 512);
    }
    return null;
  }
  // Return only controls the packaged interaction adapter can address with a
  // unique, stable selector. Never include field values or controls in private
  // subtrees. Shadow-root controls are omitted because the adapter targets the
  // main document only.
  const safeToken = value => typeof value === "string" && /^[A-Za-z_][A-Za-z0-9_-]{0,127}$/.test(value);
  const sensitiveField = element => {
    const kind = (element.getAttribute("type") || "").toLowerCase();
    const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
    return ["password", "file"].includes(kind) ||
      /(?:password|one-time-code|cc-)/.test(autocomplete);
  };
  function controlKind(element) {
    const tag = element.tagName?.toLowerCase();
    if (!["form", "button", "input", "textarea"].includes(tag) &&
        !element.isContentEditable && element.getAttribute("role") !== "button") return null;
    if (element.disabled || element.hasAttribute("disabled") || element.getAttribute("aria-disabled") === "true") return null;
    if (tag === "form") {
      return [...element.querySelectorAll("input")].some(sensitiveField) ? null : "submit";
    }
    if (tag === "button") return (element.getAttribute("type") || "submit").toLowerCase() === "button" ? "click" : null;
    if (tag === "input") {
      if (sensitiveField(element)) return null;
      const kind = (element.getAttribute("type") || "text").toLowerCase();
      if (["button", "checkbox", "radio"].includes(kind)) return "click";
      if (["text", "search", "email", "url", "tel", "number"].includes(kind)) return "type";
      return null;
    }
    if (tag === "textarea" || element.isContentEditable) return sensitiveField(element) ? null : "type";
    if (tag !== "a" && element.getAttribute("role") === "button") return "click";
    return null;
  }
  function visibleControl(element) {
    if (!element.getClientRects().length || element.hasAttribute("hidden") ||
        element.hasAttribute("data-lima-private") || element.getAttribute("aria-hidden") === "true") return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" &&
      style.visibility !== "collapse" && Number(style.opacity) !== 0 &&
      (!parent(element) || visible(parent(element)));
  }
  function controlSelector(element) {
    if (element.getRootNode && element.getRootNode() !== document) return null;
    const tag = element.tagName.toLowerCase();
    const supportedTag = ["button", "input", "textarea", "form"].includes(tag);
    const candidates = [];
    const id = element.getAttribute("id");
    if (safeToken(id)) candidates.push(supportedTag ? `${tag}#${id}` : `#${id}`);
    const name = element.getAttribute("name");
    if (supportedTag && safeToken(name)) candidates.push(`${tag}[name="${name}"]`);
    const classes = (element.getAttribute("class") || "").split(/\s+/).filter(safeToken).slice(0, 3);
    for (const className of classes) candidates.push(supportedTag ? `${tag}.${className}` : `.${className}`);
    if (supportedTag) candidates.push(tag);
    for (const selector of candidates) {
      try {
        const matches = document.querySelectorAll(selector);
        if (matches.length === 1 && matches[0] === element) return selector;
      } catch {}
    }
    return null;
  }
  let inspectedControls = 0;
  function control(element) {
    const action = controlKind(element);
    if (!action) return null;
    if (++inspectedControls > 200) { exhausted = true; return null; }
    if (!visibleControl(element)) return null;
    const selector = controlSelector(element);
    if (!selector) return null;
    const label = (element.getAttribute("aria-label") || element.getAttribute("title") ||
      (action === "click" ? textWithin(element, 128) : "") ||
      element.getAttribute("placeholder") || element.getAttribute("name") || element.getAttribute("id") || "").trim().slice(0, 128);
    if (!label) return null;
    return {selector, action, label};
  }
  const documentRoot = document.body || document.documentElement;
  const root = document.querySelector("main,article,[role=main]") || documentRoot;
  const text = textWithin(root, 32000);
  const links = [], headings = [], controls = [], seen = new Set();
  let scanned = 0;
  for (const element of nodes(documentRoot)) {
    if (++scanned > 20000) { exhausted = true; break; }
    if (element.nodeType !== 1) continue;
    const actionable = control(element);
    if (actionable) {
      if (controls.length < 100) controls.push(actionable);
      else exhausted = true;
    }
    if (!visible(element)) continue;
    if (headings.length < 60 && (/^H[1-6]$/.test(element.tagName) || element.getAttribute("role") === "heading")) {
      headings.push(textWithin(element, 256));
    }
    const destination = linkURL(element);
    if (!destination) continue;
    const label = textWithin(element, 256);
    const key = destination.href + "\n" + label;
    if (seen.has(key)) continue;
    if (links.length >= 150) { exhausted = true; break; }
    seen.add(key);
    links.push({...destination, text: label,
      accessibleName: element.getAttribute("aria-label")?.slice(0, 256) || null,
      title: element.getAttribute("title")?.slice(0, 256) || null,
      rowContext: rowContext(element)});
  }
  const selection = window.getSelection();
  const ranges = [];
  for (let i = 0; i < Math.min(selection?.rangeCount || 0, 8); i++) ranges.push(selection.getRangeAt(i));
  const selectedText = ranges.length ? textWithin(documentRoot, 8000, ranges) : "";
  return {url: location.href, title: document.title.slice(0, 256),
    text, selection: selectedText, links, headings, controls,
    truncated: exhausted, untrustedPageContent: true,
    interactionSupport: "Explicit HTTPS site grants support bounded navigation. Discoverable controls list safe selectors for Lima-confirmed click, text entry, and form submission; arbitrary scripts and sensitive fields remain excluded."};
})()
