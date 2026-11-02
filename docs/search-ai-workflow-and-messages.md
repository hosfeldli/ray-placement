# Search, task progress, Terminal, and Messages

## Search → a fresh running chat

Ask Lima (the sparkles action) in Search now selects a request composer. Return (or the send arrow) creates a new chat, submits the typed request, opens the Assistant workspace, and shows the same running chat. A sparkles action can also carry an already-typed search into Ask mode. Escape goes back to Search and retains the unsent prompt. While a request is running, starting another chat is refused without cancelling or changing the active request. Provider/setup failures remain visible in the newly opened chat.

## A saved, actionable checklist

`update_task_plan` is a context-owned tool for multi-step work. Plans live on their assistant message and survive history persistence and recovery. They use stable IDs, compare-and-swap revisions, one current step, completion evidence, and explicit explanations when scope or order changes. Steps must be started before completion; completed tasks cannot silently become pending. Child agents cannot change the parent's checklist.

The provider receives plan progress in tool results and saved transcript context. If it stops with a pending plan, the execution loop asks it to continue up to twice; blocked steps stop that continuation. A provider that still stops early leaves a visible unfinished checklist and warning, never automatically checked boxes. Completion evidence is the assistant's reported verification, not an independent guarantee of external success.

The checklist appears in Chat, the mission panel, and the Terminal work log. The work log stays associated with the terminal session's originating conversation, displays recent real activity, and never writes decorative output into the PTY.

## Motion and layout

The Browser/Chat/Terminal selector moves its selected background smoothly. Search intent, mission expansion, and terminal-log expansion use short transitions. Workspace motion follows destination changes, rather than every token or terminal byte. Reduce Motion disables these animations. Search keeps its corrected native window sizing and matching input borders.

## Messages

Unnamed chats now use participant addresses instead of indistinguishable “Conversation” labels. The read adapter decodes the common little-endian typedstream root NSString envelope as well as secure keyed archives. It checks exact byte lengths (including two- and four-byte lengths), UTF-8, size bounds, and the closing marker; it never loads archived classes for typedstream or guesses printable runs. Unknown envelopes remain unavailable.

Search includes rich-body candidates, decodes before matching, and preserves selected-conversation/date scopes. A search reads at most 1,000 candidates and returns the requested bounded count. The conversation transcript uses chronological bubbles, initially positions the selected search result or latest message, and offers a Latest button without jumping away from history on each refresh.

Messages tests use an isolated SQLite fixture. No personal Messages history is read and no live messages are sent during validation. Full Disk Access and exact-send review retain their existing roles.

Format reference: [python-typedstream's low-level integer and string reader](https://github.com/dgelessus/python-typedstream/blob/master/src/typedstream/stream.py). The implementation is a bounded extractor for common Messages envelopes, not a full typedstream deserializer.

## Validation

All 819 discovered Swift tests passed in the complete bounded test run. Six focused checks also passed after strengthening the existing-custom-install migration fixture. Visual review completed 36 Search renders and 40 checklist, terminal work-log, and Messages transcript renders in light/dark themes, narrow/wide layouts, and normal/enlarged text. Reviewed renders show no clipped composer hints or checklist rows.

No live provider requests or real Messages sends were used. These changes are local and have not been published as a new release.
