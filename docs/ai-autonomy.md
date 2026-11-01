# AI Browser and scheduled tasks

The AI Browser control is shared between Chat and Browser. It contains Browser access, navigation method, and the independence policy for the current or next run.

- **Ask for Actions** reviews navigation and interactions.
- **Approved Sites** allows routine nonpayment actions on the exact origins authorized for the task.
- **Independent** follows links across websites and permits routine nonpayment actions and canvas controls without repeated site or action prompts. Payments, protected fields, and user takeover keep their existing enforcement.

Adaptive navigation can use semantic controls and screenshots. Safe partial semantic results are available when a page exceeds the returned text or target budget, provided the privacy scan and frame accounting completed. Incomplete privacy scans still withhold page content.

Native visual clicks support left or right buttons and single or double clicks. `browser_game_key` clicks a canvas point and sends one bounded game key, including arrows and WASD. It releases the key on completion, cancellation, loss of foreground, or revoked authority. Each action needs a recent screenshot delivered to the current run. Independent mode allows unrelated DOM updates while acting on a currently exposed canvas, so a live score display does not invalidate every input. Navigation, human input, scrolling, mask changes, and noncanvas target changes still require a fresh observation. Dispatch is not proof that a game action succeeded.

## Scheduled work

Use Chat's clock button, or ask Lima to schedule the task. A saved task includes its originating conversation, instructions, absolute start time, IANA timezone, latest allowed start, and Browser approval choice. The list shows pending work, active runs, results, cancellations, and missed start windows.

Tasks run through the existing visible chat and tool-review pipeline. Lima must be running, the Mac must be awake, and the chat must be idle with no unfinished draft or attachments. Busy tasks are deferred only within their allowed start window. The scheduler does not install an operating-system wake service or launch Lima while it is closed.

A task can authorize Approved Sites or Independent nonpayment Browser work. Browser access and current tool permissions still apply; required approvals pause the run. Saving a task does not imply a reservation was made. A finished AI run also does not imply a confirmed reservation: inspect the conversation for the verified website confirmation.

The scheduler persists its claim before starting inference. A task interrupted by a restart requires attention and is never automatically replayed, since a remote booking may already have completed. Cancelling a task does not undo external actions.

## Workspace surfaces

`lima_surfaces` lists implemented workspace surfaces and their native content tools. `lima_surface_open` presents a surface and reports actual visibility. Opening a surface does not authorize reading its private data or bypass its native tool permissions.

## Validation

The focused tests cover durable scheduling, duplicate prevention, expiry, crash recovery, conversation isolation, draft preservation, a due task starting exactly once, independent Browser authority, payment/protected boundaries, guaranteed game-key release, and screenshot-cache fairness. Browser integration tests cover safe partial reads, incomplete privacy scans, masking, frame lifecycle, forms, modal controls, and navigation recovery.

To render the new UI with isolated fixture data:

```
LIMA_TEST_MODE=1 .build/debug/RayPlacement --visual-audit /tmp/lima-autonomy-preview --autonomy-only
```

These previews perform no live inference or booking.
