(() => {
  "use strict";
  // This script returns only identity and revision metadata. It never reads
  // page content, storage, form values, or frames.
  const state = globalThis.__limaPageSessionV1;
  if (!state || state.document !== document) return null;
  if (state.url !== location.href) {
    state.url = location.href;
    state.pageGeneration += 1;
  }
  return {url: location.href, documentID: state.documentID,
    pageGeneration: state.pageGeneration, snapshotRevision: state.snapshotRevision,
    mutationRevision: state.mutationRevision};
})()
