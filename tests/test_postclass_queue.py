#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "postclass_generate.sh"


class PostclassQueueTests(unittest.TestCase):
    def make_vault(self, root: Path) -> Path:
        vault = root / "vault"
        for name in ("学生档案", "课后反馈", "课堂文字稿"):
            (vault / "上课记录" / name).mkdir(parents=True, exist_ok=True)
        return vault

    def test_unmatched_transcript_is_queued_as_valid_utf8(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-test-") as tmp:
            root = Path(tmp)
            session = root / "1999-01-01_120000"
            vault = self.make_vault(root)
            session.mkdir()
            transcript = "\n".join(
                f"[{index:02d}:00] 中英文课堂文字稿 Internal Energy"
                for index in range(240)
            )
            (session / "transcript.txt").write_text(transcript, encoding="utf-8")

            env = os.environ.copy()
            env["CALENDAR_QUERY_SCRIPT"] = "/usr/bin/false"
            subprocess.run(
                ["bash", str(SCRIPT), str(session), str(vault)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            materials = list(
                (vault / "上课记录" / "课后反馈草稿").glob("*.md")
            )
            self.assertEqual(len(materials), 1)
            text = materials[0].read_text(encoding="utf-8")
            self.assertIn("status: 待人工确认录音", text)
            self.assertIn("calendar_match_status: unmatched", text)

    def test_degraded_capture_blocks_ai_but_keeps_recovery_transcript(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-test-") as tmp:
            root = Path(tmp)
            session = root / "2026-09-16_120000"
            vault = self.make_vault(root)
            session.mkdir()
            (session / "transcript.txt").write_text(
                "\n".join([
                    "[00:01 - 00:03] We are discussing pressure and volume.",
                    "[00:04 - 00:07] The area under the PV curve is work.",
                    "[00:08 - 00:11] Now compare isobaric and isochoric processes.",
                    "[00:12 - 00:15] The student explains the graph correctly.",
                ]),
                encoding="utf-8",
            )
            (session / "audio_health.json").write_text(
                json.dumps({
                    "status": "system_audio_missing",
                    "action": "transcribe_degraded",
                }),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "bash", str(SCRIPT), str(session), str(vault),
                    "AP Physics 2", "Eden",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            materials = (
                vault / "上课记录" / "课后反馈草稿"
                / "2026-09-16-Eden-feedback-materials.md"
            )
            text = materials.read_text(encoding="utf-8")
            self.assertIn("status: 待人工确认录音", text)
            self.assertIn(
                "transcript_quality: audio_capture_degraded_system_audio_missing",
                text,
            )
            self.assertIn("audio_capture_action: transcribe_degraded", text)
            self.assertIn("不得生成正式家长反馈", text)

    def test_previous_feedback_uses_latest_date_not_file_mtime(self):
        with tempfile.TemporaryDirectory(prefix="physicsclass-test-") as tmp:
            root = Path(tmp)
            session = root / "2026-08-28_120000"
            vault = self.make_vault(root)
            session.mkdir()
            (session / "transcript.txt").write_text(
                "\n".join([
                    "[00:01] 完整文字稿 one",
                    "[00:02] 完整文字稿 two",
                    "[00:03] 完整文字稿 three",
                ]),
                encoding="utf-8",
            )
            (vault / "上课记录" / "学生档案" / "Julien.md").write_text(
                "# Julien", encoding="utf-8"
            )
            feedback_dir = vault / "上课记录" / "课后反馈"
            old = feedback_dir / "2026-08-07-Julien-feedback.md"
            recent = feedback_dir / "2026-08-24-Julien-feedback.md"
            old.write_text("旧反馈", encoding="utf-8")
            recent.write_text("最近反馈", encoding="utf-8")
            os.utime(
                old,
                (recent.stat().st_mtime + 60, recent.stat().st_mtime + 60),
            )

            subprocess.run(
                [
                    "bash", str(SCRIPT), str(session), str(vault),
                    "CIE", "Julien",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            materials = (
                vault / "上课记录" / "课后反馈草稿"
                / "2026-08-28-Julien-feedback-materials.md"
            )
            text = materials.read_text(encoding="utf-8")
            self.assertIn(f"source_previous_feedback: {recent}", text)
            self.assertIn("最近反馈", text)
            self.assertNotIn("\n旧反馈\n", text)


if __name__ == "__main__":
    unittest.main()
