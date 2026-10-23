# Opt-in live-site booking acceptance gate

This is a **separate, manual, real-site acceptance gate** for Lima's embedded `WKWebView` Browser. It does not schedule or execute a booking. Local WebKit fixtures and the Workbench `--live` CLI smoke test cannot close it.

## Preconditions

- Test a clean, committed source tree and the packaged Lima app built from that exact commit. Keep the private evidence directory **outside** the repository.
- The user must explicitly authorize the real service, account, date/time, party size, maximum fee or deposit, allowed hosts, and whether a real final submission may be made. Do not infer permission from this checklist.
- Use a user-authorized real-site test account and the embedded Browser only. Do not use Browser Bridge, an extension, native messaging, a site-specific adapter, or a deterministic/local fixture.
- If the safe account, site, or limits are unavailable, leave the gate **OPEN**. Never make a real reservation merely to satisfy a test.

## Evidence sequence

Capture a private, redacted evidence bundle for one explicit Browser tab and one exact provider call ID:

1. **fresh_read** — current URL, page identity, relevant availability and constraints, and a bounded artifact from a fresh Browser read.
2. **commit_review** — exact call ID and visible final target label; inspect visible fee, deposit, cancellation, and other material terms.
3. **user_approval** — one-call `allow_once` decision for that same call. If observed fees exceed the approved limit, include the exact approved amount and the structured question's `approved` answer. A denial or unavailable user stops the run.
4. **final_action** — that same call ID and a bounded artifact showing the action actually dispatched. This alone is **not** booking success.
5. **confirmation_read** — a new Browser read on an approved host, with a changed page identity, matching party/date/time, a visible confirmation marker, and an actual confirmation reference. Include a bounded redacted artifact.

The evidence JSON uses `schema_version: 1`, `runtime: "embedded-wkwebview"`, `site_url`, `allowed_hosts` (hostnames only), `git_commit`, `tab_id`, `account_is_user_authorized_test_account: true`, `constraints`, and the five ordered `steps` above. Constraints contain `party_size`, `date` (YYYY-MM-DD), `earliest_time`, `latest_time`, `selected_time` (24-hour HH:MM), `maximum_fee_usd`, and `observed_fee_usd`. Every step has `kind`, `tab_id`, the current `page_identity`, and a timezone-aware ISO 8601 `at`. The fresh read, commit review, and final action must carry the same page identity; the confirmation read must show a changed one. The read, review, and final-action steps have `url`, with the first three using the exact same approved URL. The final action must occur within 15 minutes of the fresh read, and confirmation must be read within five minutes of the final action. `confirmation_read` additionally has `party_size`, `date`, `time`, `confirmation_marker`, and `confirmation_reference`. `commit_review` has `call_id` and `target_label`; `user_approval` has `call_id`, `decision`, and, when required, `fee_exception: { "approved_amount_usd": "...", "question_answer": "approved" }`; `final_action` has `call_id` and `performed: true`.

The fresh read, final action, and confirmation read each have a relative `artifact` path and its `sha256`. Keep artifacts below 5 MB each, in the evidence directory, with passwords, OTPs, payment data, cookies, headers, and personal details removed. Record the actual Browser/tool output; do not manufacture or substitute fixture output.

## Validate and attest

```sh
python3 scripts/live_site_booking_gate.py --evidence /private/path/live-booking.json --validate-only
python3 scripts/live_site_booking_gate.py --evidence /private/path/live-booking.json
```

The first command checks structure but intentionally exits with the gate still open. The second requires an interactive terminal and a human who has inspected the **packaged app**, the real account/site, the approval UI, action trace, and confirmation artifacts. It rechecks source and evidence after that review and writes a private, exclusive `live-booking.receipt.json` beside the evidence, bound to its SHA-256 and source commit. Existing receipts are not overwritten.

A syntactically valid JSON bundle is not proof of a booking. If the final page lacks an actual matching confirmation, or any step is uncertain, do not attest. The gate is still **OPEN** until a safe real-site run and manual inspection produce a receipt for the release candidate.
