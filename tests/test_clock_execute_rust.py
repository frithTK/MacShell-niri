import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from clock_commands import execute
from clock_store import ClockStore
from clock_timer import migrate_legacy
import clock_stopwatch


class ClockExecuteRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='clock-execute-build-'); cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.build.name, '--example', 'execute'], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/examples/execute'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name); self.py = root / 'python/clock.json'; self.rs = root / 'rust/clock.json'
        timing = migrate_legacy({'state':'idle','total':5000,'left':5000},'boot-a',1000,100000,'timer')
        timing['stopwatch'] = clock_stopwatch.migrate_legacy({'running':False,'startAt':0,'acc':0,'laps':[]},1000,100000,'sw')
        for path in (self.py,self.rs):
            with ClockStore(path) as store: store.commit({'timing':copy.deepcopy(timing)},'missing',0)

    def run_rust(self, envelope, boot, wall):
        p = subprocess.Popen([str(self.binary),str(self.rs)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, TZ='UTC'))
        self.assertTrue(json.loads(p.stdout.readline())['ready'])
        request = dict(envelope=envelope,bootId='boot-a',boot=boot,wall=wall)
        output, error = p.communicate(json.dumps(request)+'\n',timeout=5)
        self.assertEqual(p.returncode,0,error)
        return json.loads(output)

    def test_stopwatch_and_snooze_replay_match_python(self):
        commands = [
            ('stopwatch-start', {'sessionId':'sw'}, 1, 1100),
            ('stopwatch-lap', {'sessionId':'sw'}, 2, 2200),
            ('stopwatch-pause', {'sessionId':'sw'}, 3, 3300),
        ]
        for action,args,revision,boot in commands:
            envelope=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=boot,revision=revision,action=action,args=args)
            with ClockStore(self.py) as store: expected=execute(store,envelope,'boot-a',boot,100000+boot)
            actual=self.run_rust(envelope,boot,100000+boot)
            self.assertTrue(actual['success'],actual); self.assertEqual(actual['result'],expected)
            replay=self.run_rust(envelope,boot+50,200000+boot)
            self.assertEqual(replay['result'],expected)
        for path in (self.py,self.rs):
            with ClockStore(path) as store:
                doc,token=store.read(); timing=doc['timing']; timing['completion']={'eventId':'alarm','sessionId':'a','kind':'alarm','label':'Wake'}
                store.commit({'timing':timing},token,doc['revision'])
        envelope=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=4000,revision=5,action='snooze',args={'eventId':'alarm'})
        with ClockStore(self.py) as store: expected=execute(store,envelope,'boot-a',4000,104000)
        actual=self.run_rust(envelope,4000,104000); self.assertEqual(actual['result'],expected)
        self.assertEqual(self.run_rust(envelope,4100,999999)['result'],expected)

    def test_revision_conflict_preserves_bytes(self):
        envelope=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=1100,revision=0,action='stopwatch-start',args={'sessionId':'sw'})
        before=self.rs.read_bytes(); result=self.run_rust(envelope,1200,100000)
        self.assertFalse(result['success']); self.assertEqual(self.rs.read_bytes(),before)

    def test_start_expiry_and_repeat_are_idempotent(self):
        start=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=1100,revision=1,action='start',args={'sessionId':'new','durationMs':5000,'label':'Tea','soundId':'builtin-chime-01','soundOptions':{'volume':40}})
        with ClockStore(self.py) as store: expected=execute(store,start,'boot-a',1200,100000)
        self.assertEqual(self.run_rust(start,1200,100000)['result'],expected)
        pause=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=6200,revision=2,action='pause',args={'sessionId':'new'})
        with ClockStore(self.py) as store: expired=execute(store,pause,'boot-a',6200,105000)
        self.assertEqual(self.run_rust(pause,6200,105000)['result'],expired)
        repeat=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=6300,revision=3,action='repeat-timer',args={'eventId':expired['timing']['completion']['eventId'],'sessionId':'repeat'})
        with ClockStore(self.py) as store: expected=execute(store,repeat,'boot-a',6300,105100)
        self.assertEqual(self.run_rust(repeat,6300,105100)['result'],expected)
        self.assertEqual(self.run_rust(repeat,6400,999999)['result'],expected)

    def test_settings_patch_and_pending_alarm_guard(self):
        alarm={'id':'a','h':9,'m':0,'on':True,'days':[1],'label':''}
        command=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=1100,revision=1,action='patch-settings',args={'patch':{'alarms':[alarm],'cities':[{'name':'London','tz':'Europe/London'}],'recents':[60000]}})
        with ClockStore(self.py) as store: expected=execute(store,command,'boot-a',1200,100000)
        self.assertEqual(self.run_rust(command,1200,100000)['result'],expected)
        self.assertEqual(self.run_rust(command,1300,200000)['result'],expected)
        for path in (self.py,self.rs):
            with ClockStore(path) as store:
                doc,token=store.read(); timing=doc['timing'];timing.update(alarmCursorWallMs=1793005199000,alarmCursorBootId='boot-a',handledAlarmDates={})
                store.commit({'timing':timing,'alarms':[{'id':'a','h':9,'m':0,'on':True,'days':[],'label':''}]},token,doc['revision'])
        command=dict(id=str(uuid.uuid4()),bootId='boot-a',issuedBootMs=1400,revision=3,action='patch-settings',args={'patch':{'alarms':[]}})
        result=self.run_rust(command,1400,1793005260000)
        self.assertFalse(result['success']);self.assertIn('Pending alarm',result['error'])


if __name__ == '__main__': unittest.main()
