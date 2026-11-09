"""Installed Rust-only policy and compatibility with legacy profiles."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RustOnlyLauncherTests(unittest.TestCase):
    def test_all_python_fallback_launchers_obey_profile_policy(self):
        launchers = []
        for folder in ('MacShell', 'MacLock', 'scripts'):
            for path in (ROOT / folder).glob('*.sh'):
                content = path.read_text()
                if 'exec python3' in content:
                    launchers.append((path, content))
        self.assertGreaterEqual(len(launchers), 30)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tools = root / 'tools'; tools.mkdir()
            python = tools / 'python3'
            python.write_text('#!/bin/sh\nprintf "legacy-python\\n"\n')
            python.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + '/usr/bin:/bin',
                       MACSHELL_NIRI_BRIDGE_BACKEND='auto')
            for index, (source, content) in enumerate(launchers):
                with self.subTest(launcher=str(source.relative_to(ROOT))):
                    folder = root / str(index); folder.mkdir()
                    launcher = folder / source.name; shutil.copy(source, launcher)
                    match = re.search(r'binary="\$directory/([^"]+)"', content)
                    self.assertIsNotNone(match)
                    binary = folder / match.group(1)
                    command = ['/bin/sh', str(launcher), 'input', '{}']
                    legacy = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
                    self.assertEqual(legacy.returncode, 0, legacy.stderr)
                    self.assertIn('legacy-python', legacy.stdout)
                    (folder / '.macshell-rust-only').write_text('1\n')
                    for present in (False, True):
                        if present:
                            binary.write_text('#!/bin/sh\nprintf "incompatible\\n"\n')
                            binary.chmod(0o755)
                        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn('legacy-python', result.stdout)
                        self.assertIn('Rust', result.stderr)
                    marker = folder / '.macshell-rust-only'
                    marker.unlink()
                    for marker_type in ('directory', 'broken-link'):
                        with self.subTest(marker=marker_type):
                            if marker_type == 'directory':
                                marker.mkdir()
                            else:
                                marker.symlink_to('missing-marker-target')
                            for present in (False, True):
                                if present:
                                    binary.write_text('#!/bin/sh\nprintf "incompatible\\n"\n')
                                    binary.chmod(0o755)
                                else:
                                    binary.unlink(missing_ok=True)
                                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
                                self.assertNotEqual(result.returncode, 0)
                                self.assertNotIn('legacy-python', result.stdout)
                                self.assertIn('Rust', result.stderr)
                            if marker_type == 'directory':
                                marker.rmdir()
                            else:
                                marker.unlink()


if __name__ == '__main__':
    unittest.main()
