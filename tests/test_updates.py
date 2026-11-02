import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from MacShell import update_service as updates


class ReleaseChecks(unittest.TestCase):
    def test_versions_are_numeric_and_only_stable_tags_are_accepted(self):
        self.assertGreater(updates.version("v1.10.0"), updates.version("1.9.9"))
        for invalid in ("v01.2.3", "v1.2.3-beta", "v1.2", "v1.2.3/../../x"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                updates.version(invalid)

    def test_release_failure_is_not_reported_as_up_to_date(self):
        with patch.object(updates, "installed_version", return_value="1.1.0"), patch.object(updates, "latest_release", side_effect=OSError()):
            self.assertEqual(updates.check_release()["state"], "error")

    def test_malformed_remote_release_is_rejected(self):
        for payload in (["v1.2.0"], {"tag_name": 12}):
            result = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
            with self.subTest(payload=payload), patch.object(updates.shutil, "which", return_value="/usr/bin/gh"), patch.object(updates, "run", return_value=result):
                with self.assertRaisesRegex(ValueError, "invalid_release"):
                    updates.latest_release()

    def test_only_newer_release_is_offered(self):
        with patch.object(updates, "installed_version", return_value="1.1.0"), patch.object(updates, "latest_release", return_value="v1.2.0"):
            self.assertEqual(updates.check_release()["state"], "available")
        with patch.object(updates, "installed_version", return_value="1.3.0"), patch.object(updates, "latest_release", return_value="v1.2.0"):
            self.assertEqual(updates.check_release()["state"], "ahead")


class PackageChecks(unittest.TestCase):
    @patch.object(updates.shutil, "which", side_effect=lambda x: "/usr/bin/" + x)
    def test_available_empty_and_failed_are_distinct(self, which):
        for code, output, expected in [(0, "alpha 1 -> 2\nbeta 2 -> 3\n", "available"), (2, "", "current"), (1, "", "error"), (0, "unexpected", "error")]:
            with self.subTest(code=code, output=output), patch.object(updates, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
                answer = updates.check_packages()
                self.assertEqual(answer["state"], expected)
                if expected == "available": self.assertEqual(answer["count"], 2)

    def test_missing_checker_does_not_claim_system_is_current(self):
        with patch.object(updates.shutil, "which", return_value=None):
            self.assertEqual(updates.check_packages()["state"], "unsupported")

    def test_system_update_is_explicit_and_has_no_shell_interpolation(self):
        with patch.object(updates.shutil, "which", side_effect=lambda x: "/usr/bin/" + x), patch.object(updates.subprocess, "Popen") as start:
            updates.launch_packages()
            self.assertEqual(start.call_args.args[0], ["/usr/bin/kitty", "--hold", "-e", "/usr/bin/sudo", "/usr/bin/pacman", "-Syu"])


@unittest.skipUnless(shutil.which("git"), "git required")
class Preparation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        for command in (["init", "-q"], ["config", "user.email", "test@example.invalid"], ["config", "user.name", "Test"]):
            subprocess.run(["git", "-C", str(self.repo), *command], check=True, capture_output=True)
        (self.repo / "VERSION").write_text("1.2.0\n")
        (self.repo / "install.sh").write_text("#!/bin/sh\nexit 0\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "VERSION", "install.sh"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "fixture"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "tag", "v1.2.0"], check=True)
        self.env = patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root / "data")})
        self.env.start(); self.addCleanup(self.env.stop)
        self.remote = patch.object(updates, "REMOTE", self.repo.as_uri())
        self.remote.start(); self.addCleanup(self.remote.stop)
        self.installed = patch.object(updates, "installed_version", return_value="1.1.0")
        self.installed.start(); self.addCleanup(self.installed.stop)
        latest_patch = patch.object(updates, "latest_release", return_value="v1.2.0")
        self.latest = latest_patch.start(); self.addCleanup(latest_patch.stop)

    def test_preparation_clones_tag_without_installing_or_touching_checkout(self):
        result = updates.prepare("v1.2.0")
        self.assertEqual(result["tag"], "v1.2.0")
        self.assertEqual(updates.prepared(), result)
        self.assertTrue((self.repo / "install.sh").is_file())
        self.assertEqual((self.repo / "VERSION").read_text(), "1.2.0\n")
        self.assertNotEqual(updates.prepare("v1.2.0")["command"], result["command"])

    def test_changed_release_does_not_prepare(self):
        self.latest.side_effect = ["v1.2.0", "v1.3.0"]
        with self.assertRaisesRegex(ValueError, "release_changed"):
            updates.prepare("v1.2.0")
        self.assertIsNone(updates.prepared())

    def test_foreign_state_is_not_returned_as_install_command(self):
        base = updates.data_directory()
        base.mkdir(parents=True)
        (base / "prepared.json").write_text(json.dumps({"tag":"v1.2.0", "command":"bash /tmp/install.sh"}))
        self.assertIsNone(updates.prepared())

    def test_installed_prepared_release_is_not_offered_again(self):
        updates.prepare("v1.2.0")
        self.installed.stop()
        with patch.object(updates, "installed_version", return_value="1.2.0"):
            self.assertIsNone(updates.prepared())


if __name__ == "__main__":
    unittest.main()
