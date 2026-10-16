# Search and AI streaming comparative profile — October 14, 2026

This is a **fixture-backed microprofile**, not an Instruments trace or a claim about full UI frame pacing. Both versions ran on the same Mac in the same test mode. The baseline was the detached immutable `v3.14.24` tag (`980f1f7`); the candidate was the uncommitted redesign based on that commit. The opt-in Swift Testing probes were copied unchanged into the baseline worktree.

Run with `LIMA_TEST_MODE=1 LIMA_RUN_PERFORMANCE_PROFILE=1 swift test --filter comparativeSearchTypingProfile`, `--filter comparativeSearchPopulatedCatalogProfile`, or `--filter comparativeAIStreamingProfile`. Build products are separate for each worktree. Raw outputs are in `/tmp/lima-search-profile-baseline.log`, `/tmp/lima-search-profile-current-after-actor.log`, `/tmp/lima-search-populated-baseline.log`, `/tmp/lima-search-populated-current-after-actor.log`, `/tmp/lima-ai-stream-profile-baseline-2.log`, and `/tmp/lima-ai-stream-profile-current-2.log`.

| Search typing metric | v3.14.24 | Candidate |
| --- | ---: | ---: |
| First-key MainActor setter, median | 4.259 ms | 0.059 ms |
| First-key MainActor setter, p95 | 4.606 ms | 0.095 ms |
| Warm-key MainActor setter, median | 4.301 ms | 0.039 ms |
| Warm-key MainActor setter, p95 | 5.100 ms | 0.069 ms |
| First visible `notes` result, median | 5.556 ms | 40.993 ms |
| First visible `notes` result, p95 | 5.919 ms | 44.685 ms |

The candidate shifts ranking off the MainActor and makes keystroke work much smaller. The 35 ms debounce makes the result appear later by design; this profile does not decide whether that latency feels acceptable under real input methods.

| 500-entry synthetic clipboard catalog | v3.14.24 | Candidate |
| --- | ---: | ---: |
| First-key MainActor setter, median | 24.948 ms | 0.068 ms |
| First-key MainActor setter, p95 | 25.337 ms | 0.073 ms |
| First matching result, median | 26.336 ms | 53.321 ms |
| First matching result, p95 | 26.695 ms | 54.267 ms |

This test uses only synthetic clipboard entries and disables app scanning. The candidate removes long keystroke blocking under source volume, but its first result is later. The candidate numbers shown are after moving document normalization into the Search actor; that change improved the isolation boundary, not this fixture’s result latency. It is not a full index-volume or perceived-latency test.

| 20 KB AI fixture stream metric | v3.14.24 | Candidate |
| --- | ---: | ---: |
| Send MainActor preparation, median | 2.622 ms | 2.545 ms |
| Send MainActor preparation, p95 | 2.686 ms | 2.598 ms |
| Completion latency, median | 50.987 ms | 24.978 ms |
| Completion latency, p95 | 52.275 ms | 25.820 ms |
| Conversation-store publications, median | 10 | 4 |
| View-model publications, median | 13 | 13 |

The AI probe emits 2,000 fixture deltas of 10 bytes each, then one terminal event, and measures 12 runs after two warmups. It does not include network latency, Markdown layout, native tool execution, or real window rendering. Live Codex CLI tool behavior has a separate opt-in integration test.

## Follow-up Search scheduling probe — October 15, 2026

The candidate now starts the first query after an empty composer after one task yield; only subsequent edits keep the 35 ms coalescing delay. The same opt-in Search probes reran with `LIMA_TEST_MODE=1` and synthetic fixtures (`/tmp/lima-search-profile-70.log`, exit 0):

| Search metric | Earlier candidate | Adaptive first query | v3.14.24 |
| --- | ---: | ---: | ---: |
| First-key setter, median | 0.059 ms | 0.112 ms | 4.259 ms |
| First visible `notes` result, median | 40.993 ms | 22.877 ms | 5.556 ms |
| 500-entry first-key setter, median | 0.068 ms | 0.120 ms | 24.948 ms |
| 500-entry first result, median | 53.321 ms | 40.267 ms | 26.336 ms |

This reduces first-result latency without returning to synchronous keystroke ranking, but first results still trail the old synchronous path. These are microprofiles, not user-visible frame-pacing or memory measurements.

**Still required for complete-scope readiness:** profile Search with a realistic multi-source catalog, Workspace module switching and Notes editing, window resizing and visual frame pacing, plus the remaining AI run-authority and presentation-isolation architecture gates. These microprofiles alone are not release clearance.

## October 16 limited-release candidate probe

The current candidate reran the three opt-in synthetic probes separately (`/tmp/lima-final-profiles-isolated-20261016.log`, all three passed):

| Isolated candidate metric | Result |
| --- | ---: |
| Search first-key MainActor median | 0.058 ms |
| Search first visible `notes` result median | 5.440 ms |
| 500-entry first-key MainActor median | 0.075 ms |
| 500-entry first result median | 17.237 ms |
| AI send MainActor preparation median | 3.299 ms |
| AI completion median | 26.341 ms |
| Conversation-store publications median | 4 |

The same three probes run concurrently (`/tmp/lima-final-comparative-profile-20261016.log`) reported slower first-result medians of 29.139 ms for `notes` and 46.991 ms for the 500-entry catalog. This run-to-run/load sensitivity is material. The immutable v3.14.24 baseline was not rerun on October 16 under identical conditions, and no real-window frame-pacing or memory trace was collected. The limited release must not claim that every new feature is performant or regression-free.
