import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import wave

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'MacShell'))
from clock_sound_library import SoundLibrary


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'),'ffmpeg required')
class ClockImportRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory(prefix='clock-import-build-');cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(ROOT/'native/clock-core/Cargo.toml'),'--target-dir',cls.build.name,'--bin','clock-sound-import'],check=True,timeout=120)
        cls.binary=Path(cls.build.name)/'debug/clock-sound-import'

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name);self.library=self.root/'library';self.source=self.root/'звук.wav'
        with wave.open(str(self.source),'wb') as output:output.setparams((1,2,8000,0,'NONE','not compressed'));output.writeframes(struct.pack('<8000h',*([300]*8000)))

    def run_import(self,path):
        result=subprocess.run([str(self.binary),'--library',str(self.library),str(path)],capture_output=True,text=True,timeout=20)
        return result,json.loads(result.stdout)

    def test_import_dedup_and_python_compatibility(self):
        result,first=self.run_import(self.source);self.assertEqual(result.returncode,0,first);self.assertTrue(first['created'])
        self.assertEqual(first['sound']['durationMs'],1000)
        result,second=self.run_import(self.source);self.assertEqual(result.returncode,0);self.assertFalse(second['created']);self.assertEqual(first['sound'],second['sound'])
        self.assertEqual(SoundLibrary(self.library).list_imported(),[first['sound']])

    def test_invalid_file_and_cancel_cleanup(self):
        bad=self.root/'bad.wav';bad.write_bytes(b'invalid');result,response=self.run_import(bad)
        self.assertNotEqual(result.returncode,0);self.assertFalse(response['success']);self.assertFalse(list(self.library.glob('.import-*')))
        bindir=self.root/'bin';bindir.mkdir();probe=bindir/'ffprobe';probe.write_text('#!/bin/sh\nexec /usr/bin/sleep 30\n');probe.chmod(0o755)
        env=dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'])
        worker=subprocess.Popen([str(self.binary),'--library',str(self.library),str(self.source)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+5
            while not list(self.library.glob('.import-*')) and time.monotonic()<deadline:time.sleep(.02)
            worker.send_signal(signal.SIGTERM);worker.communicate(timeout=5)
            self.assertFalse(list(self.library.glob('.import-*')))
        finally:
            if worker.poll() is None:worker.kill();worker.communicate()


if __name__=='__main__':unittest.main()
