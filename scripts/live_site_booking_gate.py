#!/usr/bin/env python3
"""Opt-in, human-attested acceptance gate for a real embedded-WebKit booking.

This validates an evidence bundle; it does not visit a site or submit a booking.
No fixture, CI job, or non-interactive process can mark the live gate passed.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
ORDER = ("fresh_read", "commit_review", "user_approval", "final_action", "confirmation_read")
REJECTED_HOSTS = {"localhost", "example.com", "example.org", "example.net"}
REJECTED_SUFFIXES = (".localhost", ".local", ".test", ".invalid", ".example",
                     ".example.com", ".example.org", ".example.net")


class GateError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def text(value: object, name: str, minimum: int = 1, maximum: int = 240) -> str:
    require(isinstance(value, str), f"{name} must be text")
    value = value.strip()
    require(minimum <= len(value) <= maximum, f"{name} must be {minimum}–{maximum} characters")
    return value


def moment(value: object, name: str) -> datetime:
    raw = text(value, name, 20, 40)
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise GateError(f"{name} must be an ISO 8601 timestamp") from exc
    require(parsed.tzinfo is not None, f"{name} must include a timezone")
    return parsed.astimezone(timezone.utc)


def public_host(value: object, name: str) -> str:
    raw = text(value, name, 12, 2048)
    url = urlsplit(raw)
    require(url.scheme == "https" and url.hostname is not None, f"{name} must be a public HTTPS URL")
    require(url.username is None and url.password is None, f"{name} must not contain credentials")
    try:
        port = url.port
    except ValueError as exc:
        raise GateError(f"{name} has an invalid HTTPS port") from exc
    require(port in (None, 443), f"{name} must use the standard HTTPS port")
    host = url.hostname.lower().rstrip(".")
    require(host not in REJECTED_HOSTS and not host.endswith(REJECTED_SUFFIXES),
            f"{name} cannot use a fixture, local, or reserved host")
    require("." in host and len(host) <= 253, f"{name} must have a public hostname")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        require(re.fullmatch(r"[a-z0-9.-]+", host) is not None, f"{name} has an invalid hostname")
    else:
        require(address.is_global, f"{name} cannot use a private or reserved IP")
    return host


def decimal(value: object, name: str) -> Decimal:
    require(not isinstance(value, bool), f"{name} must be a dollar amount")
    try:
        amount = Decimal(str(value))
    except InvalidOperation as exc:
        raise GateError(f"{name} must be a dollar amount") from exc
    require(amount.is_finite() and Decimal("0") <= amount <= Decimal("10000"),
            f"{name} must be a finite nonnegative dollar amount")
    require(amount.as_tuple().exponent >= -2, f"{name} must have no more than two decimal places")
    return amount


def artifact(record: dict, name: str, evidence_dir: Path) -> None:
    relative = text(record.get("artifact"), f"{name}.artifact", 1, 180)
    path = Path(relative)
    require(not path.is_absolute() and ".." not in path.parts and len(path.parts) <= 3,
            f"{name}.artifact must be a short relative path")
    candidate = evidence_dir / path
    resolved = candidate.resolve()
    require(resolved.is_relative_to(evidence_dir.resolve()) and resolved.is_file() and not candidate.is_symlink(),
            f"{name}.artifact must exist inside the evidence directory")
    require(0 < resolved.stat().st_size <= 5_000_000, f"{name}.artifact must be bounded")
    expected = text(record.get("sha256"), f"{name}.sha256", 64, 64).lower()
    require(re.fullmatch(r"[0-9a-f]{64}", expected) is not None,
            f"{name}.sha256 must be a SHA-256 digest")
    actual = hashlib.sha256(resolved.read_bytes()).hexdigest()
    require(actual == expected, f"{name}.artifact hash did not match")


def current_commit() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
    ).strip()


def source_is_clean() -> bool:
    """HEAD is not a build identity if edited or untracked source is present."""
    return not subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=ROOT, text=True, stderr=subprocess.DEVNULL
    ).strip()


def validate(bundle: object, evidence_dir: Path) -> dict:
    require(isinstance(bundle, dict), "Evidence must be a JSON object")
    require(bundle.get("schema_version") == 1, "Unsupported evidence schema")
    require(bundle.get("runtime") == "embedded-wkwebview", "Only Lima's embedded WKWebView is accepted")
    site_host = public_host(bundle.get("site_url"), "site_url")
    hosts = bundle.get("allowed_hosts")
    require(isinstance(hosts, list) and 1 <= len(hosts) <= 5, "allowed_hosts must have 1–5 hosts")
    clean_hosts = []
    for item in hosts:
        allowed_host = text(item, "allowed_host", 4, 253).lower().rstrip(".")
        require(re.fullmatch(r"[a-z0-9.-]+", allowed_host) is not None,
                "allowed_hosts must contain hostnames, not URLs or paths")
        clean_hosts.append(public_host(f"https://{allowed_host}", "allowed_host"))
    require(site_host in clean_hosts, "The site must be an allowed host")
    commit = text(bundle.get("git_commit"), "git_commit", 40, 40).lower()
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None and commit == current_commit(),
            "Evidence must match the current source commit")
    require(source_is_clean(), "The source tree must be clean so HEAD identifies the tested code")
    tab_id = text(bundle.get("tab_id"), "tab_id", 36, 36)
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", tab_id) is not None, "tab_id must be a UUID")
    require(bundle.get("account_is_user_authorized_test_account") is True,
            "A user-authorized real-site test account is required")
    constraints = bundle.get("constraints")
    require(isinstance(constraints, dict), "constraints are required")
    party = constraints.get("party_size")
    require(type(party) is int and 1 <= party <= 20, "party_size must be 1–20")
    date = text(constraints.get("date"), "constraints.date", 10, 10)
    try:
        datetime.strptime(date, "%Y-%m-%d")
    except ValueError as exc:
        raise GateError("constraints.date must be a calendar date") from exc
    earliest = text(constraints.get("earliest_time"), "constraints.earliest_time", 5, 5)
    latest = text(constraints.get("latest_time"), "constraints.latest_time", 5, 5)
    selected = text(constraints.get("selected_time"), "constraints.selected_time", 5, 5)
    for name, value in (("earliest_time", earliest), ("latest_time", latest), ("selected_time", selected)):
        try:
            datetime.strptime(value, "%H:%M")
        except ValueError as exc:
            raise GateError(f"constraints.{name} must be HH:MM") from exc
    require(earliest <= selected <= latest, "Selected time must be inside the approved range")
    max_fee = decimal(constraints.get("maximum_fee_usd"), "maximum_fee_usd")
    observed_fee = decimal(constraints.get("observed_fee_usd"), "observed_fee_usd")

    steps = bundle.get("steps")
    require(isinstance(steps, list) and [step.get("kind") for step in steps if isinstance(step, dict)] == list(ORDER)
            and len(steps) == len(ORDER), "Exactly five ordered live evidence steps are required")
    records = dict(zip(ORDER, steps))
    times = [moment(records[kind].get("at"), f"{kind}.at") for kind in ORDER]
    require(times == sorted(times) and len(set(times)) == len(times), "Evidence step times must increase")
    now = datetime.now(timezone.utc)
    require(now - times[0] <= timedelta(hours=48)
            and times[-1] <= now + timedelta(minutes=5),
            "Every live evidence step must be recent")
    require(times[3] - times[0] <= timedelta(minutes=15),
            "Final action must follow the fresh read within 15 minutes")
    require(times[4] - times[3] <= timedelta(minutes=5),
            "Confirmation must be read within 5 minutes of the final action")
    for kind in ("fresh_read", "final_action", "confirmation_read"):
        artifact(records[kind], kind, evidence_dir)
    for kind in ORDER:
        require(records[kind].get("tab_id") == tab_id, f"{kind} must use the same explicit Browser tab")
    for kind in ("fresh_read", "commit_review", "final_action", "confirmation_read"):
        require(public_host(records[kind].get("url"), f"{kind}.url") in clean_hosts,
                f"{kind} used a host outside the approved set")
    before = text(records["fresh_read"].get("page_identity"), "fresh_read.page_identity", 8, 200)
    for kind in ("commit_review", "user_approval", "final_action"):
        require(text(records[kind].get("page_identity"), f"{kind}.page_identity", 8, 200) == before,
                f"{kind} must reference the freshly reviewed page state")
    require(records["commit_review"]["url"] == records["fresh_read"]["url"]
            and records["final_action"]["url"] == records["fresh_read"]["url"],
            "Review and final action must use the fresh-read URL")
    after = text(records["confirmation_read"].get("page_identity"),
                 "confirmation_read.page_identity", 8, 200)
    require(before != after, "The confirmation must be a fresh, changed Browser page state")
    call_id = text(records["commit_review"].get("call_id"), "commit_review.call_id", 4, 160)
    require(records["user_approval"].get("call_id") == call_id
            and records["final_action"].get("call_id") == call_id,
            "Review, approval, and final action must reference the exact same call")
    require(records["user_approval"].get("decision") == "allow_once",
            "Final submission must have a one-call user approval")
    require(records["final_action"].get("performed") is True,
            "The final action must have been performed")
    require(text(records["commit_review"].get("target_label"),
                 "commit_review.target_label", 2, 160), "Commit target is required")
    if observed_fee > max_fee:
        fee = records["user_approval"].get("fee_exception")
        require(isinstance(fee, dict) and fee.get("approved_amount_usd") is not None
                and decimal(fee["approved_amount_usd"], "fee_exception.approved_amount_usd") >= observed_fee
                and fee.get("question_answer") == "approved",
                "An unexpected fee requires a structured user answer approving the exact amount")
    confirmation = records["confirmation_read"]
    require(confirmation.get("party_size") == party
            and confirmation.get("date") == date
            and confirmation.get("time") == selected,
            "Confirmation must match the approved party, date, and time")
    text(confirmation.get("confirmation_marker"), "confirmation_read.confirmation_marker", 8, 240)
    text(confirmation.get("confirmation_reference"), "confirmation_read.confirmation_reference", 4, 120)
    return {"site_host": site_host, "date": date, "selected_time": selected,
            "party_size": party, "observed_fee_usd": str(observed_fee), "commit": commit}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True,
                        help="Private JSON evidence bundle from a real embedded-WebKit run")
    parser.add_argument("--validate-only", action="store_true",
                        help="Check structure without human signoff; never passes the live gate")
    args = parser.parse_args()
    try:
        evidence = args.evidence.resolve(strict=True)
        require(evidence.is_file() and evidence.suffix == ".json", "Evidence must be a JSON file")
        evidence_bytes = evidence.read_bytes()
        bundle = json.loads(evidence_bytes.decode("utf-8"))
        summary = validate(bundle, evidence.parent)
    except (GateError, OSError, UnicodeDecodeError, json.JSONDecodeError,
            subprocess.CalledProcessError) as exc:
        print(f"LIVE BOOKING GATE BLOCKED: {exc}", file=sys.stderr)
        return 1
    print("Structurally valid live-site evidence record:")
    print(json.dumps(summary, sort_keys=True, indent=2))
    if args.validate_only:
        print("LIVE BOOKING GATE OPEN: manual inspection and attestation were not performed.")
        return 3
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("LIVE BOOKING GATE BLOCKED: interactive manual review is required.", file=sys.stderr)
        return 1
    print("Inspect the packaged Lima Browser, site account, approval UI, action trace,")
    print("and confirmation artifacts. Do not attest from fixture data or this JSON alone.")
    answer = input("Type LIVE BOOKING CONFIRMED only after that review: ")
    if answer != "LIVE BOOKING CONFIRMED":
        print("LIVE BOOKING GATE BLOCKED: no manual attestation.", file=sys.stderr)
        return 1
    try:
        require(evidence.read_bytes() == evidence_bytes,
                "Evidence changed during manual review")
        require(validate(bundle, evidence.parent) == summary,
                "Evidence or source state changed during manual review")
        receipt = evidence.with_suffix(".receipt.json")
        record = {
            "schema_version": 1, "status": "passed_after_manual_review",
            "attested_at": datetime.now(timezone.utc).isoformat(),
            "evidence_sha256": hashlib.sha256(evidence_bytes).hexdigest(),
            "summary": summary,
        }
        descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(record, output, sort_keys=True, indent=2)
            output.write("\n")
    except (GateError, OSError, subprocess.CalledProcessError) as exc:
        print(f"LIVE BOOKING GATE BLOCKED: {exc}", file=sys.stderr)
        return 1
    print(f"LIVE BOOKING GATE PASSED for the exact source commit above. Receipt: {receipt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
