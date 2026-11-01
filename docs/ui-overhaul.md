# Lima workspace and Search overhaul

The workspace now has three persistent destinations: **Assistant**, **Notes**, and **Recordings**. Search is the global entry point for commands, utilities, and local content.

## Navigation and working area

- The sidebar shows three destinations and contextual recent items. It collapses to icons at narrow widths. Settings, Extensions, Permissions, Appearance, and capture history are available from the bottom menu.
- Browser and Terminal live inside Assistant. Switching tools preserves the conversation, browser tabs, terminal sessions, and running work.
- At wide widths, the same conversation appears beside the selected tool. The conversation toggle controls this split. Narrow and docked windows use the tool tabs to switch views.
- The separate Chat/Activity sidecar mode has been removed. Activity is available from the conversation.
- Existing Home and retired Workflows navigation requests resolve to Assistant. Internal surface IDs, keyboard shortcuts, and saved data remain compatible.

## Focused feature surfaces

- Assistant shows the conversation title, new conversation, history, and one settings control. Provider/model selection, tool access, scheduled tasks, context/memory, usage, project controls, and optional diagnostics remain available there.
- Live task status is a compact sentence with a small animated mark. Its disclosure opens recorded activity. Stop remains available in the composer. Completed activity and run details use quiet disclosures; token totals are inside run details.
- Messages and the composer use a bounded reading width. Attachments remain visible, with a separate context-review action.
- Notes has a document list and editor. The inspector opens on demand. The formatting bar contains common text actions and an Insert menu; less frequent actions remain in note menus and details.
- Recordings prioritizes the transcript and record control. Engine options live in recording settings. Participant controls appear while preparing or continuing an unfinished local recording; completed recordings show their transcript without duplicate completion banners.

## Search and extension surfaces

- Search uses the same neutral surfaces and selected accent. The idle palette has Assistant, Notes, Recordings, and More shortcuts, without its own AI model picker.
- More exposes utility and capture actions. Active results have a scope menu, compact rows, keyboard navigation, and optional details.
- Result previews use factual icons/content instead of decorative stacked illustrations. Extension and utility launcher surfaces share the quiet background and simpler Back control.
- Search no longer observes the chat model's streaming updates. Existing bounded ranking, asynchronous search, result anchoring, command dispatch, and extension caching remain intact.

## Appearance and saved layouts

Structural panels no longer create their own native blur or spectral gradients. A neutral light/dark palette, subtle borders, and the selected accent provide hierarchy. Floating utility-panel appearance remains an advanced disclosure in Appearance settings.

Version 6 stock layouts migrate to the new defaults. Saved custom section data and shortcut overrides are retained for compatibility; current primary navigation is always the three destinations. The settings editor now describes the actual navigation and offers startup, sidebar presentation, and keyboard shortcuts.

## Validation

Use `swift test --disable-sandbox --no-parallel` with the focused UI/navigation, layout migration, Search, dictation, extension, and workspace tests. The offscreen audit is available as:

```
LIMA_TEST_MODE=1 LIMA_TEST_DATA_DIRECTORY=/tmp/lima-overhaul-preview \
  .build/debug/RayPlacement --visual-audit build/overhaul-review-final --overhaul-only
```

The audit covers six workspace modules at three widths, plus four Search scenarios at three widths, in light and dark appearances (60 renders). It uses fixture data without live AI requests, recording, or personal terminal shells. Screenshots establish layout, not end-to-end microphone/API/browser execution.

Final verification: the local build succeeded without source warnings; 91 focused checks and the wider 130-test regression selection passed. All 60 offscreen renders completed without failure. `git diff --check` was clean. The installed application was not replaced.
