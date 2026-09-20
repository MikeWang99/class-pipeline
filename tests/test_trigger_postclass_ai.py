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

    def test_unmatched_material_does_not_trigger_without_unique_identity(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-ai-trigger-") as tmp:
            session = Path(tmp) / "2026-08-28_120000"
            session.mkdir()
            material = Path(tmp) / "materials.md"
            material.write_text(
                "status: 待AI识别学生\ncalendar_match_status: unmatched\n",
                encoding="utf-8",
            )
            fake_codex = Path(tmp) / "fake-codex.sh"
            fake_codex.write_text(
                "#!/bin/bash\n"
                f"printf '%s\\n' 'unexpected' > {tmp}/triggered\n",
                encoding="utf-8",
            )
            fake_codex.chmod(0o755)
            env = os.environ.copy()
            env["CODEX_BIN"] = str(fake_codex)
            env["CALENDAR_QUERY_SCRIPT"] = "/usr/bin/false"

            result = subprocess.run(
                ["bash", str(SCRIPT), str(session), str(material)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout, "")
            self.assertFalse((Path(tmp) / "triggered").exists())

    def test_completed_session_does_not_trigger(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-ai-trigger-") as tmp:
            session = Path(tmp) / "2026-08-28_120000"
            session.mkdir()
            review = Path(tmp) / "teacher-review.md"
            review.write_text("review\n", encoding="utf-8")
            (session / "ai_completed.txt").write_text(
                f"teacher_review: {review}\n", encoding="utf-8"
            )
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
            review = Path(tmp) / "teacher-review.md"
            review.write_text("review\n", encoding="utf-8")
            (session / "ai_completed.txt").write_text(
                f"teacher_review: {review}\n", encoding="utf-8"
            )
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

    def test_worker_accepts_marker_feedback_path_without_material_metadata(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-ai-trigger-") as tmp:
            session = Path(tmp) / "2026-08-28_120000"
            session.mkdir()
            material = Path(tmp) / "materials.md"
            material.write_text("status: 待AI生成\n", encoding="utf-8")
            feedback = Path(tmp) / "feedback.md"
            fake_codex = Path(tmp) / "fake-codex.sh"
            fake_codex.write_text(
                "#!/bin/bash\n"
                f"printf '%s\\n' 'status: 已完成' > {material}\n"
                f"printf '%s\\n' 'feedback' > {feedback}\n"
                f"printf '%s\\n' 'teacher review' > {tmp}/teacher-review.md\n"
                f"printf '%s\\n' 'formal_feedback: {feedback}' > {session / 'ai_completed.txt'}\n"
                f"printf '%s\\n' 'teacher_review: {tmp}/teacher-review.md' >> {session / 'ai_completed.txt'}\n",
                encoding="utf-8",
            )
            fake_codex.chmod(0o755)
            for name in ("audio.wav", "system_audio.caf", "microphone_audio.caf"):
                (session / name).write_bytes(b"source")

            env = os.environ.copy()
            env["CODEX_BIN"] = str(fake_codex)
            result = subprocess.run(
                ["bash", str(SCRIPT), "--worker", str(session), str(material)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout, "")
            self.assertFalse((session / "audio.wav").exists())
            self.assertTrue((session / "audio_deleted.txt").exists())


if __name__ == "__main__":
    unittest.main()
