# Background context, extension management, and live dictation

## Background context

Context remains Lima's storage/reference layer for captures and AI tools. It is removed from the main launcher destination list, default and saved navigation sections, the layout editor's hidden-module list, and AI surface-opening choices. Existing content is preserved. The AI attachment menu exposes recent captures rather than requiring users to manage a Shelf. Browser references save in place instead of switching to a Context screen.

The sidebar has a smaller brand/header area and promotes Dictation to a first-class destination. Untouched version-4 default layouts migrate once; customized layouts keep their order and placement, except that Context is no longer a visible destination.

## Extension performance

Opening management no longer performs a full extension reload. Manifest metadata is read/decoded once on a background task with stale-result and cancellation checks. Approved contributions are resolved on the main actor using the existing manifest hash/capability and logical-removal rules.

The sorted installed-package projection is cached. Command/profile updates are coalesced before rebuilding it; typing a query only filters the cached data. Explicit Reload still invokes the full loader. The loader reuses manifest bytes for decoding and hashing, and registering an unchanged package no longer changes its timestamp, publishes a new record, or rewrites its registry.

A fixture scanned 100 manifests and verified that repeated unchanged registration left persisted bytes and timestamps identical. No production-library speed multiplier was measured.

## Live dictation

Engine choices are available directly in Dictation (in the settings popover at compact widths):

- Apple Live: on-device recognition with revisable partial text and committed speech.
- Whisper: on-device transcription of short rolling windows. TinyDiarize detects turn changes, not voice identity; labels are numbered turns instead of alternating alleged Speaker 1 / Speaker 2 identities.
- OpenAI API: rolling 10-second WAV windows are uploaded while recording. Stop drains remaining windows. Successful live output is committed once, confirmed audio is removed, and failed pending audio is preserved for retry. Cancellation and changed run tokens reject late network results.

The API uses the OpenAI key already configured in Lima, as authorized in this conversation. No new key was created or copied. Local engines never fall back to the API silently.

### People and speaker labels

For local dictation, add participant names and choose who is speaking before their turn. Names are saved with the conversation. Apple recognition flushes its pending phrase at a chosen boundary without resetting its committed-hypothesis anchor; Whisper associates each recorded window with the name selected when recording it. These are user assignments, not automatic voice identification.

The API's Detect speakers option requests `diarized_json`. It can represent more than two voices with timestamps. Labels are explicitly scoped to each audio window: an A in one window is not asserted to be the A in another. Stable, automatic person identity throughout an entire meeting is not implemented. Local turn numbers also restart between recognition windows.

OpenAI's [file transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text) and [transcription reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create) document the diarization request. The currently documented specialized model is `gpt-4o-transcribe-diarize`, which OpenAI marks deprecated with shutdown scheduled for February 26, 2027. The implementation will need a supported speaker-labeling replacement before that date. Existing ordinary file transcription retains the app's configured implementation model.

Previously committed live text is not rewritten by optional cleanup. Speaker-tagged API text retains its returned speaker structure; the existing transcript AI actions can prepare summaries or edited copies explicitly. Optional automatic cleanup is retained only for uncommitted, non-speaker cloud batches.

## Validation and limits

83 focused regression tests passed, covering queued live delivery, stop/drain, pending-window retry, late results after cancellation, three or more speaker labels, manual boundary deduplication, old conversation decoding, package metadata, unchanged registration, navigation and search. Twelve light/dark renders cover Dictation and Extensions at 420, 800 and 1240 points.

Builds and fixture tests pass. Live microphone accuracy, real group recordings, network latency, and account access to the speaker model have not been exercised. This is a local build; the installed Lima application has not been replaced.
