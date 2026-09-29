#!/usr/bin/env python3
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class RecordingSafetyContractTests(unittest.TestCase):
    def test_example_config_has_hard_150_minute_cap(self):
        cfg=json.loads((ROOT/"config.example.json").read_text(encoding="utf-8"))
        self.assertEqual(cfg["max_recording_minutes"],150)
        self.assertGreaterEqual(cfg["min_free_disk_gb"],cfg["critical_free_disk_gb"])
        self.assertEqual(cfg["recording_backend"],"native_system_and_microphone")

    def test_shell_scripts_parse(self):
        paths=[
            ROOT/"setup.sh",
            ROOT/"uninstall.sh",
            *sorted((ROOT/"scripts").glob("*.sh")),
        ]
        for path in paths:
            result=subprocess.run(["bash","-n",str(path)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,f"{path}: {result.stderr}")

    def test_watcher_contains_non_restart_hard_limit_and_disk_guard(self):
        text=(ROOT/"scripts/meeting_watcher.sh").read_text(encoding="utf-8")
        for required in [
            "MAX_RECORDING_SECONDS",
            "recording_limit_reached",
            "HOLD_UNTIL_MEETING_END",
            "recording_disk_guard",
            "capture_segments.tsv",
            "check_capture_runtime_health",
            "recording_incomplete",
            "RECORDING_MIN_COMPLETENESS_RATIO",
        ]:
            self.assertIn(required,text)
        self.assertIn('if [ "$HOLD_UNTIL_MEETING_END" -eq 1 ]',text)

    def test_native_helper_has_runtime_delegate_heartbeat_and_hard_timer(self):
        text=(ROOT/"scripts/capture_native_audio.swift").read_text(encoding="utf-8")
        self.assertIn("SCStreamDelegate",text)
        self.assertIn("didStopWithError",text)
        self.assertIn("heartbeat_epoch=",text)
        self.assertIn("maxDurationSource",text)
        self.assertIn("hard duration limit",text)

    def test_incomplete_marker_is_a_postclass_hard_gate(self):
        post=(ROOT/"scripts/postclass_generate.sh").read_text(encoding="utf-8")
        trigger=(ROOT/"scripts/trigger_postclass_ai.sh").read_text(encoding="utf-8")
        self.assertIn('recording_incomplete',post)
        self.assertIn('TRANSCRIPT_QUALITY="recording_incomplete"',post)
        self.assertGreaterEqual(trigger.count("recording_incomplete"),2)


if __name__=="__main__":
    unittest.main()
