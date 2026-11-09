import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]


class ClockAudioControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='clock-audio-controller-');cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(ROOT/'native/clock-core/Cargo.toml'),'--target-dir',cls.temp.name,'--example','audio'],check=True,timeout=120)
        cls.binary=Path(cls.temp.name)/'debug/examples/audio'

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.sound=self.root/'sound';self.sound.mkdir();self.builtin=self.root/'builtin';self.builtin.mkdir();self.bin=self.root/'bin';self.bin.mkdir()
        for path in (self.sound/'timer.wav',self.builtin/'timer.wav'):path.write_bytes(b'test')
        player=self.bin/'pw-play';player.write_text('#!/bin/sh\nprintf "play\\n" >> "$LOG"\nif [ "$FAIL_FIRST" = 1 ] && [ ! -e "$MARK" ]; then : > "$MARK"; exit 1; fi\nexec /usr/bin/sleep 30\n');player.chmod(0o755)
        self.worker=self.bin/'worker';self.worker.write_text('#!/bin/sh\nexit 1\n');self.worker.chmod(0o755)
        env=dict(os.environ,PATH=str(self.bin),LOG=str(self.root/'log'),MARK=str(self.root/'mark'),FAIL_FIRST='1')
        self.p=subprocess.Popen([str(self.binary),str(self.sound),str(self.builtin),str(self.worker)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        self.addCleanup(self.stop)

    def stop(self):
        if self.p.poll() is None:self.p.terminate()
        self.p.communicate(timeout=5)

    def call(self,op,**fields):
        self.p.stdin.write(json.dumps(dict(op=op,**fields))+'\n');self.p.stdin.flush();return json.loads(self.p.stdout.readline())

    def test_fallback_and_stop_owned_process(self):
        event={'eventId':'a','kind':'timer'}
        first=self.call('start',event=event,boot=1000);self.assertTrue(first['success'])
        for _ in range(100):
            result=self.call('tick',event=event,boot=1100)
            if result['fallback'] and result['pid']:break
            time.sleep(.01)
        self.assertTrue(result['fallback']);pid=result['pid'];self.assertTrue(Path('/proc',str(pid)).exists())
        self.call('stop');self.assertFalse(Path('/proc',str(pid)).exists())

    def test_preview_timeout_and_alert_limit(self):
        self.call('preview',id='x',path=str(self.builtin/'timer.wav'),boot=100)
        self.call('preview-tick',boot=15100)
        event={'eventId':'b','kind':'timer'};result=self.call('start',event=event,boot=20000)
        pid=result['pid'];self.call('tick',event=event,boot=320000)
        self.assertFalse(Path('/proc',str(pid)).exists())

    def test_missing_worker_falls_back_to_builtin_player(self):
        self.worker.unlink()
        event={'eventId':'worker-missing','kind':'timer','soundOptions':{'fadeMs':100}}
        result=self.call('start',event=event,boot=1000)
        self.assertTrue(result['success']);self.assertTrue(result['fallback']);self.assertFalse(result['failed'])
        self.assertIsNotNone(result['pid'])
        self.call('stop')


if __name__=='__main__':unittest.main()
