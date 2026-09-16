#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "check_audio_capture.py"


class AudioCaptureHealthTests(unittest.TestCase):
    def run_check(self, audio: Path, system_only: bool = False) -> tuple[int, dict]:
        report = audio.with_suffix(".json")
        extra = ["--system-only"] if system_only else []
        result = subprocess.run(
            ["python3", str(SCRIPT), str(audio), *extra, "--output", str(report)],
            capture_output=True,
            text=True,
        )
        return result.returncode, json.loads(report.read_text(encoding="utf-8"))

    def make_stereo(self, path: Path, left_filter: str, right_filter: str, duration: float = 2) -> None:
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-y", "-v", "error",
                "-f", "lavfi", "-i", left_filter,
                "-f", "lavfi", "-i", right_filter,
                "-filter_complex", "[0:a][1:a]amerge=inputs=2",
                "-t", str(duration), "-c:a", "pcm_s16le", str(path),
            ],
            check=True,
        )

    def test_system_audio_missing_is_degraded_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "missing-system.wav"
            self.make_stereo(
                audio,
                "anullsrc=r=16000:cl=mono",
                "sine=frequency=440:r=16000",
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "system_audio_missing")
            self.assertEqual(report["action"], "transcribe_degraded")
            self.assertEqual(report["completeness"], "degraded")

    def test_microphone_missing_is_degraded_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "missing-mic.wav"
            self.make_stereo(
                audio,
                "sine=frequency=330:r=16000",
                "anullsrc=r=16000:cl=mono",
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "microphone_audio_missing")
            self.assertEqual(report["action"], "transcribe_degraded")

    def test_allows_recording_when_both_sources_have_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "healthy.wav"
            self.make_stereo(
                audio,
                "sine=frequency=330:r=16000",
                "sine=frequency=440:r=16000",
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "healthy")
            self.assertTrue(report["system_signal_present"])
            self.assertTrue(report["microphone_signal_present"])

    def test_rejects_only_when_both_native_sources_are_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "silent-stereo.wav"
            self.make_stereo(
                audio,
                "anullsrc=r=16000:cl=mono",
                "anullsrc=r=16000:cl=mono",
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 1)
            self.assertEqual(report["status"], "no_capturable_audio")

    def test_keeps_legacy_mono_files_compatible(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "legacy.wav"
            subprocess.run(
                [
                    "ffmpeg", "-nostdin", "-y", "-v", "error",
                    "-f", "lavfi", "-i", "sine=frequency=440:r=16000",
                    "-t", "1", "-c:a", "pcm_s16le", str(audio),
                ],
                check=True,
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "legacy_mixed_audio")

    def test_rejects_silent_legacy_mono_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "silent.wav"
            subprocess.run(
                [
                    "ffmpeg", "-nostdin", "-y", "-v", "error",
                    "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", "1", "-c:a", "pcm_s16le", str(audio),
                ],
                check=True,
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 1)
            self.assertEqual(report["status"], "no_capturable_audio")

    def test_peak_detection_does_not_misclassify_sparse_audio_as_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sparse.wav"
            # 0.15 s tone followed by long silence: whole-file mean can be very
            # low, but a capture signal clearly existed.
            sparse = "aevalsrc=if(lt(t\\,0.15)\\,0.8*sin(2*PI*440*t)\\,0):s=16000"
            self.make_stereo(
                audio,
                sparse,
                "sine=frequency=220:r=16000",
                duration=8,
            )
            rc, report = self.run_check(audio)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "healthy")
            self.assertGreater(report["system_peak_db"], -48.0)

    def test_writes_per_source_health_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "healthy.wav"
            self.make_stereo(
                audio,
                "sine=frequency=330:r=16000",
                "sine=frequency=440:r=16000",
            )
            self.run_check(audio)
            self.assertTrue((Path(tmp) / "system_audio_health.json").is_file())
            self.assertTrue((Path(tmp) / "microphone_audio_health.json").is_file())

    def test_system_only_mode_checks_the_first_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "system.caf"
            self.make_stereo(
                audio,
                "sine=frequency=330:r=16000",
                "anullsrc=r=16000:cl=mono",
            )
            rc, report = self.run_check(audio, system_only=True)
            self.assertEqual(rc, 0)
            self.assertEqual(report["status"], "healthy")


if __name__ == "__main__":
    unittest.main()
