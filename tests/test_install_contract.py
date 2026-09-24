from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class InstallContractTests(unittest.TestCase):
    def test_setup_is_self_bootstrapping(self):
        setup = (ROOT / "setup.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_brew", setup)
        self.assertIn("ensure_formula_command whisper-cli whisper-cpp", setup)
        self.assertIn("download_whisper_model", setup)
        self.assertIn("healthcheck.sh", setup)
        self.assertIn('"whisper_cli"', setup)

    def test_skill_requires_first_use_bootstrap(self):
        skill = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("setup.sh --auto", skill)
        self.assertIn("healthcheck.sh", skill)
        self.assertIn("不得宣称 Pipeline 已就绪", skill)

    def test_runtime_config_template_has_resolved_cli(self):
        config = (ROOT / "config.example.json").read_text(encoding="utf-8")
        self.assertIn('"skill_version": "2.3.1"', config)
        self.assertIn('"whisper_cli"', config)
