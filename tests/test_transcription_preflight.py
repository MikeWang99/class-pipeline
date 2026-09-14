#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "check_transcription_preflight.py"
SPEC = importlib.util.spec_from_file_location("transcription_preflight", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TranscriptionPreflightTests(unittest.TestCase):
    def test_repeated_hallucination_is_rejected(self):
        report = MODULE.assess_segments(["I don't know how to do this."] * 12)
        self.assertEqual(report["status"], "unusable")
        self.assertEqual(report["dominant_segment_ratio"], 1.0)
        self.assertEqual(report["repeated_segment_ratio"], 1.0)

    def test_varied_lesson_language_is_allowed(self):
        report = MODULE.assess_segments([
            "The wavelength is the distance between two neighbouring crests.",
            "Now use the wave speed equation and convert nanometres to metres.",
            "The image is virtual because the reflected rays do not really meet.",
        ])
        self.assertEqual(report["status"], "usable")

    def test_short_recordings_do_not_run_sampling_gate(self):
        self.assertEqual(MODULE.sample_offsets(599), [])


if __name__ == "__main__":
    unittest.main()
