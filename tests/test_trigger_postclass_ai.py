#!/usr/bin/env python3
import json, os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).parents[1]; SCRIPT=ROOT/"scripts"/"trigger_postclass_ai.sh"

def make_context(root,student="Eden"):
    transcript=root/"transcript.txt"; transcript.write_text("x",encoding="utf-8")
    profile=root/"profile.md"; profile.write_text("before",encoding="utf-8")
    return profile,{
      "schema_version":"2.2","identity":{"student":student,"system":"AP","status":"confirmed","match_basis":"final"},
      "sources":{"transcript":{"path":str(transcript),"read_complete":True},"current_profile":{"path":str(profile),"read_complete":True}},
      "before_lesson":{"current_progress":"Kinematics","active_issues":[]},
      "this_lesson":{"actual_content":["graphs"],"successes":[],"difficulties":[],"homework_assigned":[]},
      "issue_assessment":[],"next_lesson":{"planned_topics":["reference frame"],"issue_checks":[],"basis":["current progress"]},"unresolved":[]}

def feedback_text():
    return "本节课反馈：\n\n「1. 本节课内容」\n内容\n\n「2. 本节课进步」\n进步\n\n「3. 孩子当前待加强方向」\n- 本节暂无需要写入家长反馈的新问题\n\n「4. 后续计划」\n课后练习安排：\n- 本节未明确布置新的课后练习\n下节课安排：\n- 继续图像\n"

class TriggerTests(unittest.TestCase):
    def material(self,path,student="Eden"):
        path.write_text(f"student: {student}\nstatus: 待AI生成\ncalendar_match_status: matched_final\nsource_profile: {path.parent/'profile.md'}\n",encoding="utf-8")
    def test_dry_run_accepts_final_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            session=Path(tmp)/"2026-08-28_120000"; session.mkdir(); material=Path(tmp)/"materials.md"; self.material(material)
            env=os.environ.copy(); env["TRIGGER_POSTCLASS_AI_DRY_RUN"]="1"
            r=subprocess.run(["bash",str(SCRIPT),str(session),str(material)],check=True,env=env,capture_output=True,text=True)
            self.assertIn("would trigger Codex",r.stdout)
    def test_unmatched_does_not_trigger_without_final_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            session=Path(tmp)/"2026-08-28_120000"; session.mkdir(); (session/"transcript.txt").write_text("[00:00] hi",encoding="utf-8")
            material=Path(tmp)/"materials.md"; material.write_text("status: 待AI识别学生\ncalendar_match_status: unmatched\n",encoding="utf-8")
            env=os.environ.copy(); env["CALENDAR_QUERY_SCRIPT"]="/usr/bin/false"; env["CODEX_BIN"]="/usr/bin/false"
            subprocess.run(["bash",str(SCRIPT),str(session),str(material)],check=True,env=env,capture_output=True,text=True)
            self.assertFalse((session/".ai_trigger.pid").exists())
    def test_fully_validated_completed_session_cleans_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); session=root/"2026-08-28_120000"; session.mkdir(); material=root/"materials.md"; self.material(material)
            profile,ctx=make_context(root); context=session/"postclass-context.json"; context.write_text(json.dumps(ctx),encoding="utf-8")
            feedback=root/"feedback.md"; feedback.write_text(feedback_text(),encoding="utf-8"); review=root/"review.md"; review.write_text("review",encoding="utf-8")
            (session/"ai_completed.txt").write_text(f"formal_feedback: {feedback}\nstudent_profile: {profile}\nteacher_review: {review}\npostclass_context: {context}\n",encoding="utf-8")
            for name in ("audio.wav","system_audio.caf","microphone_audio.caf"):(session/name).write_bytes(b"source")
            subprocess.run(["bash",str(SCRIPT),str(session),str(material)],check=True,capture_output=True,text=True)
            self.assertFalse((session/"audio.wav").exists()); self.assertTrue((session/"audio_deleted.txt").exists())
    def test_incomplete_marker_does_not_count_as_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); session=root/"2026-08-28_120000"; session.mkdir(); material=root/"materials.md"; self.material(material)
            review=root/"review.md"; review.write_text("review",encoding="utf-8"); (session/"ai_completed.txt").write_text(f"teacher_review: {review}\n",encoding="utf-8")
            env=os.environ.copy(); env["TRIGGER_POSTCLASS_AI_DRY_RUN"]="1"
            r=subprocess.run(["bash",str(SCRIPT),str(session),str(material)],check=True,env=env,capture_output=True,text=True)
            self.assertIn("would trigger Codex",r.stdout)
if __name__=="__main__": unittest.main()
