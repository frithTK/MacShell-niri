import json
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ClockPrototypeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='clock-prototype-build-'); cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(ROOT/'native/clock-core/Cargo.toml'),'--target-dir',cls.temp.name,'--bin','clock-service-prototype'],check=True,timeout=120)
        cls.binary=Path(cls.temp.name)/'debug/clock-service-prototype'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)/'clock.json'

    def start(self, audio=False, builtin_dir=None, player_script=None):
        command=[str(self.binary),'--prototype','--store',str(self.path)]
        env=dict(os.environ,TZ='UTC')
        if audio:
            root=self.path.parent;bindir=root/'bin';bindir.mkdir(exist_ok=True)
            player=bindir/'pw-play';player.write_text('#!/usr/bin/python3\nimport json,os,time\nif os.path.exists(os.environ["TEST_STORE"]):\n d=json.load(open(os.environ["TEST_STORE"]))\n if d["timing"]["completion"] is not None: assert d["timing"]["completion"]["soundClaimed"]\nopen(os.environ["TEST_AUDIO"],"a").write(str(os.getpid())+"\\n")\ntime.sleep(30)\n');player.chmod(0o755)
            if player_script is not None:player.write_text(player_script)
            (root/'timer.wav').write_bytes(b'test')
            env.update(PATH=str(bindir)+os.pathsep+os.environ['PATH'],TEST_STORE=str(self.path),TEST_AUDIO=str(root/'audio.log'))
            command+=['--audio-dir',str(root),'--builtin-dir',str(builtin_dir or root),'--audio-worker',str(bindir/'worker')]
        p=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,env=env)
        messages=queue.Queue()
        threading.Thread(target=lambda:[messages.put(line) for line in p.stdout],daemon=True).start()
        self.addCleanup(self.stop,p)
        self.assertEqual(json.loads(messages.get(timeout=5))['type'],'ready')
        return p,messages

    @staticmethod
    def stop(p):
        if p.poll() is None:p.terminate()
        p.wait(timeout=5)
        p.stdin.close();p.stdout.close();p.stderr.close()

    def send(self,p,action,identifier,data=None):
        p.stdin.write(json.dumps({'id':identifier,'generation':1,'action':action,'data':data or {}})+'\n');p.stdin.flush()

    def get(self,messages,kind,timeout=5):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            value=json.loads(messages.get(timeout=max(.01,end-time.monotonic())))
            if value['type']==kind:return value
        self.fail('Missing '+kind)

    def persist_initial(self, state):
        self.path.write_text(json.dumps({key: state[key] for key in ('revision', 'timing', 'timer', 'sw', 'ringing')} | {'version': 2}))

    def test_read_only_start_and_rejected_command_do_not_create_store(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state')
        self.assertEqual(state['revision'],0);self.assertFalse(self.path.exists())
        self.send(p,'prepare',2);prepared=self.get(messages,'prepared');self.assertEqual(prepared['revision'],0)
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=0,action='start',args={'sessionId':prepared['sessionId'],'durationMs':0})
        self.send(p,'command',3,envelope);self.assertFalse(self.get(messages,'result')['success'])
        self.assertFalse(self.path.exists())

    def test_prepare_command_replay_and_restart(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state')
        self.assertEqual(state['timer']['state'],'idle')
        self.send(p,'prepare',2);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':30000,'label':'Tea'})
        self.send(p,'command',3,envelope);result=self.get(messages,'result');self.assertTrue(result['success'],result)
        running=self.get(messages,'state');self.assertEqual(running['timer']['state'],'running')
        self.stop(p);p,messages=self.start();self.send(p,'load',4);reloaded=self.get(messages,'state')
        self.assertEqual(reloaded['timing']['timer']['sessionId'],prepared['sessionId'])
        self.send(p,'command',5,envelope);replay=self.get(messages,'result')
        self.assertEqual(replay['result'],result['result'])

    def test_due_alarm_is_persisted_once_on_restart(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text());now=datetime.now(timezone.utc);occurrence=now.replace(second=0,microsecond=0)
        if now.second<2: occurrence-=timedelta(minutes=1)
        document['alarms']=[{'id':'alarm-a','h':occurrence.hour,'m':occurrence.minute,'on':True,'days':[],'label':'Wake'}]
        document['timing']['alarmCursorWallMs']=int((occurrence-timedelta(seconds=1)).timestamp()*1000)
        document['timing']['alarmCursorBootId']=state['bootId'];document['timing']['handledAlarmDates']={}
        self.path.write_text(json.dumps(document))
        p,messages=self.start();self.send(p,'load',2);state=self.get(messages,'state')
        self.assertEqual(state['timing']['completion']['sessionId'],'alarm-a')
        self.assertFalse(state['alarms'][0]['on']);event=state['timing']['completion']['eventId']
        self.stop(p);p,messages=self.start();self.send(p,'load',3);again=self.get(messages,'state')
        self.assertEqual(again['timing']['completion']['eventId'],event)
        self.assertEqual(again['timing'].get('completionQueue',[]),[])

    def test_alarm_queue_snooze_restart_and_dismiss(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text());now=datetime.now(timezone.utc)
        occurrence=now.replace(second=0,microsecond=0)
        if now.second<2: occurrence-=timedelta(minutes=1)
        document['alarms']=[{'id':name,'h':occurrence.hour,'m':occurrence.minute,'on':True,'days':[],'label':name,'soundId':'silence'} for name in ('first','second')]
        document['timing'].update(alarmCursorWallMs=int((occurrence-timedelta(seconds=1)).timestamp()*1000),alarmCursorBootId=state['bootId'],handledAlarmDates={})
        self.path.write_text(json.dumps(document));p,messages=self.start();self.send(p,'load',2);state=self.get(messages,'state')
        first=state['timing']['completion'];queued=state['timing']['completionQueue']
        self.assertEqual(len(queued),1);self.assertEqual({first['sessionId'],queued[0]['sessionId']},{'first','second'})
        self.assertTrue(all(not alarm['on'] for alarm in state['alarms']))
        self.send(p,'prepare',3);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='snooze',args={'eventId':first['eventId']})
        self.send(p,'command',4,envelope);result=self.get(messages,'result');self.assertTrue(result['success'],result)
        self.stop(p);p,messages=self.start();self.send(p,'load',5);state=self.get(messages,'state')
        self.assertEqual(state['timing']['completion']['eventId'],queued[0]['eventId'])
        self.assertEqual(state['timing']['snoozes'][0]['sourceEventId'],first['eventId'])
        self.assertEqual(state['timing']['completionQueue'],[])
        self.send(p,'command',6,envelope);self.assertEqual(self.get(messages,'result')['result'],result['result'])
        self.send(p,'prepare',7);prepared=self.get(messages,'prepared')
        dismiss=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='dismiss-event',args={'eventId':queued[0]['eventId']})
        self.send(p,'command',8,dismiss);self.assertTrue(self.get(messages,'result')['success'])
        self.stop(p);document=json.loads(self.path.read_text());document['timing']['snoozes'][0]['deadlineBootMs']=0;self.path.write_text(json.dumps(document))
        p,messages=self.start();self.send(p,'load',9);state=self.get(messages,'state')
        self.assertEqual(state['timing']['completion']['sourceEventId'],first['eventId']);self.assertEqual(state['timing']['snoozes'],[])

    def test_timer_expires_during_continuous_requests(self):
        p,messages=self.start();self.send(p,'prepare',1);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':300,'soundId':'silence'})
        self.send(p,'command',2,envelope);self.assertTrue(self.get(messages,'result')['success'])
        end=time.monotonic()+1.5
        while time.monotonic()<end:
            self.send(p,'load',3);time.sleep(.01)
        self.assertIsNotNone(json.loads(self.path.read_text())['timing']['completion'])

    def test_audio_claim_persisted_before_owned_playback_and_stopped(self):
        p,messages=self.start(audio=True);self.send(p,'prepare',1);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':200,'label':'Tea'})
        self.send(p,'command',2,envelope);self.assertTrue(self.get(messages,'result')['success'])
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.05)
        self.assertTrue(log.exists());pid=int(log.read_text().splitlines()[0]);self.assertTrue(Path('/proc',str(pid)).exists())
        self.send(p,'prepare',3);prepared=self.get(messages,'prepared')
        document=json.loads(self.path.read_text());event=document['timing']['completion']['eventId']
        dismiss=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='dismiss-event',args={'eventId':event})
        self.send(p,'command',4,dismiss);self.assertTrue(self.get(messages,'result')['success'])
        end=time.monotonic()+3
        while Path('/proc',str(pid)).exists() and time.monotonic()<end:time.sleep(.05)
        self.assertFalse(Path('/proc',str(pid)).exists())

    def test_audio_spawn_failure_is_reported_and_event_remains_available(self):
        p,messages=self.start(audio=True,player_script='#!/bin/sh\nexit 1\n');self.send(p,'prepare',1);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':200,'soundOptions':{'fadeMs':1}})
        self.send(p,'command',2,envelope);self.assertTrue(self.get(messages,'result')['success'])
        warning=self.get(messages,'error');self.assertEqual(warning['error'],'Clock sound failed; using the built-in sound')
        error=self.get(messages,'error');self.assertEqual(error['error'],'Clock sound playback failed')
        self.send(p,'load',3);state=self.get(messages,'state')
        while state['id']!=3:state=self.get(messages,'state')
        self.assertEqual(state['timing']['completion']['sessionId'],prepared['sessionId'])
        self.assertTrue(state['timing']['completion']['soundClaimed'])
        self.assertFalse((self.path.parent/'audio.log').exists())

    def test_missing_selected_sound_uses_bundled_not_legacy_sound(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text())
        document['timing']['completion']={'eventId':'missing-sound','sessionId':'timer-a','kind':'timer','label':'','soundId':'user-'+'a'*64}
        self.path.write_text(json.dumps(document))
        builtin=self.path.parent/'builtin';builtin.mkdir();(builtin/'timer.wav').write_bytes(b'test')
        script='#!/usr/bin/python3\nimport os,sys,time\nopen(os.environ["TEST_AUDIO"],"a").write(sys.argv[-1]+"\\n")\ntime.sleep(30)\n'
        p,messages=self.start(audio=True,builtin_dir=builtin,player_script=script)
        warning=self.get(messages,'error');self.assertEqual(warning['error'],'Clock sound failed; using the built-in sound')
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.02)
        self.assertEqual(log.read_text().splitlines(),[str(builtin/'timer.wav')])

    def test_dismissing_active_alarm_switches_audio_to_queued_alarm(self):
        (self.path.parent/'alarm.wav').write_bytes(b'test')
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text());now=datetime.now(timezone.utc);occurrence=now.replace(second=0,microsecond=0)
        if now.second<2: occurrence-=timedelta(minutes=1)
        document['alarms']=[{'id':name,'h':occurrence.hour,'m':occurrence.minute,'on':True,'days':[],'label':name} for name in ('first','second')]
        document['timing'].update(alarmCursorWallMs=int((occurrence-timedelta(seconds=1)).timestamp()*1000),alarmCursorBootId=state['bootId'],handledAlarmDates={})
        self.path.write_text(json.dumps(document));p,messages=self.start(audio=True)
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.02)
        self.assertTrue(log.exists());first_pid=int(log.read_text().splitlines()[0])
        self.send(p,'prepare',2);prepared=self.get(messages,'prepared');document=json.loads(self.path.read_text())
        first=document['timing']['completion'];second=document['timing']['completionQueue'][0]
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='dismiss-event',args={'eventId':first['eventId']})
        self.send(p,'command',3,envelope);self.assertTrue(self.get(messages,'result')['success'])
        end=time.monotonic()+5
        while len(log.read_text().splitlines())<2 and time.monotonic()<end:time.sleep(.02)
        played=log.read_text().splitlines();self.assertEqual(len(played),2);self.assertNotEqual(int(played[1]),first_pid)
        self.assertFalse(Path('/proc',str(first_pid)).exists())
        document=json.loads(self.path.read_text());self.assertEqual(document['timing']['completion']['eventId'],second['eventId']);self.assertTrue(document['timing']['completion']['soundClaimed'])

    def test_killed_service_keeps_claimed_event_without_replaying_sound(self):
        p,messages=self.start(audio=True);self.send(p,'prepare',1);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':200})
        self.send(p,'command',2,envelope);self.assertTrue(self.get(messages,'result')['success'])
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.02)
        self.assertTrue(log.exists());pid=int(log.read_text().splitlines()[0])
        event=json.loads(self.path.read_text())['timing']['completion'];self.assertTrue(event['soundClaimed'])
        p.kill();p.wait(timeout=5)
        # SIGKILL cannot reap a child; stop the test-owned player explicitly.
        try: os.kill(pid, 15)
        except ProcessLookupError: pass
        p,messages=self.start(audio=True);self.send(p,'load',3);state=self.get(messages,'state')
        self.assertEqual(state['timing']['completion']['eventId'],event['eventId'])
        time.sleep(.6);self.assertEqual(len(log.read_text().splitlines()),1)

    def test_used_sound_cannot_be_deleted(self):
        p,messages=self.start(audio=True);self.send(p,'prepare',1);prepared=self.get(messages,'prepared')
        sound='user-'+'a'*64
        directory=self.path.parent/'library'/sound;directory.mkdir(parents=True);(directory/'audio.wav').write_bytes(b'test');(directory/'metadata.json').write_text(json.dumps({'version':1,'id':sound,'name':'Test','file':'audio.wav','durationMs':1000}))
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':30000,'soundId':sound})
        self.send(p,'command',2,envelope);self.assertTrue(self.get(messages,'result')['success'])
        self.send(p,'delete-sound',3,{'soundId':sound});result=self.get(messages,'result')
        self.assertFalse(result['success']);self.assertEqual(result['error'],'Sound is in use')

    def test_missing_sound_is_rejected_without_modifying_state(self):
        p,messages=self.start(audio=True);self.send(p,'prepare',1);prepared=self.get(messages,'prepared');self.assertFalse(self.path.exists())
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':30000,'soundId':'user-'+'b'*64})
        self.send(p,'command',2,envelope);result=self.get(messages,'result');self.assertFalse(result['success']);self.assertFalse(self.path.exists())

    def test_corrupt_timing_is_not_rewritten_on_open(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p);self.persist_initial(state)
        doc=json.loads(self.path.read_text());doc['timing']['timer']['remainingCheckpointMs']=-1;self.path.write_text(json.dumps(doc));before=self.path.read_bytes()
        result=subprocess.run([str(self.binary),'--prototype','--store',str(self.path)],capture_output=True,text=True,timeout=5)
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.path.read_bytes(),before)

    def test_invalid_saved_settings_are_rejected_without_migration(self):
        for settings in ({'alarms':[{'id':'broken','on':False}]}, {'timerPresets':{'0':{}}}):
            with self.subTest(settings=settings):
                original=json.dumps({'timer':{'state':'idle','total':5000,'left':5000},**settings}).encode()
                self.path.write_bytes(original)
                result=subprocess.run([str(self.binary),'--prototype','--store',str(self.path)],capture_output=True,text=True,timeout=5)
                self.assertNotEqual(result.returncode,0);self.assertEqual(self.path.read_bytes(),original)
                self.assertFalse(list(self.path.parent.glob('clock.before-v2-*.json')))

    def test_enabled_alarm_without_cursor_initializes_evaluation_cursor(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text())
        document['alarms']=[{'id':'a','h':0,'m':0,'on':True,'days':[0,1,2,3,4,5,6]}]
        document['timing'].pop('alarmCursorWallMs',None);document['timing'].pop('alarmCursorBootId',None)
        self.path.write_text(json.dumps(document));p,messages=self.start();self.send(p,'load',2);state=self.get(messages,'state')
        self.assertGreater(state['timing']['alarmCursorWallMs'],0);self.assertEqual(state['timing']['alarmCursorBootId'],state['bootId'])

    def test_preview_stops_when_alert_starts(self):
        p,messages=self.start(audio=True)
        self.send(p,'preview-sound',1,{'soundId':'','kind':'timer'});preview=self.get(messages,'sound-preview');self.assertTrue(preview['playing'])
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.02)
        preview_pid=int(log.read_text().splitlines()[0])
        self.send(p,'prepare',2);prepared=self.get(messages,'prepared')
        envelope=dict(id=prepared['commandId'],bootId=prepared['bootId'],issuedBootMs=prepared['issuedBootMs'],revision=prepared['revision'],action='start',args={'sessionId':prepared['sessionId'],'durationMs':200})
        self.send(p,'command',3,envelope);self.assertTrue(self.get(messages,'result')['success'])
        stopped=self.get(messages,'sound-preview');self.assertFalse(stopped['playing'])
        self.assertFalse(Path('/proc',str(preview_pid)).exists())

    def test_default_preview_prefers_legacy_custom_sound(self):
        builtin=self.path.parent/'builtin';builtin.mkdir();(builtin/'timer.wav').write_bytes(b'builtin')
        script='#!/usr/bin/python3\nimport os,sys,time\nopen(os.environ["TEST_AUDIO"],"a").write(sys.argv[-1]+"\\n")\ntime.sleep(30)\n'
        p,messages=self.start(audio=True,builtin_dir=builtin,player_script=script)
        self.send(p,'preview-sound',1,{'soundId':'','kind':'timer'});self.assertTrue(self.get(messages,'sound-preview')['playing'])
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.02)
        self.assertEqual(log.read_text().splitlines(),[str(self.path.parent/'timer.wav')])

    def test_deleting_previewed_sound_notifies_preview_stopped(self):
        p,messages=self.start(audio=True,builtin_dir=ROOT/'MacShell/sounds');sound='user-'+'a'*64
        directory=self.path.parent/'library'/sound;directory.mkdir(parents=True)
        (directory/'audio.wav').write_bytes(b'test');(directory/'metadata.json').write_text(json.dumps({'version':1,'id':sound,'name':'Test','file':'audio.wav','durationMs':1000}))
        self.send(p,'preview-sound',1,{'soundId':sound});self.assertTrue(self.get(messages,'sound-preview')['playing'])
        self.send(p,'delete-sound',2,{'soundId':sound});self.assertFalse(self.get(messages,'sound-preview')['playing'])
        self.assertEqual(self.get(messages,'sounds')['id'],2)

    def test_service_shutdown_reaps_preview(self):
        p,messages=self.start(audio=True)
        self.send(p,'preview-sound',1,{'soundId':'','kind':'timer'});self.assertTrue(self.get(messages,'sound-preview')['playing'])
        log=self.path.parent/'audio.log';end=time.monotonic()+5
        while not log.exists() and time.monotonic()<end:time.sleep(.02)
        pid=int(log.read_text().splitlines()[0]);self.stop(p)
        self.assertFalse(Path('/proc',str(pid)).exists())

    def test_legacy_snooze_and_ringing_migration_preserves_backup(self):
        now=int(time.time()*1000)
        legacy={'timer':{'state':'idle','total':5000,'left':5000,'label':'Tea'},'snoozes':[{'at':now+120000,'label':'Wake','extra':{'keep':True}}], 'ringing':{'kind':'alarm','label':'Meeting','time':'09:00'},'extension':{'keep':True}}
        original=(json.dumps(legacy,ensure_ascii=False)+'\n').encode();self.path.write_bytes(original)
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state')
        recovered=state['timing']['legacySnoozesRecovery'];self.assertEqual(len(recovered),1)
        self.assertEqual(recovered[0]['legacy']['extra'],{'keep':True});self.assertGreater(recovered[0]['remainingMs'],0)
        self.assertEqual(state['timing']['completion']['label'],'Meeting');self.assertTrue(state['timing']['completion']['soundClaimed'])
        backup=list(self.path.parent.glob('clock.before-v2-*.json'));self.assertEqual(len(backup),1);self.assertEqual(backup[0].read_bytes(),original)
        event=state['timing']['completion']['eventId'];self.stop(p)
        p,messages=self.start();self.send(p,'load',2);again=self.get(messages,'state')
        self.assertEqual(again['timing']['completion']['eventId'],event);self.assertEqual(again['timing']['legacySnoozesRecovery'],recovered)

    def test_invalid_legacy_snooze_is_not_overwritten(self):
        original=b'{"snoozes":[{"at":true}]}'
        self.path.write_bytes(original)
        result=subprocess.run([str(self.binary),'--prototype','--store',str(self.path)],capture_output=True,text=True,timeout=5)
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.path.read_bytes(),original)
        self.assertFalse(list(self.path.parent.glob('clock.before-v2-*.json')))

    def test_version_two_without_stopwatch_is_migrated(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text());document['timing'].pop('stopwatch');document['sw']={'running':False,'startAt':0,'acc':2500,'laps':[1000]};self.path.write_text(json.dumps(document))
        p,messages=self.start();self.send(p,'load',2);state=self.get(messages,'state')
        self.assertEqual(state['timing']['stopwatch']['elapsedCheckpointMs'],2500)
        self.assertEqual(state['timing']['stopwatch']['laps'],[1000])

    def test_alarm_cursor_does_not_write_continuously(self):
        p,messages=self.start();self.send(p,'load',1);state=self.get(messages,'state');self.stop(p)
        self.persist_initial(state);document=json.loads(self.path.read_text());document['alarms']=[{'id':'a','h':0,'m':0,'on':True,'days':[0,1,2,3,4,5,6]}];document['timing']['alarmCursorWallMs']=int(time.time()*1000);document['timing']['alarmCursorBootId']=state['bootId'];self.path.write_text(json.dumps(document))
        p,messages=self.start();self.send(p,'load',2);first=self.get(messages,'state');time.sleep(.7);self.send(p,'load',3);second=self.get(messages,'state')
        self.assertEqual(first['revision'],second['revision'])


if __name__=='__main__':unittest.main()
