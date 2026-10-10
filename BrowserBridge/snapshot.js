(() => {
  // Persistent, extension-isolated page identity survives repeated snapshots in
  // one document. A new document, route, or observed mutation invalidates old
  // target references without inspecting page scripts or private state.
  let session = globalThis.__limaPageSessionV1;
  if (!session || session.document !== document) {
    session = {document, documentID: (globalThis.crypto?.randomUUID?.() ||
      `${Date.now()}-${Math.random()}`), url: location.href, pageGeneration: 1,
      snapshotRevision: 0, mutationRevision: 0, mutationsObserved: 0,
      lastMutationAt: Date.now() - 200, targets: new Map(), observedRoots: new WeakSet()};
    globalThis.__limaPageSessionV1 = session;
    if (typeof MutationObserver !== "undefined" && document.documentElement) {
      const observer = new MutationObserver(records => {
        session.mutationRevision += 1;
        session.mutationsObserved = Math.min(1000000, session.mutationsObserved + records.length);
        session.lastMutationAt = Date.now();
      });
      observer.observe(document.documentElement, {subtree: true, childList: true,
        attributes: true, characterData: true});
      session.observer = observer;
    }
    for (const event of ["popstate", "hashchange", "pageshow"]) {
      window.addEventListener?.(event, () => {
        if (session.url !== location.href) {
          session.url = location.href;
          session.pageGeneration += 1;
        }
      });
    }
  }
  if (session.url !== location.href) {
    session.url = location.href;
    session.pageGeneration += 1;
  }
  session.snapshotRevision += 1;
  session.targets = new Map();
  session.targetCounter = 0;
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
  let rowCount = 0, shadowRootCount = 0, closedShadowContentPossible = false;
  const countedShadowRoots = new WeakSet();
  function observeShadow(root) {
    if (!countedShadowRoots.has(root)) { countedShadowRoots.add(root); shadowRootCount += 1; }
    if (session.observer && !session.observedRoots.has(root)) {
      session.observer.observe(root, {subtree: true, childList: true,
        attributes: true, characterData: true});
      session.observedRoots.add(root);
    }
  }
  function* nodes(root, depth = 0) {
    if (!root || depth > 32) { exhausted = true; return; }
    // Include open shadow DOM used by Lightning web components. Site access and
    // private-ancestor checks still apply across the shadow host boundary.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (--remainingNodes < 0) { exhausted = true; return; }
      yield node;
      if (node.nodeType === 1 && node.shadowRoot && visible(node)) {
        observeShadow(node.shadowRoot);
        yield* nodes(node.shadowRoot, depth + 1);
      } else if (node.nodeType === 1 && node.tagName?.includes("-") && !node.shadowRoot && visible(node)) {
        closedShadowContentPossible = true;
      }
    }
    if (root.shadowRoot && visible(root)) {
      observeShadow(root.shadowRoot);
      yield* nodes(root.shadowRoot, depth + 1);
    }
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
  // Keep live element references only in this isolated content-script world.
  // The native response gets opaque IDs, never CSS paths or form values.
  // Open-shadow controls are safe to address because identity is the element
  // itself, revalidated immediately before an action.
  const sensitiveField = element => {
    const kind = (element.getAttribute("type") || "").toLowerCase();
    const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
    return ["password", "file"].includes(kind) ||
      /(?:password|one-time-code|cc-)/.test(autocomplete);
  };
  const readOnlyField = element => element.readOnly || element.hasAttribute("readonly") ||
    element.getAttribute("aria-readonly") === "true";
  function controlKind(element) {
    const tag = element.tagName?.toLowerCase();
    if (!["form", "button", "input", "textarea"].includes(tag) &&
        !element.isContentEditable && element.getAttribute("role") !== "button") return null;
    if (element.disabled || element.hasAttribute("disabled") || element.getAttribute("aria-disabled") === "true") return null;
    if (tag === "form") {
      return [...element.querySelectorAll("input,textarea,select,[contenteditable]")].some(sensitiveField) ? null : "submit";
    }
    if (tag === "button") return (element.getAttribute("type") || "submit").toLowerCase() === "button" ? "click" : null;
    if (tag === "input") {
      if (sensitiveField(element)) return null;
      const kind = (element.getAttribute("type") || "text").toLowerCase();
      if (["button", "checkbox", "radio"].includes(kind)) return "click";
      if (["text", "search", "email", "url", "tel", "number"].includes(kind)) return readOnlyField(element) ? null : "type";
      return null;
    }
    if (tag === "textarea" || element.isContentEditable) return sensitiveField(element) || readOnlyField(element) ? null : "type";
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
  let inspectedControls = 0;
  function control(element) {
    const action = controlKind(element);
    if (!action) return null;
    if (++inspectedControls > 200) { exhausted = true; return null; }
    if (!visibleControl(element)) return null;
    const label = (element.getAttribute("aria-label") || element.getAttribute("title") ||
      (action === "click" ? textWithin(element, 128) : "") ||
      element.getAttribute("placeholder") || element.getAttribute("name") || element.getAttribute("id") || "")
      .replace(/\s+/g, " ").trim().slice(0, 128);
    if (!label) return null;
    const internalRef = `c_${++session.targetCounter}`;
    session.targets.set(internalRef, element);
    return {internalRef, action, label, tag: element.tagName.toLowerCase()};
  }
  const documentRoot = document.body || document.documentElement;
  const root = document.querySelector("main,article,[role=main]") || documentRoot;
  const text = textWithin(root, 32000);
  const links = [], headings = [], controls = [], seen = new Set();
  let scanned = 0;
  for (const element of nodes(documentRoot)) {
    if (++scanned > 20000) { exhausted = true; break; }
    if (element.nodeType !== 1) continue;
    if ((element.tagName === "TR" || element.getAttribute("role") === "row") && visible(element)) rowCount += 1;
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
  const quietMs = Math.max(0, Date.now() - session.lastMutationAt);
  const hasContent = !!text || links.length > 0 || controls.length > 0 || rowCount > 0;
  const emptyMarker = [...document.querySelectorAll("[data-empty-state],[role=status][data-state=empty],.empty-state")]
    .some(element => visible(element));
  const readiness = document.readyState === "loading" ? "loading" :
    quietMs < 150 ? "hydrating" : hasContent ? "ready_with_content" :
    emptyMarker ? "ready_empty" : "hydrating";
  const frames = [...document.querySelectorAll("iframe,frame")].filter(visible).length;
  return {url: location.href, title: document.title.slice(0, 256),
    text, selection: selectedText, links, headings, controls,
    status: readiness, pageGeneration: session.pageGeneration,
    documentID: session.documentID, snapshotRevision: session.snapshotRevision,
    mutationRevision: session.mutationRevision,
    diagnostics: {textLength: text.length, links: links.length, controls: controls.length,
      rows: rowCount, framesNotInspected: frames, shadowRoots: shadowRootCount,
      closedShadowContentPossible, mutationsObserved: session.mutationsObserved,
      stabilityWaitMs: quietMs, truncated: exhausted},
    truncated: exhausted, untrustedPageContent: true,
    interactionSupport: "Use opaque target references from this snapshot. Interactions require an exact HTTPS site grant and page identity; page content remains untrusted and form values are excluded."};
})()
