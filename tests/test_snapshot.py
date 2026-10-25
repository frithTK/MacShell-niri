import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("snapshot", ROOT / "scripts/desktop_snapshot.py")
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    def test_restore_preserves_current_files_and_removes_new_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            config = home / ".config/niri/config.kdl"
            config.parent.mkdir(parents=True)
            config.write_text("// original niri\n")
            new_config = home / ".config/macshell-niri"
            paths = [".config/niri", ".config/macshell-niri"]
            result = subprocess.CompletedProcess([], 0, stdout="test inventory\n", stderr="")
            with patch.multiple(snapshot, USER_PATHS=paths, SYSTEM_PATHS=[], SOURCE=home / "no-source"), patch.object(snapshot.subprocess, "run", return_value=result):
                directory = snapshot.create(home)
            self.assertGreater(snapshot.verify(directory), 0)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            config.write_text("// user edits after snapshot\n")
            new_config.mkdir()
            (new_config / "settings.json").write_text('{"glass":true}')
            with patch.object(snapshot.Path, "home", return_value=home), patch.object(snapshot.os, "geteuid", return_value=1000):
                snapshot.restore(directory)
            self.assertEqual(config.read_text(), "// original niri\n")
            self.assertFalse(new_config.exists())
            recovery = next(directory.glob("pre-restore-*"))
            self.assertEqual((recovery / ".config/niri/config.kdl").read_text(), "// user edits after snapshot\n")
            self.assertTrue((recovery / ".config/macshell-niri/settings.json").exists())

    def test_corrupt_backup_is_rejected_before_restoring(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "original").write_text("original")
            (directory / "checksums.json").write_text(json.dumps(snapshot.checksums(directory)))
            (directory / "original").write_text("corrupted")
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                snapshot.restore(directory)


if __name__ == "__main__":
    unittest.main()
