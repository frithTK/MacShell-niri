from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from clock_alarms import evaluate


class ClockAlarmsRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='clock-alarms-build-'); cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.temp.name, '--example', 'alarms'], check=True, timeout=120)
        cls.binary = Path(cls.temp.name) / 'debug/examples/alarms'

    def rust(self, alarms, handled, since, now, zone):
        request = dict(alarms=alarms, handled=handled, since=since, now=now, zone=zone)
        result = subprocess.run([str(self.binary)], input=json.dumps(request, ensure_ascii=False)+'\n', capture_output=True, text=True, check=True, timeout=5)
        return json.loads(result.stdout)

    def test_matches_python_across_dst_one_shot_and_rewind(self):
        ms = lambda value: int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp()*1000)
        cases = [
            ([{'id':'утро','h':2,'m':30,'on':True,'days':list(range(7)),'label':'Чай'}], {}, '2026-03-29T00:00:00','2026-03-29T01:05:00','Europe/Berlin'),
            ([{'id':'a','h':2,'m':30,'on':True,'days':list(range(7))}], {}, '2026-10-25T00:00:00','2026-10-25T00:40:00','Europe/Berlin'),
            ([{'id':'weekly','h':9,'m':0,'on':True,'days':[1]},{'id':'once','h':8,'m':0,'on':True,'days':[]}], {}, '2026-09-01T00:00:00','2026-10-26T09:05:00','UTC'),
            ([{'id':'a','h':9,'m':0,'on':True,'days':list(range(7))}], {'a':['2026-10-26']}, '2026-10-26T06:00:00','2026-10-26T10:00:00','Europe/Berlin'),
            ([{'id':'a','h':9,'m':0,'on':True,'days':[]}], {}, '2026-10-26T10:00:00','2026-10-26T09:00:00','UTC'),
        ]
        for alarms, handled, since, now, zone in cases:
            with self.subTest(zone=zone, since=since):
                expected = evaluate(alarms,handled,ms(since),ms(now),ZoneInfo(zone))
                actual = self.rust(alarms,handled,ms(since),ms(now),zone)
                self.assertTrue(actual['success'],actual)
                self.assertEqual((actual['alarms'],actual['handled'],actual['events']),expected)

    def test_invalid_days_and_sound_are_rejected(self):
        for alarm in [dict(id='a',h=9,m=0,on=True,days=[0,0]),dict(id='a',h=9,m=0,on=True,days=[],soundId='../invalid')]:
            with self.assertRaises(ValueError): evaluate([alarm],{},0,100000,ZoneInfo('UTC'))
            self.assertFalse(self.rust([alarm],{},0,100000,'UTC')['success'])


if __name__ == '__main__': unittest.main()
