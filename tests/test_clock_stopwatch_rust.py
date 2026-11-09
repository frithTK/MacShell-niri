import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
import clock_stopwatch as python


class StopwatchRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='clock-stopwatch-build-'); cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.temp.name, '--example', 'stopwatch'], check=True, timeout=120)
        cls.binary = Path(cls.temp.name) / 'debug/examples/stopwatch'

    def rust(self, operation, value, **kwargs):
        request = dict(op=operation, value=value, **kwargs)
        result = subprocess.run([str(self.binary)], input=json.dumps(request) + '\n', text=True, capture_output=True, check=True, timeout=5)
        return json.loads(result.stdout)

    def test_transitions_and_recovery_match_python(self):
        initial = {'running': False, 'acc': 0, 'startAt': 0, 'laps': []}
        py = python.migrate_legacy(initial, 100, 1000, 'session')
        self.assertEqual(self.rust('migrate', initial, boot=100, wall=1000, session='session')['result'], py)
        for action, boot, wall in [('start', 100, 1000), ('lap', 2100, 3000), ('lap', 3100, 4000), ('pause', 4100, 5000), ('start', 5000, 6000), ('pause', 6500, 7500)]:
            expected = python.command(py, action, boot, 'session', wall)
            actual = self.rust('command', py, action=action, boot=boot, wall=wall, session='session')
            self.assertTrue(actual['success'], actual)
            self.assertEqual(actual['result'], expected)
            py = expected
        recovered = python.restore(py, True)
        self.assertEqual(self.rust('restore', py, changed=True)['result'], recovered)
        self.assertEqual(self.rust('projection', recovered, boot=7000, wall=8000)['result'], python.legacy_projection(recovered, 7000, 8000))
        resumed = python.command(recovered, 'recover-resume', 7000, 'session', 8000)
        self.assertEqual(self.rust('command', recovered, action='recover-resume', boot=7000, wall=8000, session='session')['result'], resumed)
        self.assertEqual(self.rust('checkpoint', resumed, boot=8000, wall=9000)['result'], python.checkpoint(resumed, 8000, 9000))

    def test_invalid_transitions_and_backward_boot(self):
        idle = python.migrate_legacy({'running': False, 'acc': 0, 'startAt': 0}, 10, 100, 's')
        for action, session in [('pause', 's'), ('start', 'wrong')]:
            with self.assertRaises(python.StopwatchError): python.command(idle, action, 10, session)
            self.assertFalse(self.rust('command', idle, action=action, boot=10, session=session)['success'])
        running = python.command(idle, 'start', 10, 's')
        with self.assertRaises(python.StopwatchError): python.elapsed(running, 9)
        self.assertFalse(self.rust('elapsed', running, boot=9)['success'])
        invalid = copy.deepcopy(idle); invalid['laps'] = [1]
        with self.assertRaises(python.StopwatchError): python.validate(invalid)
        self.assertFalse(self.rust('validate', invalid)['success'])


if __name__ == '__main__': unittest.main()
