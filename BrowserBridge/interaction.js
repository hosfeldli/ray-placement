"use strict";
/* Static, packaged page interaction adapter. It never evaluates page text or code. */
(() => {
  if (globalThis.__limaBrowserInteractionV1) return;
  globalThis.__limaBrowserInteractionV1 = true;

  const code = value => ({error: value});
  const safeSelector = value => typeof value === "string" && value.length >= 1 && value.length <= 256 &&
    !/[\u0000-\u0020\u007f]/.test(value) && /^[A-Za-z0-9_.#\[\]="'-]+$/.test(value);
  const safeText = value => typeof value === "string" && value.length <= 4000 &&
    !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);

  function target(selector) {
    if (!safeSelector(selector)) throw new Error("invalid_selector");
    const matches = document.querySelectorAll(selector);
    if (!matches.length) throw new Error("target_not_found");
    if (matches.length !== 1) throw new Error("target_ambiguous");
    const element = matches[0];
    if (!element.isConnected || !element.getClientRects().length) throw new Error("target_not_visible");
    if (element.disabled || element.hasAttribute("disabled") ||
        element.getAttribute("aria-disabled") === "true") throw new Error("target_not_interactable");
    for (let node = element, depth = 0; node && depth++ < 128; node = node.parentElement) {
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
        sender.id !== browser.runtime.id || !safeSelector(message.selector)) return undefined;
    try {
      const element = target(message.selector);
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