import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
import clock_timer as python


class ClockTimerRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='clock-timer-build-'); cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.temp.name, '--example', 'timer'], check=True, timeout=120)
        cls.binary = Path(cls.temp.name) / 'debug/examples/timer'

    def rust(self, op, value, **fields):
        data = dict(op=op, value=value, bootId='boot', **fields)
        result = subprocess.run([str(self.binary)], input=json.dumps(data) + '\n', capture_output=True, text=True, check=True, timeout=5)
        return json.loads(result.stdout)

    def test_timer_commands_checkpoint_expiry_and_queue(self):
        legacy = {'state': 'idle', 'total': 3000, 'left': 3000, 'label': 'Tea'}
        state = python.migrate_legacy(legacy, 'boot', 100, 1000, 'old')
        self.assertEqual(self.rust('migrate', legacy, boot=100, wall=1000, session='old')['result'], state)
        for action, boot, wall, session, duration in [('start',100,1000,'new',5000),('pause',1100,2000,'new',None),('resume',2000,3000,'new',None)]:
            expected = python.command(state, action, 'boot', boot, session_id=session, duration_ms=duration, wall_now=wall)
            actual = self.rust('command', state, action=action, boot=boot, wall=wall, session=session, duration=duration)
            self.assertTrue(actual['success'], actual); self.assertEqual(actual['result'], expected); state=expected
        self.assertEqual(self.rust('checkpoint', state, boot=2500, wall=3500)['result'], python.checkpoint(state, 'boot', 2500, 3500))
        state['completion'] = {'eventId': 'existing', 'sessionId': 'old', 'label': 'other'}
        expired = python.advance(state, 'boot', 6000)
        self.assertEqual(self.rust('advance', state, boot=6000)['result'], expired)
        self.assertEqual(self.rust('advance', expired, boot=9000)['result'], expired)
        self.assertEqual(self.rust('command', state, action='pause', boot=6000, session='new')['result'], python.command(state, 'pause', 'boot', 6000, session_id='new'))

    def test_reboot_recovery_and_stale_session(self):
        state = python.migrate_legacy({'state':'running','total':10000,'endAt':9000,'label':''}, 'boot', 100, 1000, 'old')
        new_boot = dict(op='advance', value=state, bootId='other', boot=20)
        result = subprocess.run([str(self.binary)], input=json.dumps(new_boot)+'\n', capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['result'], python.advance(state, 'other', 20))
        self.assertFalse(self.rust('command', state, action='pause', boot=200, session='wrong')['success'])


if __name__ == '__main__': unittest.main()
