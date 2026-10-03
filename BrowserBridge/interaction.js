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
    const style = getComputedStyle(element);
    if (!element.isConnected || !element.getClientRects().length ||
        style.display === "none" || style.visibility === "hidden") {
      throw new Error("target_not_visible");
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

  function type(element, text) {
    if (!safeText(text)) throw new Error("invalid_text");
    const tag = element.tagName.toLowerCase();
    if (tag === "input") {
      const kind = (element.type || "text").toLowerCase();
      const autocomplete = (element.autocomplete || "").toLowerCase();
      if (!["text", "search", "email", "url", "tel", "number"].includes(kind) ||
          ["password", "current-password", "new-password", "one-time-code"].some(value => autocomplete.includes(value))) {
        throw new Error("sensitive_or_unsupported_target");
      }
      element.focus();
      element.value = text;
      emit(element, "input");
      emit(element, "change");
    } else if (tag === "textarea") {
      element.focus();
      element.value = text;
      emit(element, "input");
      emit(element, "change");
    } else if (element.isContentEditable) {
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