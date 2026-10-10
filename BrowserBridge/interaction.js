"use strict";
/* Static, packaged page interaction adapter. It never evaluates page text or code. */
(() => {
  if (globalThis.__limaBrowserInteractionV1) return;
  globalThis.__limaBrowserInteractionV1 = true;

  const code = value => ({error: value});
  const safeRef = value => typeof value === "string" && /^c_[1-9][0-9]{0,2}$/.test(value);
  const safeText = value => typeof value === "string" && value.length <= 4000 &&
    !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);

  function target(ref, expected) {
    if (!safeRef(ref)) throw new Error("invalid_target");
    const session = globalThis.__limaPageSessionV1;
    if (!session || session.document !== document || session.url !== location.href ||
        session.documentID !== expected.documentID ||
        session.pageGeneration !== expected.pageGeneration ||
        session.snapshotRevision !== expected.snapshotRevision ||
        session.mutationRevision !== expected.mutationRevision) throw new Error("target_stale");
    const element = session.targets?.get(ref);
    if (!element) throw new Error("target_stale");
    if (expected) {
      const label = (element.getAttribute("aria-label") || element.getAttribute("title") ||
        (expected.action === "click" ? element.textContent : "") ||
        element.getAttribute("placeholder") || element.getAttribute("name") ||
        element.getAttribute("id") || "").replace(/\s+/g, " ").trim().slice(0, 128);
      if (element.tagName.toLowerCase() !== expected.tag || label !== expected.label) {
        throw new Error("target_stale");
      }
    }
    if (!element.isConnected || !element.getClientRects().length) throw new Error("target_not_visible");
    if (element.disabled || element.hasAttribute("disabled") ||
        element.getAttribute("aria-disabled") === "true") throw new Error("target_not_interactable");
    for (let node = element, depth = 0; node && depth++ < 128;
         node = node.parentElement || node.getRootNode?.()?.host || null) {
      const style = getComputedStyle(node);
      if (node.hasAttribute("hidden") || node.hasAttribute("data-lima-private") ||
          node.getAttribute("aria-hidden") === "true" || style.display === "none" ||
          style.visibility === "hidden" || style.visibility === "collapse" || Number(style.opacity) === 0) {
        throw new Error("target_not_visible");
      }
    }
    return element;
  }

  function emit(element, type) {
    element.dispatchEvent(new Event(type, {bubbles: true}));
  }

  function click(element) {
    const tag = element.tagName.toLowerCase();
    if (tag === "a" || tag === "form") throw new Error("unsupported_target");
    if (tag === "button" && (element.type || "submit").toLowerCase() !== "button") {
      throw new Error("submit_requires_form_tool");
    }
    if (tag === "input" && !["button", "checkbox", "radio"].includes((element.type || "").toLowerCase())) {
      throw new Error("unsupported_target");
    }
    if (!["button", "input"].includes(tag) && element.getAttribute("role") !== "button") {
      throw new Error("unsupported_target");
    }
    element.click();
    return {performed: "click", target: tag};
  }

  function sensitiveField(element) {
    const kind = (element.getAttribute("type") || "").toLowerCase();
    const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
    return ["password", "file"].includes(kind) ||
      /(?:password|one-time-code|cc-)/.test(autocomplete);
  }

  function type(element, text) {
    if (!safeText(text)) throw new Error("invalid_text");
    if (element.readOnly || element.hasAttribute("readonly") ||
        element.getAttribute("aria-readonly") === "true") throw new Error("target_not_interactable");
    const tag = element.tagName.toLowerCase();
    if (tag === "input") {
      const kind = (element.type || "text").toLowerCase();
      if (!["text", "search", "email", "url", "tel", "number"].includes(kind) || sensitiveField(element)) {
        throw new Error("sensitive_or_unsupported_target");
      }
      element.focus();
      element.value = text;
      emit(element, "input");
      emit(element, "change");
    } else if (tag === "textarea") {
      if (sensitiveField(element)) throw new Error("sensitive_or_unsupported_target");
      element.focus();
      element.value = text;
      emit(element, "input");
      emit(element, "change");
    } else if (element.isContentEditable) {
      if (sensitiveField(element)) throw new Error("sensitive_or_unsupported_target");
      element.focus();
      element.textContent = text;
      emit(element, "input");
      emit(element, "change");
    } else {
      throw new Error("sensitive_or_unsupported_target");
    }
    return {performed: "type", target: tag};
  }

  function submit(element) {
    if (element.tagName.toLowerCase() !== "form" || typeof element.requestSubmit !== "function") {
      throw new Error("unsupported_target");
    }
    if ([...element.querySelectorAll("input,textarea,select,[contenteditable]")].some(sensitiveField)) {
      throw new Error("sensitive_or_unsupported_target");
    }
    element.requestSubmit();
    return {performed: "submit", target: "form"};
  }

  browser.runtime.onMessage.addListener((message, sender) => {
    if (!message || message.type !== "lima-browser-interaction" ||
        sender.id !== browser.runtime.id || !safeRef(message.internalRef)) return undefined;
    try {
      const expected = message.expected;
      if (!expected || typeof expected !== "object" ||
          !["click", "type", "submit"].includes(expected.action) ||
          typeof expected.tag !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(expected.tag) ||
          typeof expected.label !== "string" || !expected.label || expected.label.length > 128 ||
          typeof expected.documentID !== "string" || expected.documentID.length > 128 ||
          !Number.isSafeInteger(expected.pageGeneration) || !Number.isSafeInteger(expected.snapshotRevision) ||
          !Number.isSafeInteger(expected.mutationRevision) ||
          message.command !== `browser.${expected.action}`) throw new Error("invalid_target");
      const element = target(message.internalRef, expected);
      switch (message.command) {
        case "browser.click": return click(element);
        case "browser.type": return type(element, message.text);
        case "browser.submit": return submit(element);
        default: return code("unsupported_command");
      }
    } catch (error) {
      const value = error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : "interaction_failed";
      return code(value);
    }
  });
})();