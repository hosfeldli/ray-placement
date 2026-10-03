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
  const documentRoot = document.body || document.documentElement;
  const root = document.querySelector("main,article,[role=main]") || documentRoot;
  const text = textWithin(root, 32000);
  const links = [], headings = [], seen = new Set();
  let scanned = 0;
  for (const element of nodes(documentRoot)) {
    if (++scanned > 20000) { exhausted = true; break; }
    if (element.nodeType !== 1 || !visible(element)) continue;
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
    text, selection: selectedText, links, headings,
    truncated: exhausted, untrustedPageContent: true,
    interactionSupport: "Explicit HTTPS site grants support bounded navigation. Compatible companions also support Lima-confirmed click, text entry, and form submission; arbitrary scripts and password fields remain excluded."};
})()
