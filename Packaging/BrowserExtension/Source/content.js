(() => {
  "use strict";

  if (globalThis.__LIMA_BROWSER_BRIDGE_INSTALLED__) {
    return { installed: true };
  }
  globalThis.__LIMA_BROWSER_BRIDGE_INSTALLED__ = true;

  let generation = 0;
  let elementMap = new Map();

  const sensitiveAutocomplete = new Set([
    "current-password",
    "new-password",
    "one-time-code",
    "cc-name",
    "cc-number",
    "cc-exp",
    "cc-exp-month",
    "cc-exp-year",
    "cc-csc"
  ]);

  function cleanText(value, limit = 180) {
    return String(value || "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, limit);
  }

  function isVisible(element) {
    if (!(element instanceof Element)) return false;
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
    return element.getClientRects().length > 0;
  }

  function labelFor(element) {
    const aria = cleanText(element.getAttribute("aria-label"));
    if (aria) return aria;
    if (element.labels && element.labels.length) {
      const labels = Array.from(element.labels).map(label => cleanText(label.innerText)).filter(Boolean);
      if (labels.length) return labels.join(" ");
    }
    return cleanText(
      element.innerText ||
      element.textContent ||
      element.getAttribute("title") ||
      element.getAttribute("placeholder") ||
      element.getAttribute("name")
    );
  }

  function roleFor(element) {
    const explicit = element.getAttribute("role");
    if (explicit) return explicit;
    const tag = element.tagName.toLowerCase();
    if (tag === "a") return "link";
    if (tag === "button") return "button";
    if (tag === "textarea") return "textbox";
    if (tag === "select") return "combobox";
    if (tag === "input") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (["submit", "button", "reset"].includes(type)) return "button";
      return "textbox";
    }
    return "control";
  }

  function describeInteractiveElements(maxElements) {
    generation += 1;
    elementMap = new Map();

    const selector = [
      "a[href]",
      "button",
      "input",
      "textarea",
      "select",
      "[role='button']",
      "[role='link']",
      "[contenteditable='true']"
    ].join(",");

    const output = [];
    for (const element of document.querySelectorAll(selector)) {
      if (output.length >= maxElements) break;
      if (!isVisible(element) || element.getAttribute("aria-hidden") === "true") continue;

      const id = `e${generation}-${output.length + 1}`;
      elementMap.set(id, element);

      const item = {
        id,
        role: roleFor(element),
        text: labelFor(element)
      };

      if (element instanceof HTMLAnchorElement && element.href) {
        try {
          const href = new URL(element.href, location.href);
          if (href.protocol === "http:" || href.protocol === "https:") item.href = href.href;
        } catch (_) {}
      }

      if (element instanceof HTMLInputElement) {
        item.inputType = (element.type || "text").toLowerCase();
        item.placeholder = cleanText(element.placeholder);
        item.autocomplete = cleanText(element.autocomplete);
      } else if (element instanceof HTMLTextAreaElement) {
        item.inputType = "textarea";
        item.placeholder = cleanText(element.placeholder);
        item.autocomplete = cleanText(element.autocomplete);
      }

      output.push(item);
    }
    return output;
  }

  function snapshot(params) {
    const maxTextCharacters = params.maxTextCharacters || 60000;
    const maxElements = params.maxElements || 250;
    const bodyText = cleanText(document.body?.innerText || "", maxTextCharacters);
    return {
      url: location.href,
      title: document.title || "",
      text: bodyText,
      elements: describeInteractiveElements(maxElements)
    };
  }

  function elementForID(elementID) {
    const element = elementMap.get(elementID);
    if (!element || !element.isConnected) {
      throw new Error("That page element is no longer available. Read the page again before acting.");
    }
    return element;
  }

  function clickElement(params) {
    const element = elementForID(params.elementID);
    if (!isVisible(element)) throw new Error("The requested element is not visible.");
    element.scrollIntoView({ block: "center", inline: "nearest", behavior: "auto" });
    element.click();
    return { clicked: true };
  }

  function typeIntoElement(params) {
    const element = elementForID(params.elementID);
    const text = String(params.text || "");

    const inputType = element instanceof HTMLInputElement ? (element.type || "text").toLowerCase() : "";
    const autocomplete = cleanText(element.getAttribute("autocomplete")).toLowerCase();
    if (inputType === "password" || sensitiveAutocomplete.has(autocomplete) || autocomplete.startsWith("cc-")) {
      throw new Error("Lima will not type into password, one-time-code, or payment fields.");
    }

    element.focus();

    if (element instanceof HTMLInputElement) {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      if (setter) setter.call(element, text);
      else element.value = text;
    } else if (element instanceof HTMLTextAreaElement) {
      const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")?.set;
      if (setter) setter.call(element, text);
      else element.value = text;
    } else if (element.isContentEditable) {
      element.textContent = text;
    } else {
      throw new Error("The requested element does not accept text.");
    }

    element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return { typed: true, characters: text.length };
  }

  function scrollPage(params) {
    const explicit = Number(params.amount || 0);
    const amount = explicit > 0 ? Math.min(explicit, window.innerHeight * 3) : window.innerHeight * 0.78;
    const delta = params.direction === "up" ? -amount : amount;
    window.scrollBy({ top: delta, behavior: "smooth" });
    return { scrolled: true, delta };
  }

  function resolveSalesforceCases(params) {
    const requested = (Array.isArray(params.caseNumbers) ? params.caseNumbers : [])
      .map(value => String(value).trim())
      .filter(Boolean);

    const anchors = Array.from(document.querySelectorAll("a[href]"));
    const matches = [];
    const unresolved = [];

    for (const caseNumber of requested) {
      const normalized = caseNumber.toLowerCase();
      const anchor = anchors.find(candidate => {
        const visible = cleanText(candidate.innerText).toLowerCase();
        const aria = cleanText(candidate.getAttribute("aria-label")).toLowerCase();
        const title = cleanText(candidate.getAttribute("title")).toLowerCase();
        return visible === normalized || aria === normalized || title === normalized;
      });

      if (!anchor) {
        unresolved.push(caseNumber);
        continue;
      }

      try {
        const url = new URL(anchor.href, location.href);
        if (url.protocol !== "http:" && url.protocol !== "https:") {
          unresolved.push(caseNumber);
          continue;
        }
        matches.push({ caseNumber, url: url.href });
      } catch (_) {
        unresolved.push(caseNumber);
      }
    }

    return { matches, unresolved };
  }

  browser.runtime.onMessage.addListener(message => {
    if (!message || message.source !== "lima-browser-bridge") return undefined;
    const params = message.params || {};

    switch (message.method) {
      case "snapshot": return Promise.resolve(snapshot(params));
      case "click": return Promise.resolve(clickElement(params));
      case "type": return Promise.resolve(typeIntoElement(params));
      case "scroll": return Promise.resolve(scrollPage(params));
      case "resolveSalesforceCases": return Promise.resolve(resolveSalesforceCases(params));
      default: return Promise.reject(new Error(`Unsupported page command: ${message.method}`));
    }
  });

  return { installed: true };
})();
