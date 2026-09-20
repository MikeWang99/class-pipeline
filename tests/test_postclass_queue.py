#!/usr/bin/env python3
import os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).parents[1]; SCRIPT=ROOT/"scripts"/"postclass_generate.sh"

class PostclassQueueTests(unittest.TestCase):
    def make_vault(self,root):
        vault=root/"vault"
        for name in ("学生档案","课后反馈","课堂文字稿","备课内容"):(vault/"上课记录"/name).mkdir(parents=True,exist_ok=True)
        return vault
    def confirmed_env(self):
        env=os.environ.copy(); env["POSTCLASS_IDENTITY_CONFIRMED"]="1"; env["CALENDAR_QUERY_SCRIPT"]="/usr/bin/false"; return env
    def test_unmatched_transcript_is_queued(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); session=root/"1999-01-01_120000"; session.mkdir(); vault=self.make_vault(root)
            (session/"transcript.txt").write_text("\n".join(f"[{i:02d}:00] lesson Internal Energy" for i in range(4)),encoding="utf-8")
            env=os.environ.copy(); env["CALENDAR_QUERY_SCRIPT"]="/usr/bin/false"
            subprocess.run(["bash",str(SCRIPT),str(session),str(vault)],check=True,env=env,capture_output=True,text=True)
            text=next((vault/"上课记录"/"课后反馈草稿").glob("*.md")).read_text(encoding="utf-8")
            self.assertIn("calendar_match_status: unmatched",text)
            self.assertIn("status: 待AI识别学生",text)
    def test_manual_confirmed_identity_embeds_complete_profile_and_context_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); session=root/"2026-09-20_120000"; session.mkdir(); vault=self.make_vault(root)
            (session/"transcript.txt").write_text("[00:01] one\n[00:02] two\n[00:03] three\n",encoding="utf-8")
            profile=vault/"上课记录"/"学生档案"/"Eden.md"; profile.write_text("# Eden\n"+"档案内容\n"*150,encoding="utf-8")
            subprocess.run(["bash",str(SCRIPT),str(session),str(vault),"AP","Eden"],check=True,env=self.confirmed_env(),capture_output=True,text=True)
            material=vault/"上课记录"/"课后反馈草稿"/"2026-09-20-Eden-feedback-materials.md"; text=material.read_text(encoding="utf-8")
            self.assertIn("calendar_match_status: confirmed_manual",text)
            self.assertIn("postclass_context: ",text)
            self.assertGreater(text.count("档案内容"),120)
            self.assertIn("本节课 evidence-backed issue assessment",text)
    def test_previous_feedback_uses_latest_date(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); session=root/"2026-08-28_120000"; session.mkdir(); vault=self.make_vault(root)
            (session/"transcript.txt").write_text("[00:01] one\n[00:02] two\n[00:03] three\n",encoding="utf-8")
            (vault/"上课记录"/"学生档案"/"Julien.md").write_text("# Julien",encoding="utf-8")
            f=vault/"上课记录"/"课后反馈"; (f/"2026-08-07-Julien-feedback.md").write_text("旧反馈",encoding="utf-8"); (f/"2026-08-24-Julien-feedback.md").write_text("最近反馈",encoding="utf-8")
            subprocess.run(["bash",str(SCRIPT),str(session),str(vault),"CIE","Julien"],check=True,env=self.confirmed_env(),capture_output=True,text=True)
            text=(vault/"上课记录"/"课后反馈草稿"/"2026-08-28-Julien-feedback-materials.md").read_text(encoding="utf-8")
            self.assertIn("最近反馈",text); self.assertNotIn("\n旧反馈\n",text)
if __name__=="__main__": unittest.main()
