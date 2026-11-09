import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import unittest
import wave

ROOT=Path(__file__).resolve().parents[1]


class ClockAudioWorkerRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='clock-audio-build-');cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(ROOT/'native/clock-core/Cargo.toml'),'--target-dir',cls.temp.name,'--bin','clock-audio-worker'],check=True,timeout=120)
        cls.binary=Path(cls.temp.name)/'debug/clock-audio-worker'

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg required')
    def test_fragment_and_fade_with_owned_pipe(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'input.wav'
            with wave.open(str(source),'wb') as output:
                output.setparams((1,2,8000,0,'NONE','not compressed'));output.writeframes(struct.pack('<8000h',*([10000]*8000)))
            bindir=root/'bin';bindir.mkdir();player=bindir/'pw-play'
            player.write_text('#!/usr/bin/python3\nimport os,sys\nopen(os.environ["TEST_PCM"],"wb").write(sys.stdin.buffer.read())\n');player.chmod(0o755)
            env=dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'],TEST_PCM=str(root/'output.raw'))
            options={'volume':80,'startMs':100,'durationMs':200,'fadeMs':200,'fadeElapsedMs':0}
            result=subprocess.run([str(self.binary),str(source),json.dumps(options)],env=env,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            data=(root/'output.raw').read_bytes();self.assertEqual(len(data),38400)
            early=struct.unpack('<2880h',data[:5760]);late=struct.unpack('<3840h',data[28800:36480])
            self.assertGreater(sum(map(abs,late))/len(late),sum(map(abs,early))/len(early)*3)

    def test_termination_reaps_owned_children(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);bindir=root/'bin';bindir.mkdir()
            for name in ('ffmpeg','pw-play'):
                tool=bindir/name;tool.write_text('#!/usr/bin/python3\nimport os,time\nopen(os.path.join(os.environ["TEST_PID_DIR"],os.path.basename(__file__)+".pid"),"w").write(str(os.getpid()))\ntime.sleep(30)\n');tool.chmod(0o755)
            env=dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'],TEST_PID_DIR=directory)
            worker=subprocess.Popen([str(self.binary),str(root/'unused.wav'),'{"fadeMs":1000}'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                deadline=time.monotonic()+5
                while not all((root/(name+'.pid')).exists() for name in ('ffmpeg','pw-play')) and time.monotonic()<deadline:time.sleep(.02)
                pids=[int((root/(name+'.pid')).read_text()) for name in ('ffmpeg','pw-play')]
                worker.send_signal(signal.SIGTERM);worker.wait(timeout=5)
                self.assertTrue(all(not Path('/proc',str(pid)).exists() for pid in pids))
            finally:
                if worker.poll() is None:worker.kill();worker.wait()


if __name__=='__main__':unittest.main()
