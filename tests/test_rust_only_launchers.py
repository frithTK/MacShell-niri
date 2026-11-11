"""Runtime launchers never invoke Python; missing Rust binaries fail."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RustOnlyLauncherTests(unittest.TestCase):
    def test_runtime_launchers_never_invoke_python(self):
        launchers = []
        for folder in ('MacShell', 'MacLock', 'scripts'):
            for path in (ROOT / folder).glob('*.sh'):
                content = path.read_text()
                if 'binary="$directory/' not in content:
                    continue
                if 'Rust' not in content or 'exit 1' not in content:
                    continue
                self.assertNotIn('exec python3', content)
                self.assertNotIn('python3', content)
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
                    missing = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
                    self.assertNotEqual(missing.returncode, 0, missing.stdout)
                    self.assertNotIn('legacy-python', missing.stdout)
                    self.assertIn('Rust', missing.stderr)
                    binary.write_text('#!/bin/sh\nprintf "incompatible\\n"\n')
                    binary.chmod(0o755)
                    incompatible = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
                    self.assertNotEqual(incompatible.returncode, 0)
                    self.assertNotIn('legacy-python', incompatible.stdout)
                    self.assertIn('Rust', incompatible.stderr)


if __name__ == '__main__':
    unittest.main()
