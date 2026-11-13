import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "MacShell" / "reveal-folder.sh"


class RevealFolderTests(unittest.TestCase):
    def test_script_is_valid_shell(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_rejects_relative_paths(self):
        result = subprocess.run(
            ["/bin/sh", str(SCRIPT), "tmp", "file://tmp", "open"],
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2)

    def test_opens_gui_file_manager_not_xdg_open(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "folder"
            target.mkdir()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "log"
            nautilus = bin_dir / "nautilus"
            xdg = bin_dir / "xdg-open"
            nautilus.write_text(
                "#!/bin/sh\nprintf 'nautilus:%s\\n' \"$*\" >> \"$REVEAL_LOG\"\n"
            )
            xdg.write_text(
                "#!/bin/sh\nprintf 'xdg:%s\\n' \"$*\" >> \"$REVEAL_LOG\"\nexit 99\n"
            )
            nautilus.chmod(0o755)
            xdg.chmod(0o755)
            env = dict(os.environ)
            env["PATH"] = str(bin_dir)
            env["REVEAL_LOG"] = str(log)
            result = subprocess.run(
                ["/bin/sh", str(SCRIPT), str(target), "file://" + str(target), "open"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            text = log.read_text()
            self.assertIn("nautilus:", text)
            self.assertNotIn("xdg:", text)


if __name__ == "__main__":
    unittest.main()
