import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RustUpdateServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([
            "cargo", "build", "--offline", "--locked", "--manifest-path",
            str(ROOT / "native/update-service/Cargo.toml"),
        ], check=True, timeout=120)
        cls.binary = ROOT / "native/update-service/target/debug/macshell-update-service"

    def run_service(self, action="status", *arguments, env=None, check=True):
        result = subprocess.run(
            [str(self.binary), action, *arguments],
            env=dict(os.environ, **(env or {})),
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result, json.loads(result.stdout)

    def test_protocol_and_status_match_python_shape(self):
        protocol = subprocess.check_output([str(self.binary), "--protocol-version"], text=True).strip()
        self.assertEqual(protocol, "macshell-update-service 1")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VERSION").write_text("1.1.0\n")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "curl").write_text("#!/bin/sh\nprintf '%s' '{\"tag_name\":\"v1.2.0\",\"draft\":false,\"prerelease\":false}'\n")
            (bin_dir / "checkupdates").write_text("#!/bin/sh\nprintf '%s\\n' 'alpha 1 -> 2'\nexit 0\n")
            (bin_dir / "pacman").write_text("#!/bin/sh\nexit 0\n")
            for path in bin_dir.iterdir():
                path.chmod(0o755)
            result, payload = self.run_service(env={
                "MACSHELL_TEST_BIN_DIR": str(bin_dir),
                "MACSHELL_UPDATE_API_URL": "https://fixture.invalid/release",
                "MACSHELL_UPDATE_VERSION_FILE": str(root / "VERSION"),
                "PATH": str(bin_dir),
                "HOME": str(root / "home"),
            })
            (root / "VERSION").write_text("1.1.0\n")
            self.assertEqual(payload["release"], {"state": "available", "installed": "1.1.0", "latest": "1.2.0", "tag": "v1.2.0"})
            self.assertEqual(payload["packages"], {"state": "available", "count": 1, "packages": ["alpha 1 -> 2"]})

    def test_prepare_clones_tag_checks_version_and_writes_safe_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            for command in (("init", "-q"), ("config", "user.email", "test@example.invalid"), ("config", "user.name", "Test")):
                subprocess.run(["git", "-C", str(repo), *command], check=True, capture_output=True)
            (repo / "VERSION").write_text("1.2.0\n")
            (repo / "install.sh").write_text("#!/bin/sh\nexit 0\n")
            subprocess.run(["git", "-C", str(repo), "add", "VERSION", "install.sh"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)
            subprocess.run(["git", "-C", str(repo), "tag", "v1.2.0"], check=True)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "git").symlink_to(shutil.which("git"))
            (bin_dir / "curl").write_text("#!/bin/sh\nprintf '%s' '{\"tag_name\":\"v1.2.0\",\"draft\":false,\"prerelease\":false}'\n")
            (bin_dir / "checkupdates").write_text("#!/bin/sh\nexit 2\n")
            (bin_dir / "pacman").write_text("#!/bin/sh\nexit 0\n")
            for path in bin_dir.iterdir():
                if not path.is_symlink():
                    path.chmod(0o755)
            env = {"MACSHELL_TEST_BIN_DIR": str(bin_dir), "MACSHELL_UPDATE_API_URL": "https://fixture.invalid/release", "MACSHELL_UPDATE_VERSION_FILE": str(root / "VERSION.installed"), "MACSHELL_UPDATE_REMOTE": repo.as_uri(), "PATH": str(bin_dir), "HOME": str(root / "home"), "XDG_DATA_HOME": str(root / "data")}
            (root / "home").mkdir()
            (root / "VERSION.installed").write_text("1.1.0\n")
            # The Rust service reads the installed VERSION beside its binary;
            # use a temporary copy to exercise the same installed layout.
            installed = root / "installed"
            installed.mkdir()
            shutil.copy2(self.binary, installed / self.binary.name)
            (installed / "VERSION").write_text("1.1.0\n")
            result = subprocess.run([str(installed / self.binary.name), "prepare", "v1.2.0"], env=dict(os.environ, **env), capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            prepared = json.loads(result.stdout)["prepared"]
            self.assertEqual(prepared["tag"], "v1.2.0")
            self.assertTrue(Path(env["XDG_DATA_HOME"]).joinpath("macshell-niri/updates/prepared.json").is_file())
            self.assertIn("install.sh", prepared["command"])

    def test_invalid_release_is_rejected_without_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            result, payload = self.run_service("prepare", "v1.2", env={"HOME": directory, "XDG_DATA_HOME": directory}, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(payload, {"error": "invalid_version"})


if __name__ == "__main__":
    unittest.main()
