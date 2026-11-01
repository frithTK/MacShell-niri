import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ClockPathTests(unittest.TestCase):
    def test_real_save_command_uses_xdg_and_explicit_override(self):
        source = (ROOT / 'MacShell/ClockApp.qml').read_text()
        match = re.search(r'Quickshell\.execDetached\(\["sh", "-c", ("(?:\\.|[^"\\])*")', source)
        self.assertIsNotNone(match)
        script = json.loads(match.group(1))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for override in (False, True):
                with self.subTest(override=override):
                    case = root / ('override' if override else 'xdg')
                    for part in ('home', 'config', 'settings'):
                        (case / part).mkdir(parents=True, exist_ok=True)
                    environment = dict(os.environ, HOME=str(case / 'home'), XDG_CONFIG_HOME=str(case / 'config'))
                    environment.pop('MACSHELL_SETTINGS_HOME', None)
                    if override:
                        environment['MACSHELL_SETTINGS_HOME'] = str(case / 'settings')
                    subprocess.run(['sh', '-c', script, 'sh', '{"timer":{"label":"Path test"}}'],
                                   env=environment, check=True, timeout=10)
                    path = case / ('settings' if override else 'config') / 'macshell/clock.json'
                    self.assertEqual(json.loads(path.read_text())['timer']['label'], 'Path test')
                    self.assertFalse((case / 'home/.config/macshell/clock.json').exists())


if __name__ == '__main__':
    unittest.main()
