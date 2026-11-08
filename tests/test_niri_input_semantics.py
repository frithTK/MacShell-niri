"""Validate isolated niri input/include fixtures; never touch the user profile."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which("niri"), "niri is not installed")
class NiriInputSemanticsTests(unittest.TestCase):
    def validate(self, config, fragment):
        with tempfile.TemporaryDirectory(prefix="macshell-niri-semantics-") as directory:
            root = Path(directory)
            (root / "config.kdl").write_text(config)
            (root / "macshell-input.kdl").write_text(fragment)
            return subprocess.run(
                ["niri", "validate", "-c", str(root / "config.kdl")],
                capture_output=True, text=True, timeout=10,
            )

    def test_separate_input_sections_in_include_are_accepted(self):
        result = self.validate(
            'input { keyboard { xkb { layout "us"; }; }; }\ninclude "./macshell-input.kdl"\n',
            'input { mouse { accel-speed 0.25; }; }\n',
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_input_setting_in_include_is_accepted_by_validator(self):
        result = self.validate(
            'input { mouse { accel-speed 0.1; }; }\ninclude "./macshell-input.kdl"\n',
            'input { mouse { accel-speed 0.25; }; }\n',
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
