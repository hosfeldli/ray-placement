#!/usr/bin/env python3
"""Run every Swift Testing case in bounded processes.

Swift Testing starts top-level tests concurrently even when SwiftPM's default
--no-parallel mode is selected. Running the entire Lima catalog in one process
can overload WebKit and PTY fixtures. Discover the catalog, run small disjoint
batches, and verify that every discovered case actually started exactly once.
"""

from __future__ import annotations

from collections import Counter
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = ROOT / ".build"
TEST_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_]*Tests(?:\.[A-Za-z_][A-Za-z0-9_]*)*[./]([A-Za-z_][A-Za-z0-9_]*)\(\)$")
STARTED = re.compile(r"\bTest ([A-Za-z_][A-Za-z0-9_]*)\(\) started\.")
SWIFT_TEST = ["swift", "test", "--disable-sandbox", "--scratch-path", str(SCRATCH)]
# Hosted SwiftUI/AppKit fixtures can deadlock teardown with WebKit/AppKit
# peers. The OCR/Search fixture shares a SQLite index with screenshot-history
# tests, so keep its database writes out of their concurrent batch.
ISOLATED_TESTS = {
    "completedAnswerMountsInHostedChatWithoutScrollGesture",
    "completedLongMarkdownAnswerShowsItsTailWithoutScrollGesture",
    "embeddedBrowserSelectedTabMountsItsOwnPageOnRepeatedSwitches",
    # This hosted navigation fixture uses process-local Browser task policy;
    # unrelated AI runs in a mixed batch can temporarily activate a site grant.
    "embeddedBrowserToolsReportLoadedAndDeferredPostconditions",
    # Hosted WebKit page/new-tab fixtures can abort native teardown when mixed
    # with Search and AI cases; each still runs and is counted on its own.
    "embeddedBrowserWaitForNewTabReturnsTheOpenedTabIdentity",
    "embeddedBrowserWebKitReadsLinksShadowControlsAndRejectsStaleTargets",
    "browserAskForActionsRequiresNativeApproval",
    # Visual review must retain its exact capture; the process-wide screenshot
    # store has an eight-capture cap that concurrent WebKit fixtures can evict.
    "browserVisualHitRequiresCaptureAndExactClickReview",
    "browserVisualShadowHitDispatchesToChildAndPrefersSemanticHost",
    # WebKit secure-handoff fixtures pass independently but can deadlock when
    # mixed with hosted Search/AppKit tests in the same concurrent process.
    "secureBrowserHandoffResumesSameRunWithoutReturningFieldValues",
    "secureBrowserHandoffRejectsSameHostRouteAndCancelStopsRun",
    "passwordHandoffResumesAfterSameHostNavigationWithoutClaimingSignIn",
    "screenshotOCRTextAppearsAsIndividualCentralSearchResult",
    # This Search fixture passes alone but can lose its expected result when
    # several hosted launcher queries share a mixed Swift Testing process.
    "screenshotStudioIsAnExplicitSearchAction",
    # This launcher fixture passes alone but can race other hosted Search
    # fixtures that mutate the process-wide search catalog in a mixed batch.
    "searchPreviewNeverExecutesUntilExplicitAction",
    # AI view-model fixtures can stall the Swift Testing helper when initialized
    # together after hosted WebKit batches; keep each in a bounded process.
    "embeddedNoteContentsReachOpenAIAndClaudeWithoutAPath",
    "emptyProviderCompletionIsTerminalAndComposerReady",
    "enabledNotesToolsRemainVisibleForEveryPrompt",
    "enabledToolsRemainVisibleRegardlessOfPromptWording",
    "endingPendingApprovalClearsPauseWithoutRunningTool",
}


def descendant_pids(root_pid: int) -> list[int]:
    listing = subprocess.check_output(["ps", "-Ao", "pid=,ppid="], text=True)
    children: dict[int, list[int]] = {}
    for line in listing.splitlines():
        pid, parent = (int(value) for value in line.split())
        children.setdefault(parent, []).append(pid)
    found: list[int] = []
    pending = [root_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            found.append(child)
            pending.append(child)
    return found


def run(command: list[str], timeout: int, *, separate_stderr: bool = False) -> tuple[int, str]:
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE if separate_stderr else subprocess.STDOUT,
        text=True,
        errors="replace",
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # SwiftPM's testing helper can have its own process group. Capture the
        # complete child tree before killing SwiftPM so no orphan keeps the
        # output pipe open or interferes with the next batch.
        children = descendant_pids(process.pid)
        for pid in reversed(children):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
        return 124, output + f"\nCommand exceeded {timeout} seconds: {' '.join(command)}\n"
    return process.returncode, output + ((_ or "") if process.returncode else "")


def main() -> int:
    try:
        batch_size = int(os.environ.get("LIMA_SWIFT_TEST_BATCH_SIZE", "16"))
    except ValueError:
        print("LIMA_SWIFT_TEST_BATCH_SIZE must be an integer.", file=sys.stderr)
        return 2
    if not 1 <= batch_size <= 64:
        print("LIMA_SWIFT_TEST_BATCH_SIZE must be between 1 and 64.", file=sys.stderr)
        return 2

    list_command = ["swift", "test", "list", "--disable-sandbox", "--scratch-path", str(SCRATCH)]
    code, output = run(list_command, timeout=600, separate_stderr=True)
    if code:
        print(output, end="")
        return code

    names: list[str] = []
    for line in output.splitlines():
        match = TEST_ID.fullmatch(line)
        if not match:
            print(f"Unexpected Swift test catalog line: {line!r}", file=sys.stderr)
            return 2
        names.append(match.group(1))
    if not names or len(names) != len(set(names)):
        print("Swift test catalog is empty or has duplicate function names.", file=sys.stderr)
        return 2

    groups: list[list[str]] = []
    pending: list[str] = []
    for name in names:
        if name in ISOLATED_TESTS:
            if pending:
                groups.append(pending)
                pending = []
            groups.append([name])
        else:
            pending.append(name)
            if len(pending) == batch_size:
                groups.append(pending)
                pending = []
    if pending:
        groups.append(pending)

    print(f"Discovered {len(names)} Swift tests in {len(groups)} bounded groups.", flush=True)
    continue_after_failure = os.environ.get("LIMA_SWIFT_TEST_CONTINUE_AFTER_FAILURE") == "1"
    failed_batches: list[tuple[int, int]] = []
    completed = 0
    for index, expected in enumerate(groups, start=1):
        pattern = "|".join(re.escape(name) for name in expected)
        print(f"Batch {index}/{len(groups)}: {len(expected)} tests ({', '.join(expected)})", flush=True)
        code, output = run(SWIFT_TEST + ["--skip-build", "--filter", pattern], timeout=180)
        print(output, end="", flush=True)
        actual = STARTED.findall(output)
        if Counter(actual) != Counter(expected):
            print(
                f"Batch selection mismatch: expected {expected!r}, observed {actual!r}",
                file=sys.stderr,
                flush=True,
            )
            return 2
        if code:
            print(f"Swift test batch {index} exited with status {code}.", file=sys.stderr, flush=True)
            if not continue_after_failure:
                return code
            failed_batches.append((index, code))
        completed += len(expected)

    if failed_batches:
        print(f"All {completed} discovered Swift tests started exactly once; failed batches: {failed_batches}.",
              file=sys.stderr, flush=True)
        return 1
    print(f"All {completed} discovered Swift tests started exactly once and passed.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
