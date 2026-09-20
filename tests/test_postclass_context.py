#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]

def load(name):
    path = ROOT / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod

REF = load("derive_lesson_reference")
CTX = load("validate_postclass_context")
FB = load("validate_feedback_output")

class PostclassContextTests(unittest.TestCase):
    def test_effective_reference_uses_first_meaningful_transcript_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "2026-09-20_090000"
            session.mkdir()
            (session / "transcript.txt").write_text(
                "[00:05] (door opens)\n[59:55] Today we start projectile motion\n[60:10] student answer\n",
                encoding="utf-8",
            )
            ref = REF.derive(session)
            self.assertEqual(ref.strftime("%Y-%m-%d %H:%M:%S"), "2026-09-20 09:59:55")

    def valid_context(self, root: Path):
        transcript = root / "transcript.txt"; transcript.write_text("x", encoding="utf-8")
        profile = root / "profile.md"; profile.write_text("x", encoding="utf-8")
        return {
            "schema_version":"2.2",
            "identity":{"student":"Eden","system":"AP","status":"confirmed","match_basis":"final"},
            "sources":{
                "transcript":{"path":str(transcript),"read_complete":True},
                "current_profile":{"path":str(profile),"read_complete":True},
                "previous_feedback":{"path":"","read_complete":False}
            },
            "before_lesson":{"current_progress":"Kinematics","active_issues":[]},
            "this_lesson":{
                "actual_content":["graphs"],
                "successes":[{"claim":"reads slope","evidence":[{"timestamp":"10:00","observation":"correct"}]}],
                "difficulties":[],"homework_assigned":[]
            },
            "issue_assessment":[{
                "issue":"graph sign","previous_status":"not_tracked","current_status":"new",
                "this_lesson_evidence":[{"timestamp":"20:00","observation":"confused sign"}],
                "include_in_parent_feedback":True,"reason":"appeared twice"
            }],
            "next_lesson":{"planned_topics":["reference frame"],"issue_checks":["graph sign"],"basis":["current progress","lesson evidence"]},
            "unresolved":[]
        }

    def test_context_requires_this_lesson_evidence_for_parent_issue(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); data=self.valid_context(root)
            data["issue_assessment"][0]["this_lesson_evidence"]=[]
            p=root/"context.json"; p.write_text(json.dumps(data),encoding="utf-8")
            self.assertTrue(any("without this-lesson evidence" in e for e in CTX.validate(p,"Eden")))

    def test_valid_context_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); p=root/"context.json"; p.write_text(json.dumps(self.valid_context(root)),encoding="utf-8")
            self.assertEqual(CTX.validate(p,"Eden"),[])

    def test_feedback_rejects_paragraph_final_period_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/"feedback.md"
            p.write_text("本节课反馈：\n\n「1. 本节课内容」\n内容。中间可以有句号，但末尾不要。\n\n「2. 本节课进步」\n进步\n\n「3. 孩子当前待加强方向」\n- 问题\n\n「4. 后续计划」\n课后练习安排：\n- 练习\n下节课安排：\n- 继续图像\n",encoding="utf-8")
            self.assertTrue(FB.validate(p))
            p.write_text(p.read_text(encoding="utf-8").replace("但末尾不要。","但末尾不要"),encoding="utf-8")
            self.assertEqual(FB.validate(p),[])

if __name__ == "__main__": unittest.main()
