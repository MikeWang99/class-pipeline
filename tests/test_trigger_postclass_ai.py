#!/usr/bin/env python3

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "trigger_postclass_ai.sh"


class TriggerPostclassAITests(unittest.TestCase):
    def test_dry_run_accepts_pending_session(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-ai-trigger-") as tmp:
            session = Path(tmp) / "2026-08-28_120000"
            session.mkdir()
            material = Path(tmp) / "materials.md"
            material.write_text("status: 待AI生成\n", encoding="utf-8")
            env = os.environ.copy()
            env["TRIGGER_POSTCLASS_AI_DRY_RUN"] = "1"

            result = subprocess.run(
                ["bash", str(SCRIPT), str(session), str(material)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertIn("would trigger Codex", result.stdout)
            self.assertFalse((session / ".ai_trigger.pid").exists())

    def test_completed_session_does_not_trigger(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-ai-trigger-") as tmp:
            session = Path(tmp) / "2026-08-28_120000"
            session.mkdir()
            (session / "ai_completed.txt").write_text("complete\n", encoding="utf-8")
            material = Path(tmp) / "materials.md"
            material.write_text("status: 已完成\n", encoding="utf-8")
            env = os.environ.copy()
            env["TRIGGER_POSTCLASS_AI_DRY_RUN"] = "1"

            result = subprocess.run(
                ["bash", str(SCRIPT), str(session), str(material)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout, "")
            self.assertFalse((session / ".ai_trigger.pid").exists())

    def test_completed_session_cleans_all_native_audio_channels(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-ai-trigger-") as tmp:
            session = Path(tmp) / "2026-08-28_120000"
            session.mkdir()
            (session / "ai_completed.txt").write_text("complete\n", encoding="utf-8")
            material = Path(tmp) / "materials.md"
            material.write_text("status: 已完成\n", encoding="utf-8")
            for name in ("audio.wav", "system_audio.caf", "microphone_audio.caf"):
                (session / name).write_bytes(b"source")

            result = subprocess.run(
                ["bash", str(SCRIPT), str(session), str(material)],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout, "")
            self.assertFalse((session / "audio.wav").exists())
            self.assertFalse((session / "system_audio.caf").exists())
            self.assertFalse((session / "microphone_audio.caf").exists())
            self.assertTrue((session / "audio_deleted.txt").exists())


if __name__ == "__main__":
    unittest.main()
