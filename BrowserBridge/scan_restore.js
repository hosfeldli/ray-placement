(() => {
  "use strict";
  const state = globalThis.__limaScanSessionV1;
  delete globalThis.__limaScanSessionV1;
  const page = globalThis.__limaPageSessionV1;
  if (!state || !page || page.document !== document ||
      state.documentID !== page.documentID ||
      state.pageGeneration !== page.pageGeneration ||
      state.url !== location.href || !state.element?.isConnected ||
      Math.abs(state.element.scrollTop - state.lastTop) > 4) return {restored: false};
  state.element.scrollTop = state.originalTop;
  return {restored: Math.abs(state.element.scrollTop - state.originalTop) <= 2};
})()
