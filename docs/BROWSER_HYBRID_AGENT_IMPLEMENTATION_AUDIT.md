# Hybrid Browser agent implementation audit

Status: **incomplete**. This compares the 45 sections of the supplied hybrid visual + semantic Browser proposal with the current development tree. "Present" means a bounded implementation exists, not that arbitrary live websites have been proven safe. "Partial" and "missing" are open work. The scheduler remains outside the agreed implementation slice.

| Section | Status | Finding |
| --- | --- | --- |
| 1. Five-layer architecture | Missing | Browser actions remain primarily in `BrowserWorkspaceModel` and `BrowserWorkspaceAITools`; no separate `WebTaskController`, `BrowserActionEngine`, or `PostActionVerifier`. |
| 2. Intent-level tools | Partial | Read/find/activate/set/select/toggle/submit, tabs, waits, screenshot and hit-test exist. `browser_observe`, `browser_scroll_to`, `browser_hover`, `browser_dialog_read`, and `browser_diagnostics` do not. |
| 3. Interaction graph | Partial | `BrowserTarget` has kind, state, actions, forms, options, dialogs and frames. The full typed relationship graph for grids, listboxes, tabpanels, menus and popovers is absent. |
| 4. Native virtual focus | Partial | `BrowserAIFocusState` and a target outline exist; no independent durable intent/focus model across the complete task. |
| 5. Virtual cursor | Partial | A prismatic pointer and focus/move/act/wait animation exist; hover, drag, double-click, typing and scrolling phases do not. |
| 6. Robust navigation, not evasion | Partial | Scrolling, focus, key dispatch, tabs and waits exist. No generic CAPTCHA/human-challenge detector and pause/resume flow. |
| 7. Semantic-first visual fallback | Partial | Semantic targets and screenshot-bound visual hits exist, but no general intent engine automatically selecting and recovering between methods. |
| 8. Visual hit testing | Present, bounded | `browser_hit_test` uses a fresh private screenshot and DOM hit; freshness and sensitive-target guards exist. |
| 9. Bounded coordinate action | Present, narrower | `browser_pointer_click` requires a fresh hit ID and exact-call review. Arbitrary coordinates and other pointer gestures are deliberately unavailable. |
| 10. Scroll-to-target | Partial | Bounded `browser_scroll` and `browser_scan` exist; target-directed `browser_scroll_to` does not. |
| 11. Hover | Missing | No Browser hover action or hover-triggered menu verification. |
| 12. Keyboard | Partial | Escape, arrows, Home/End and PageUp/PageDown are supported. Enter, Space, Tab and Shift-Tab are not exposed. |
| 13. First-class forms | Partial | `browser_form_read` groups fields and submit controls, but no complete form planner/completion and validation workflow. |
| 14. Live structured questions | Present, bounded | `request_user_input` suspends and resumes the same run in the sidecar. |
| 15. Free-form questions | Present, bounded | Free response and multiline entry exist in `AIUserQuestionView`. |
| 16. Browser-linked questions | Partial | A question can bind a Browser tab; per-target highlight/“Show on page” choices are absent. |
| 17. Sensitive-field handoff | Present, bounded | Protected fields are classified, model typing is blocked, and presence-only direct-site entry can resume the same run. Classification is heuristic. |
| 18. Payment handoff | Partial | Direct website entry, required-field check, cancellation and fresh-read requirement exist; the full payment-step summary and field-highlight experience do not. |
| 19. Lima-owned secure view | Partial | A native secure-handoff card lists fields; it does not display live per-field entered/waiting status or highlight each site field. |
| 20. Payment prompt | Partial | Current copy distinguishes entry from final authorization, but does not exactly implement all proposed merchant/order context and incomplete-field states. |
| 21. Separate final purchase confirmation | Partial | Exact-call Browser commit approval is separate from secure entry and binds page identity. No structured final-order dialog with merchant, line items, total, fulfillment and precise submit label. |
| 22. No payment values to model | Partial, security review open | Classified values are redacted and handoff response is presence-only. Arbitrary-site transformed/split echoes, unclassified fields and closed shadow roots are not proven safe. |
| 23. Screenshot redaction | Present, bounded | Private JPEGs mask protected regions and frames with pre/post checks. Arbitrary-site visual leakage and timing races remain unverified. |
| 24. DOM redaction | Present, bounded | Classified values, URL paths and tab titles are withheld or redacted in Browser tool output. Complete coverage of site-controlled echoes is not established. |
| 25. Autofill | Present, bounded | Classified filled state is a Boolean; values are not part of semantic field metadata. |
| 26. Checkout state machine | Missing | No `WebTransactionStage` or equivalent generic checkout stage transition model. |
| 27. Transaction progress UI | Missing | Tool-activity timeline exists, but no order/booking milestone progression. |
| 28. AI page interpretation strip | Missing | No compact fields-remaining / primary-action / validation status strip. |
| 29. Attention layer | Partial | Current target outline exists; differentiated read/consider/completed attention states do not. |
| 30. Action trail | Partial | Activity history exists below the Browser; no temporary numbered on-page markers. |
| 31. User takeover | Present, bounded | Real user events revoke targets, screenshots and results, requiring reread without permanent pause. |
| 32. Simultaneous control state | Partial | Toolbar control mode, pause/resume and activity indicators exist; the proposed collaborative transition UI does not. |
| 33. Action grouping | Missing | Activity is tool-level, not goal-level groups such as “Filling shipping address.” |
| 34. Goal-oriented macros | Missing | No generic `fillFormField`/`chooseOption`/`selectCalendarDate` strategy layer. |
| 35. Automatic recovery | Partial | Errors include recovery hints; no complete runtime recovery policy for stale, obscured, frame, menu, validation or new-tab cases. |
| 36. Interaction planner | Missing | No Browser interaction plan updated with page changes. |
| 37. Keep hidden reasoning private | Present in current UI | Current activity displays actions, not hidden chain-of-thought; a future planner must preserve this. |
| 38. Multi-tab operation | Partial | Tab IDs, activity state, background opening, suspension and pooling exist; task association and purpose are absent. |
| 39. Research-to-order flow | Partial | Research and Browser tools coexist, but no verified end-to-end generic research/cart/checkout engine. |
| 40. Scheduled tasks | Out of scope | The agreed secure-handoff slice explicitly excluded scheduler work; no shared scheduled transaction engine has been implemented. |
| 41. Transaction policy | Missing | Browser AI Control and exact-call approval exist, but no domain/merchant/maximum-total policy object or purchase-policy engine. |
| 42. Fresh final confirmation | Partial | Exact-call review rechecks page identity and visible terms; it does not parse and compare structured merchant/total/fulfillment before and after approval. |
| 43. Verify transaction success | Missing | Action outcomes distinguish dispatch and visible change, but no independent transaction receipt verifier returning confirmed/needs-review. |
| 44. Dedicated live UI | Partial | Embedded Browser, AI sidecar, secure question and target overlay exist; the proposed integrated checkout-progress experience is incomplete. |
| 45. Priority/QA program | Partial | Deterministic Browser, visual, handoff and booking-gate fixtures exist. The 20-item priority list and live-site acceptance are not complete. |

## Review fixes in this pass

- Cross-frame aggregation now withholds page-derived text whenever **any** frame on a multi-frame page has a filled classified protected field. This closes a main-frame-to-child-frame echo path as well as the existing child-to-parent path. The tradeoff is reduced semantic context until navigation; it does not prove arbitrary-site confidentiality.
- Exact-call commit review recognizes additional obvious final labels: buy, payment, donate, pledge, transfer and send money. This remains a heuristic, not a complete classifier.

## Verification and release boundary

The two reciprocal cross-frame tests, the secure-entry/final-submit fixture, same-run handoff fixture, visual-hit guard, commit-label fixture, and all 10 local Python booking-gate tests passed in focused runs. `git diff --check` passed. The full Swift suite, Release build, packaged-app/manual UI acceptance, broad arbitrary-site confidentiality review and authorized real-site booking gate were **not** completed in this audit. No real purchase or booking was made. Do not treat `post_action_verified` (which may mean a page change) as remote transaction confirmation.

The development worktree remains uncommitted. Do not close the embedded Browser or live-site gates from this audit alone.
