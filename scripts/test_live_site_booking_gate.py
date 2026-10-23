#!/usr/bin/env python3
"""Deterministic negative tests; these never attest or book a live site."""
import contextlib
import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("live_site_booking_gate.py")
SPEC = importlib.util.spec_from_file_location("live_site_booking_gate", SCRIPT)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class LiveBookingGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        clean_source = patch.object(gate, "source_is_clean", return_value=True)
        clean_source.start()
        self.addCleanup(clean_source.stop)
        now = datetime.now(timezone.utc) - timedelta(minutes=10)
        tab = "123e4567-e89b-12d3-a456-426614174000"
        self.bundle = {
            "schema_version": 1,
            "runtime": "embedded-wkwebview",
            "site_url": "https://www.invalid-qa-restaurant.org/reservations",
            "allowed_hosts": ["www.invalid-qa-restaurant.org"],
            "git_commit": gate.current_commit(),
            "tab_id": tab,
            "account_is_user_authorized_test_account": True,
            "constraints": {
                "party_size": 2, "date": "2026-10-23",
                "earliest_time": "18:45", "latest_time": "19:30",
                "selected_time": "19:15", "maximum_fee_usd": "25.00",
                "observed_fee_usd": "0.00"
            },
            "steps": []
        }
        for index, kind in enumerate(gate.ORDER):
            step = {
                "kind": kind, "tab_id": tab,
                "at": (now + timedelta(seconds=index)).isoformat()
            }
            step["page_identity"] = "document-after" if kind == "confirmation_read" else "document-before"
            if kind in ("fresh_read", "commit_review", "final_action", "confirmation_read"):
                step["url"] = self.bundle["site_url"]
            if kind in ("fresh_read", "final_action", "confirmation_read"):
                filename = f"{kind}.txt"
                data = f"synthetic {kind} for validator test".encode()
                (self.directory / filename).write_bytes(data)
                step["artifact"] = filename
                step["sha256"] = hashlib.sha256(data).hexdigest()
            if kind == "commit_review":
                step.update(call_id="call-123", target_label="Confirm booking")
            if kind == "user_approval":
                step.update(call_id="call-123", decision="allow_once")
            if kind == "final_action":
                step.update(call_id="call-123", performed=True)
            if kind == "confirmation_read":
                step.update(party_size=2, date="2026-10-23", time="19:15",
                            confirmation_marker="Reservation confirmed",
                            confirmation_reference="QA-1234")
            self.bundle["steps"].append(step)

    def test_fixture_host_cannot_validate(self):
        self.bundle["site_url"] = "https://example.com/reservations"
        self.bundle["allowed_hosts"] = ["example.com"]
        with self.assertRaises(gate.GateError):
            gate.validate(self.bundle, self.directory)

    def test_dirty_source_cannot_validate(self):
        with patch.object(gate, "source_is_clean", return_value=False):
            with self.assertRaises(gate.GateError):
                gate.validate(self.bundle, self.directory)

    def test_malformed_port_and_reserved_subdomains_cannot_validate(self):
        for url in ("https://www.example.com/booking", "https://shop.example.org/booking",
                    "https://booking.example.net/booking", "https://real.org:abc/booking"):
            self.bundle["site_url"] = url
            with self.assertRaises(gate.GateError):
                gate.validate(self.bundle, self.directory)

    def test_changed_call_id_cannot_validate(self):
        self.bundle["steps"][2]["call_id"] = "different-call"
        with self.assertRaises(gate.GateError):
            gate.validate(self.bundle, self.directory)

    def test_changed_review_page_or_action_host_cannot_validate(self):
        self.bundle["steps"][1]["page_identity"] = "document-changed"
        with self.assertRaises(gate.GateError):
            gate.validate(self.bundle, self.directory)
        self.bundle["steps"][1]["page_identity"] = "document-before"
        self.bundle["steps"][3]["url"] = "https://other.real-site.org/booking"
        with self.assertRaises(gate.GateError):
            gate.validate(self.bundle, self.directory)

    def test_stale_read_or_delayed_confirmation_cannot_validate(self):
        old = datetime.now(timezone.utc) - timedelta(hours=49)
        self.bundle["steps"][0]["at"] = old.isoformat()
        with self.assertRaisesRegex(gate.GateError, "recent"):
            gate.validate(self.bundle, self.directory)
        self.bundle["steps"][0]["at"] = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        self.bundle["steps"][4]["at"] = (datetime.now(timezone.utc) - timedelta(minutes=4)).isoformat()
        with self.assertRaisesRegex(gate.GateError, "within 5 minutes"):
            gate.validate(self.bundle, self.directory)

    def test_final_action_must_follow_fresh_read_within_15_minutes(self):
        self.bundle["steps"][0]["at"] = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat()
        self.bundle["steps"][3]["at"] = (datetime.now(timezone.utc) - timedelta(minutes=4)).isoformat()
        self.bundle["steps"][4]["at"] = (datetime.now(timezone.utc) - timedelta(minutes=3)).isoformat()
        with self.assertRaisesRegex(gate.GateError, "within 15 minutes"):
            gate.validate(self.bundle, self.directory)

    def test_confirmation_must_match_approved_constraints(self):
        self.bundle["steps"][4]["time"] = "19:45"
        with self.assertRaises(gate.GateError):
            gate.validate(self.bundle, self.directory)

    def test_unexpected_fee_needs_exact_user_answer(self):
        self.bundle["constraints"]["observed_fee_usd"] = "50.00"
        with self.assertRaises(gate.GateError):
            gate.validate(self.bundle, self.directory)
        self.bundle["steps"][2]["fee_exception"] = {
            "approved_amount_usd": "50.00", "question_answer": "approved"
        }
        gate.validate(self.bundle, self.directory)

    def test_synthetic_record_never_passes_noninteractive_gate(self):
        evidence = self.directory / "evidence.json"
        evidence.write_text(json.dumps(self.bundle), encoding="utf-8")
        with patch.object(sys, "argv", [str(SCRIPT), "--evidence", str(evidence),
                                        "--validate-only"]):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(), 3)
        with patch.object(sys, "argv", [str(SCRIPT), "--evidence", str(evidence)]):
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main(), 1)
        self.assertFalse(evidence.with_suffix(".receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
