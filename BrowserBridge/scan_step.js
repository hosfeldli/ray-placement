(() => {
  "use strict";
  // Metadata-only, bounded viewport movement. No page script, caller selector,
  // form value, frame, storage, or network API is read here.
  const page = globalThis.__limaPageSessionV1;
  if (!page || page.document !== document) return {error: "page_not_ready"};
  const key = "__limaScanSessionV1";
  const privateAncestor = "[hidden],[aria-hidden='true'],[data-lima-private],[contenteditable],[role='textbox']";
  const parent = element => element?.parentElement || element?.getRootNode?.()?.host || null;
  const visible = element => {
    if (!element || !element.getClientRects?.().length) return false;
    let current = element, depth = 0;
    while (current && depth++ < 128) {
      if (current.closest?.(privateAncestor) || !current.getClientRects?.().length) return false;
      const style = getComputedStyle(current);
      if (style.display === "none" || style.visibility === "hidden" ||
          style.visibility === "collapse" || Number(style.opacity) === 0) return false;
      current = parent(current);
    }
    return !current;
  };
  function chooseScroller() {
    const root = document.scrollingElement || document.documentElement;
    const viewportArea = Math.max(1, innerWidth * innerHeight);
    let best = root, bestScore = -1, inspected = 0;
    const consider = element => {
      const travel = Math.max(0, element.scrollHeight - element.clientHeight);
      if (travel < 32 || element.clientHeight <= 0 || !visible(element)) return;
      if (element !== root) {
        const overflow = getComputedStyle(element).overflowY;
        if (!["auto", "scroll", "overlay"].includes(overflow)) return;
      }
      const rect = element.getBoundingClientRect?.() || {width: innerWidth, height: innerHeight};
      const coverage = Math.min(1, Math.max(0, rect.width) * Math.max(0, rect.height) / viewportArea);
      if (element !== root && coverage < 0.08) return;
      const semantic = element.matches?.("[role='grid'],[role='table'],[role='list'],table") ||
        element.closest?.("[role='grid'],[role='table'],[role='list'],table") ? 1.6 : 1;
      const score = coverage * (element === root ? 1 : 2.5) * semantic *
        (1 + Math.min(4, travel / element.clientHeight) * 0.1);
      if (score > bestScore) { best = element; bestScore = score; }
    };
    consider(root);
    // Use a bounded DOM walk rather than a site-specific selector. Open shadow
    // roots are traversed because virtualized grids commonly live there.
    function visit(treeRoot, depth) {
      if (!treeRoot || depth > 16 || inspected >= 4000) return;
      const walker = document.createTreeWalker(treeRoot, NodeFilter.SHOW_ELEMENT);
      let element;
      while (inspected < 4000 && (element = walker.nextNode())) {
        inspected += 1;
        if (element !== root) consider(element);
        if (element.shadowRoot && visible(element)) visit(element.shadowRoot, depth + 1);
      }
    }
    visit(document.documentElement, 0);
    return best;
  }
  let state = globalThis[key];
  if (!state) {
    const element = chooseScroller();
    state = {element, documentID: page.documentID, pageGeneration: page.pageGeneration,
      url: location.href, originalTop: element.scrollTop, lastTop: element.scrollTop, passes: 0};
    globalThis[key] = state;
    return {initialized: true, moved: false, canAdvance: element.scrollHeight > element.clientHeight + 32,
      position: element.scrollTop, maximum: Math.max(0, element.scrollHeight - element.clientHeight)};
  }
  if (state.documentID !== page.documentID || state.pageGeneration !== page.pageGeneration ||
      state.url !== location.href || !state.element?.isConnected) return {error: "page_changed"};
  const element = state.element;
  // Do not fight the user's own scroll or a page that auto-repositioned itself.
  if (Math.abs(element.scrollTop - state.lastTop) > 4) return {error: "scroll_changed"};
  const maximum = Math.max(0, element.scrollHeight - element.clientHeight);
  const before = element.scrollTop;
  const step = Math.max(160, Math.floor(element.clientHeight * 0.8));
  element.scrollTop = Math.min(maximum, before + step);
  state.passes += 1;
  const after = element.scrollTop;
  state.lastTop = after;
  return {initialized: false, moved: after > before + 2, canAdvance: after < maximum - 2,
    position: after, maximum, pass: state.passes};
})()
