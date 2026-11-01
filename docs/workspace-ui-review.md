# Workspace, search and quick capture review

The baseline visual audit rendered 205 fixtures covering workspace modules, launcher search, AI, settings and light/dark appearances. The focused revision audit rendered 28 search/notes fixtures at 420, 760, 800, 1040 and 1240 points. These are offscreen fixture renders, not recordings of a live user session.

## Changes

- Workspace modules receive their actual available content width. Opening or resizing the AI sidecar now changes the module's responsive layout instead of leaving it in the full-window layout.
- Notes filters use a menu that fits the sidebar; every filter stays accessible without horizontal scrolling. Outline and task controls use named, accessible icon buttons to leave room for the progress indicator.
- Search has a shorter placeholder at compact widths, quieter field styling, more bottom padding for its actions and an inspector threshold of 960 points. Smaller windows open details on demand.
- Launcher ranking retains only the best 24 results; universal ranking retains bounded results per source. Both use deterministic ties. Punctuation-only queries no longer match every unrelated launcher command through an empty token list.
- Search's Workspace menu includes image capture, text capture and capture history. These follow normal launcher command dispatch and source-application restoration.

## Quick captures

Use the existing shortcuts (by default Control–Option–Shift–C for an image and Control–Option–Shift–T for text), or the search window's Workspace menu. Drag a region once. Escape cancels.

The selector gets monitor geometry directly instead of enumerating all application windows first. Capture still resolves the selected target against fresh ScreenCaptureKit content. Text recognition uses local Vision fast recognition with an accurate retry if nothing is found. Clipboard delivery precedes saving and indexing; an archive failure reports that copying succeeded but saving failed.

Captured text is pinned in Context and persists across restarts. Images are stored in Screenshot History and pinned as references in Context. Right-click a Context item to **Copy AI reference** or **Add to AI Draft**. Images retain normal Screenshot History retention; a reference does not keep an image forever or automatically send pixels to a provider.

## AI access

`lima_data_search` finds saved Context, captured text, dictation and clipboard entries. `lima_data_read` reads stable `context:UUID`, `dictation:UUID` and `clipboard:UUID` references in chunks of at most 16,000 characters. Search returns up to 30 recent matches and signals more results; narrow the query when needed.

This uses the Workspace data access category. Search results and returned text are explicitly untrusted source data. File and note references remain references. `capture:UUID` routes to native screenshot metadata/image tools; image pixels still use the reviewed handoff. Private Mail, Messages and Browser references cannot be flattened through the generic saved-data tools.

Existing native tools continue to handle Notes, projects, scheduled tasks, Browser, Terminal, extensions and macOS data. Surface navigation does not itself grant content access. This change does not add a generic reader for every transient view's unsaved editor state.

## Validation

The focused UI/search/capture/access regression suite passed 71 tests, including persisted text/image references, private reference exclusions, Unicode pagination, large-catalog ranking parity and native text-field continuity. Builds and offscreen renders pass. Live screen capture latency on the user's displays and live provider use of the new tools still need an interactive run. The installed Lima application has not been replaced by these source changes.
