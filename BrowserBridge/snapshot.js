(() => {
  // Isolated world, main frame, bounded visible text. Never reads form values,
  // editable fields, passwords, cookies, storage, scripts, or hidden DOM.
  const ignored = "script,style,noscript,template,input,textarea,select,[contenteditable],[role='textbox'],[hidden],[aria-hidden='true'],[data-lima-private]";
  const visibility = new WeakMap();
  const visible = element => {
    if (!element || element.closest(ignored)) return false;
    if (visibility.has(element)) return visibility.get(element);
    let current = element, depth = 0, result = element.getClientRects().length > 0;
    while (result && current && depth++ < 128) {
      const style = getComputedStyle(current);
      if (style.display === "none" || style.visibility === "hidden" ||
          style.visibility === "collapse" || Number(style.opacity) === 0) result = false;
      current = current.parentElement;
    }
    if (current) result = false; // Reject pathological ancestor chains.
    visibility.set(element, result);
    return result;
  };
  let exhausted = false, remainingNodes = 24000;
  function textWithin(root, limit, ranges = null) {
    if (!root) return "";
    const parts = [];
    let length = 0;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (--remainingNodes < 0 || length >= limit) { exhausted = true; break; }
      if (!visible(node.parentElement)) continue;
      const slices = ranges ? ranges.flatMap(range => {
        if (!range.intersectsNode(node)) return [];
        const start = range.startContainer === node ? range.startOffset : 0;
        const end = range.endContainer === node ? range.endOffset : node.textContent.length;
        return [node.textContent.slice(start, end)];
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
  const root = document.querySelector("main,article,[role=main]") || document.body;
  const text = textWithin(root, 32000);
  const links = [];
  const documentRoot = document.body || document.documentElement;
  const walker = document.createTreeWalker(documentRoot, NodeFilter.SHOW_ELEMENT);
  let element, scanned = 0;
  while ((element = walker.nextNode()) && scanned++ < 20000 && links.length < 150) {
    if (element.tagName !== "A" || !visible(element)) continue;
    const href = element.href;
    if (!href || href.length > 2048) continue;
    let url;
    try { url = new URL(href); } catch { continue; }
    if (url.protocol !== "https:" || url.username || url.password) continue;
    // Never use aggregate textContent: descendants may be hidden or editable.
    links.push({href, text: textWithin(element, 256),
      accessibleName: element.getAttribute("aria-label")?.slice(0, 256) || null,
      title: element.getAttribute("title")?.slice(0, 256) || null});
  }
  const selection = window.getSelection();
  const ranges = [];
  for (let i = 0; i < Math.min(selection?.rangeCount || 0, 8); i++) ranges.push(selection.getRangeAt(i));
  // Endpoint checks alone leak hidden/editable descendants between endpoints.
  const selectedText = ranges.length ? textWithin(documentRoot, 8000, ranges) : "";
  return {url: location.href, title: document.title.slice(0, 256),
    text, selection: selectedText, links,
    truncated: exhausted || scanned >= 20000 || links.length >= 150,
    untrustedPageContent: true};
})()
