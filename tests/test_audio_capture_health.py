#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "check_audio_capture.py"


class AudioCaptureHealthTests(unittest.TestCase):
    def run_check(self, audio: Path) -> tuple[int, dict]:
        report = audio.with_suffix(".json")
        result = subprocess.run(
            ["python3", str(SCRIPT), str(audio), "--output", str(report)],
            capture_output=True,
            text=True,
        )
        return result.returncode, json.loads(report.read_text(encoding="utf-8"))

    def make_stereo(self, path: Path, left_filter: str, right_filter: str) -> None:
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-y", "-v", "error",
                "-f", "lavfi", "-i", left_filter,
                "-f", "lavfi", "-i", right_filter,
                "-filter_complex", "[0:a][1:a]amerge=inputs=2",
                "-t", "2", "-c:a", "pcm_s16le", str(path),
            ],
            check=True,
        )

    def test_holds_recording_when_system_audio_channel_is_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "missing-system.wav"
            self.make_stereo(audio, "anullsrc=r=16000:cl=mono", "sine=frequency=440:r=16000")
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 1)
            self.assertEqual(report["status"], "system_audio_missing")

    def test_allows_recording_when_both_sources_have_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "healthy.wav"
            self.make_stereo(audio, "sine=frequency=330:r=16000", "sine=frequency=440:r=16000")
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "healthy")

    def test_keeps_legacy_mono_files_compatible(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "legacy.wav"
            subprocess.run(
                ["ffmpeg", "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i",
                 "sine=frequency=440:r=16000", "-t", "1", "-c:a", "pcm_s16le", str(audio)],
                check=True,
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "legacy_mixed_audio")


if __name__ == "__main__":
    unittest.main()
