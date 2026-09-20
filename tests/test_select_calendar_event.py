#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "scripts" / "select_calendar_event.py"
SPEC = importlib.util.spec_from_file_location("select_calendar_event", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SelectCalendarEventTests(unittest.TestCase):
    def test_selects_event_by_active_overlap(self):
        lines = [
            "CIE Class-Eden\t2026-09-20T09:00:00+08:00\t2026-09-20T10:00:00+08:00\t\n",
            "AP C Class-David\t2026-09-20T10:00:00+08:00\t2026-09-20T11:00:00+08:00\t\n",
        ]
        start = datetime.fromisoformat("2026-09-20T10:03:00+08:00")
        end = datetime.fromisoformat("2026-09-20T10:55:00+08:00")
        status, match, _ = MODULE.resolve_event(lines, "Class", start, end, 5400)
        self.assertEqual(status, "matched")
        self.assertEqual((match["system"], match["student"]), ("AP C", "David"))

    def test_missed_first_class_then_second_class_matches_second(self):
        lines = [
            "CIE Class-Eden\t2026-09-20T09:00:00+08:00\t2026-09-20T10:00:00+08:00\t\n",
            "AP C Class-David\t2026-09-20T10:00:00+08:00\t2026-09-20T11:00:00+08:00\t\n",
        ]
        start = datetime.fromisoformat("2026-09-20T10:01:00+08:00")
        end = datetime.fromisoformat("2026-09-20T10:58:00+08:00")
        status, match, _ = MODULE.resolve_event(lines, "Class", start, end, 5400)
        self.assertEqual(status, "matched")
        self.assertEqual(match["student"], "David")

    def test_ambiguous_overlap_is_not_auto_assigned(self):
        lines = [
            "CIE Class-Eden\t2026-09-20T09:00:00+08:00\t2026-09-20T10:00:00+08:00\t\n",
            "AP C Class-David\t2026-09-20T10:00:00+08:00\t2026-09-20T11:00:00+08:00\t\n",
        ]
        start = datetime.fromisoformat("2026-09-20T09:30:00+08:00")
        end = datetime.fromisoformat("2026-09-20T10:30:00+08:00")
        status, match, _ = MODULE.resolve_event(
            lines, "Class", start, end, 5400, ambiguity_margin=300
        )
        self.assertEqual(status, "ambiguous")
        self.assertIsNone(match)

    def test_legacy_row_is_still_supported(self):
        row = "CIE Class-Julien\t2026-09-20T14:00:00+08:00\tnotes\n"
        parsed = MODULE.parse_event_row(row, "Class")
        self.assertEqual(parsed[0:2], ("CIE", "Julien"))
        self.assertIsNone(parsed[3])

    def test_pretranscript_cli_defers_identity_lock(self):
        with tempfile.TemporaryDirectory() as d:
            session = Path(d) / "2026-09-20_090000"
            session.mkdir()
            start = MODULE.session_start(session)
            self.assertIsNone(MODULE.active_transcript_window(session))
            MODULE.write_candidates(
                session, "deferred_until_transcript", start, start, []
            )
            data = json.loads(
                (session / "calendar_candidates.json").read_text()
            )
            self.assertEqual(data["status"], "deferred_until_transcript")


if __name__ == "__main__":
    unittest.main()
