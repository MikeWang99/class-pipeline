#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "transcribe_audio.py"
SPEC = importlib.util.spec_from_file_location("transcribe_audio", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TranscriptionFallbackTests(unittest.TestCase):
    def test_stereo_zero_segment_retry_checks_each_source(self):
        plan = MODULE.retry_plan(2)
        self.assertEqual(
            plan,
            [
                (0, "system_audio", "system_channel_relaxed"),
                (1, "microphone", "microphone_channel_relaxed"),
            ],
        )

    def test_mono_zero_segment_retry_uses_relaxed_mix(self):
        self.assertEqual(MODULE.retry_plan(1), [(None, None, "mono_relaxed")])

    def test_channel_conversion_does_not_mix_other_source(self):
        self.assertIn("c0=c0", MODULE.conversion_filter(2, 0))
        self.assertIn("c0=c1", MODULE.conversion_filter(2, 1))

    def test_primary_stereo_conversion_blends_both_sources(self):
        value = MODULE.conversion_filter(2)
        self.assertIn("c0=0.707*c0+0.707*c1", value)

    def make_stereo_audio(self, path: Path) -> None:
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-y", "-v", "error",
                "-f", "lavfi", "-i", "sine=frequency=330:r=16000",
                "-f", "lavfi", "-i", "sine=frequency=440:r=16000",
                "-filter_complex", "[0:a][1:a]amerge=inputs=2",
                "-t", "1", "-c:a", "pcm_s16le", str(path),
            ],
            check=True,
        )

    def write_fake_whisper(self, path: Path, always_empty: bool = False) -> None:
        body = """#!/usr/bin/env python3
import json
import sys
args = sys.argv[1:]
outbase = args[args.index("-of") + 1]
threshold = args[args.index("-nth") + 1]
if ALWAYS_EMPTY or threshold == "0.60":
    transcription = []
else:
    transcription = [{
        "timestamps": {"from": "00:00:00,000", "to": "00:00:00,800"},
        "text": "Recovered speech",
    }]
with open(outbase + ".json", "w", encoding="utf-8") as f:
    json.dump({"transcription": transcription}, f)
"""
        path.write_text(
            body.replace("ALWAYS_EMPTY", "True" if always_empty else "False"),
            encoding="utf-8",
        )
        path.chmod(0o755)

    def test_end_to_end_zero_segment_first_pass_recovers_per_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            audio = tmp / "stereo.wav"
            outdir = tmp / "out"
            fake = tmp / "fake-whisper"
            model = tmp / "model.bin"
            model.write_bytes(b"x")
            self.make_stereo_audio(audio)
            self.write_fake_whisper(fake)

            env = os.environ.copy()
            env["WHISPER_CLI"] = str(fake)
            env["WHISPER_MODEL"] = str(model)
            result = subprocess.run(
                ["python3", str(SCRIPT), str(audio), str(outdir)],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads((outdir / "transcription_meta.json").read_text())
            self.assertTrue(meta["fallback_used"])
            self.assertEqual(meta["status"], "ok")
            self.assertIn("system_channel_relaxed", meta["attempts"])
            self.assertIn("microphone_channel_relaxed", meta["attempts"])
            transcript = (outdir / "transcript.txt").read_text()
            self.assertIn("[system_audio]", transcript)
            self.assertIn("[microphone]", transcript)

    def test_end_to_end_empty_after_all_retries_is_explicit_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            audio = tmp / "stereo.wav"
            outdir = tmp / "out"
            fake = tmp / "fake-whisper"
            model = tmp / "model.bin"
            model.write_bytes(b"x")
            self.make_stereo_audio(audio)
            self.write_fake_whisper(fake, always_empty=True)

            env = os.environ.copy()
            env["WHISPER_CLI"] = str(fake)
            env["WHISPER_MODEL"] = str(model)
            result = subprocess.run(
                ["python3", str(SCRIPT), str(audio), str(outdir)],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            meta = json.loads((outdir / "transcription_meta.json").read_text())
            self.assertEqual(meta["status"], "no_speech_after_retries")
            self.assertEqual(meta["segment_count"], 0)


if __name__ == "__main__":
    unittest.main()
