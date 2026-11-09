import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
import clock_snooze as python
import clock_timer


class ClockSnoozeRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='clock-snooze-build-'); cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.temp.name, '--example', 'snooze'], check=True, timeout=120)
        cls.binary = Path(cls.temp.name) / 'debug/examples/snooze'

    def rust(self, op, value, **kwargs):
        result = subprocess.run([str(self.binary)], input=json.dumps(dict(op=op, value=value, **kwargs))+'\n', capture_output=True, text=True, check=True, timeout=5)
        return json.loads(result.stdout)

    def test_schedule_expiry_queue_and_reboot(self):
        timing = clock_timer.migrate_legacy({'state':'idle','total':5000,'left':5000}, 'boot-a', 1000, 900000, 'timer')
        event = {'eventId':'alarm-event','sessionId':'alarm-a','kind':'alarm','label':'Wake','soundId':'builtin-gentle-02','soundOptions':{'volume':42,'startMs':3000}}
        expected = copy.deepcopy(timing); python.schedule(expected,event,'snooze-a','boot-a',1000)
        result = self.rust('schedule', timing, event=event, id='snooze-a', bootId='boot-a', boot=1000)
        self.assertEqual(result['result'], expected)
        early = clock_timer.advance(expected,'boot-a',540999)
        self.assertEqual(self.rust('advance',expected,bootId='boot-a',boot=540999)['result'], early)
        expected['completion'] = {'eventId':'existing','sessionId':'other','label':'existing'}
        due = clock_timer.advance(expected,'boot-a',541000,1700000000000)
        self.assertEqual(self.rust('advance',expected,bootId='boot-a',boot=541000,wall=1700000000000)['result'], due)
        reboot = clock_timer.advance(expected,'boot-b',500)
        self.assertEqual(self.rust('advance',expected,bootId='boot-b',boot=500)['result'], reboot)

    def test_recovery_and_invalid_sound(self):
        timing = clock_timer.migrate_legacy({'state':'idle','total':5000,'left':5000}, 'boot-a', 1000, 900000, 'timer')
        recovered = python.migrate_legacy([{'at':1100000,'label':'Wake','extra':{'keep':True}}],1000000)
        timing['legacySnoozesRecovery'] = recovered
        expected = python.resolve_recovery(copy.deepcopy(timing),recovered[0]['id'],'resume','cmd','boot-a',2000)
        actual = self.rust('resolve',timing,id=recovered[0]['id'],decision='resume',commandId='cmd',bootId='boot-a',boot=2000)
        self.assertEqual(actual['result'],expected)
        invalid = copy.deepcopy(expected['snoozes']); invalid[0]['soundId'] = 'bad'
        with self.assertRaises(ValueError): python.validate(invalid)
        self.assertFalse(self.rust('validate',invalid)['success'])


if __name__ == '__main__': unittest.main()
