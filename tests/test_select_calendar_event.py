#!/usr/bin/env python3
import importlib.util
import unittest
from datetime import datetime
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "scripts" / "select_calendar_event.py"
SPEC = importlib.util.spec_from_file_location("select_calendar_event", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

class SelectCalendarEventTests(unittest.TestCase):
    def test_selects_nearest_event_case_insensitively(self):
        lines=["CIE class-Eden\t2026-08-24T10:30:00+08:00\t\n","CIE class-Julien\t2026-08-24T14:30:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-08-24T10:28:58+08:00")
        self.assertEqual(MODULE.select_event(lines,"Class",ref,3600),(62,"CIE","Eden"))

    def test_accepts_unicode_dash(self):
        lines=["AP M Class—Sujal\t2026-08-24T16:30:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-08-24T16:28:44+08:00")
        self.assertEqual(MODULE.select_event(lines,"Class",ref,3600),(76,"AP M","Sujal"))

    def test_accepts_new_swift_row_with_end_and_identifier(self):
        lines=["AP Class-Eden\t2026-09-20T10:00:00+08:00\t2026-09-20T11:00:00+08:00\tevent-1\tnote\n"]
        ref=datetime.fromisoformat("2026-09-20T10:02:00+08:00")
        self.assertEqual(MODULE.select_event(lines,"Class",ref,1800,mode="final"),(120,"AP","Eden"))

    def test_accepts_applescript_calendar_prefix(self):
        lines=["mike@gmail.com\tCIE class-Julien\t2026-09-12T10:30:00+08:00\tmissing value\n"]
        ref=datetime.fromisoformat("2026-09-12T10:28:54+08:00")
        self.assertEqual(MODULE.select_event(lines,"Class",ref,3600),(66,"CIE","Julien"))

    def test_rejects_distant_event(self):
        lines=["CIE Class-Eden\t2026-08-24T10:30:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-08-24T18:30:00+08:00")
        self.assertIsNone(MODULE.select_event(lines,"Class",ref,3600))

    def test_rejects_nearby_ambiguous_legacy_events(self):
        lines=["CIE class-Eden\t2026-09-20T09:00:00+08:00\t\n","AP2 class-Johnny\t2026-09-20T10:30:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-09-20T09:43:39+08:00")
        self.assertIsNone(MODULE.select_event(lines,"Class",ref,3600))

    def test_provisional_rejects_two_packed_lessons_even_when_first_is_closest(self):
        lines=["CIE Class-First\t2026-09-20T09:00:00+08:00\t\n","AP Class-Second\t2026-09-20T10:00:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-09-20T09:00:10+08:00")
        self.assertIsNone(MODULE.select_event(lines,"Class",ref,7200,mode="provisional"))

    def test_final_reference_selects_second_lesson_after_cancelled_first(self):
        lines=["CIE Class-First\t2026-09-20T09:00:00+08:00\t\n","AP Class-Second\t2026-09-20T10:00:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-09-20T09:59:55+08:00")
        self.assertEqual(MODULE.select_event(lines,"Class",ref,2700,mode="final"),(5,"AP","Second"))

    def test_rejects_nearby_ambiguous_final_events(self):
        lines=["CIE Class-A\t2026-09-20T10:00:00+08:00\t\n","AP Class-B\t2026-09-20T10:05:00+08:00\t\n"]
        ref=datetime.fromisoformat("2026-09-20T10:02:30+08:00")
        self.assertIsNone(MODULE.select_event(lines,"Class",ref,2700,mode="final"))

if __name__=="__main__": unittest.main()
