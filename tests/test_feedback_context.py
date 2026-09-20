#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod

CTX = load("build_feedback_context")
VAL = load("validate_feedback_evidence")


class FeedbackContextTests(unittest.TestCase):
    def make_vault(self, root: Path):
        vault = root / "vault"
        base = vault / "上课记录"
        for d in ["学生档案", "课后反馈", "课堂文字稿", "备课内容"]:
            (base / d).mkdir(parents=True, exist_ok=True)
        return vault

    def test_context_collects_profile_previous_and_next_sources(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            vault = self.make_vault(root)
            session = root / "2026-09-20_100000"
            session.mkdir()
            (session / "transcript.txt").write_text(
                "[00:01] hello\n[00:02] world\n[00:03] again\n"
            )
            base = vault / "上课记录"
            (base / "学生档案" / "David.md").write_text(
                "# David\n当前进度: rotation"
            )
            (base / "课后反馈" / "2026-09-13-David-feedback.md").write_text(
                "prev feedback"
            )
            (base / "课堂文字稿" / "2026-09-13 AP C Class-David.md").write_text(
                "prev transcript"
            )
            (base / "备课内容" / "2026-09-20 AP C Class-David.md").write_text(
                "---\nevent_start: 2026-09-20T10:00:00+08:00\n---\ncurrent"
            )
            (base / "备课内容" / "2026-09-27 AP C Class-David.md").write_text(
                "---\nevent_start: 2026-09-27T10:00:00+08:00\n---\nnext"
            )
            data = CTX.build(session, vault, "AP C", "David")
            self.assertTrue(data["sources"]["current_profile"].endswith("David.md"))
            self.assertIn(
                "2026-09-13-David-feedback.md",
                data["sources"]["previous_feedback"],
            )
            self.assertIn(
                "2026-09-13 AP C Class-David.md",
                data["sources"]["previous_transcript"],
            )
            self.assertIn(
                "2026-09-20 AP C Class-David.md",
                data["sources"]["current_prep"],
            )
            self.assertIn(
                "2026-09-27 AP C Class-David.md",
                data["sources"]["next_prep"],
            )

    def test_evidence_requires_current_lesson_refs_for_priority_issue(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            transcript = root / "transcript.txt"
            transcript.write_text(
                "[00:10] first\n[00:20] second\n[00:30] third\n"
            )
            context = root / "context.json"
            context.write_text(json.dumps({
                "student": "David",
                "sources": {
                    "current_transcript": str(transcript),
                    "current_profile": None,
                    "previous_feedback": None,
                    "previous_transcript": None,
                    "current_prep": None,
                    "next_prep": None,
                },
            }))
            evidence = root / "evidence.json"
            evidence.write_text(json.dumps({
                "schema_version": "2.2",
                "student": "David",
                "context_read": {"current_transcript": True},
                "current_progress_summary": "progress",
                "lesson_content": [{"claim": "topic", "transcript_refs": ["00:10"]}],
                "progress_evidence": [],
                "priority_issues": [{
                    "issue": "same old issue",
                    "status": "historical",
                    "profile_issue": "x",
                    "transcript_refs": [],
                }],
                "next_lesson_plan": [{
                    "plan": "check it",
                    "basis": ["current_progress"],
                }],
            }))
            errs = VAL.validate(context, evidence)
            self.assertTrue(any(
                "priority_issues[0] requires current-lesson transcript_refs" in e
                for e in errs
            ))

    def test_valid_evidence_passes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            transcript = root / "transcript.txt"
            profile = root / "David.md"
            prev = root / "prev.md"
            transcript.write_text(
                "[00:10] first\n[00:20] second\n[00:30] third\n"
            )
            profile.write_text("# David")
            prev.write_text("prev")
            context = root / "context.json"
            context.write_text(json.dumps({
                "student": "David",
                "sources": {
                    "current_transcript": str(transcript),
                    "current_profile": str(profile),
                    "previous_feedback": str(prev),
                    "previous_transcript": None,
                    "current_prep": None,
                    "next_prep": None,
                },
            }))
            evidence = root / "evidence.json"
            evidence.write_text(json.dumps({
                "schema_version": "2.2",
                "student": "David",
                "context_read": {
                    "current_transcript": True,
                    "current_profile": True,
                    "previous_feedback": True,
                },
                "current_progress_summary": "rotation is current progress",
                "lesson_content": [{
                    "claim": "rotation",
                    "transcript_refs": ["00:10"],
                }],
                "progress_evidence": [{
                    "claim": "student corrected sign",
                    "transcript_refs": ["00:20"],
                }],
                "priority_issues": [{
                    "issue": "sign convention",
                    "status": "historical",
                    "profile_issue": "sign convention",
                    "transcript_refs": ["00:30"],
                }],
                "next_lesson_plan": [{
                    "plan": "recheck sign convention then continue rotation",
                    "basis": ["current_progress", "priority_issue"],
                }],
            }))
            self.assertEqual(VAL.validate(context, evidence), [])

    def test_available_previous_context_must_be_marked_read(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            transcript = root / "transcript.txt"
            prev = root / "prev.md"
            transcript.write_text(
                "[00:10] first\n[00:20] second\n[00:30] third\n"
            )
            prev.write_text("prev")
            context = root / "context.json"
            context.write_text(json.dumps({
                "student": "D",
                "sources": {
                    "current_transcript": str(transcript),
                    "current_profile": None,
                    "previous_feedback": str(prev),
                    "previous_transcript": None,
                    "current_prep": None,
                    "next_prep": None,
                },
            }))
            evidence = root / "evidence.json"
            evidence.write_text(json.dumps({
                "schema_version": "2.2",
                "student": "D",
                "context_read": {"current_transcript": True},
                "current_progress_summary": "x",
                "lesson_content": [{
                    "claim": "x",
                    "transcript_refs": ["00:10"],
                }],
                "progress_evidence": [],
                "priority_issues": [],
                "next_lesson_plan": [{
                    "plan": "x",
                    "basis": ["current_progress"],
                }],
            }))
            self.assertTrue(
                any("previous_feedback" in e for e in VAL.validate(context, evidence))
            )


if __name__ == "__main__":
    unittest.main()
