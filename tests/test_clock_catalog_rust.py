import json
import fcntl
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'MacShell'))
from clock_sound_library import SoundLibrary


class ClockCatalogRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='clock-catalog-build-');cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(ROOT/'native/clock-core/Cargo.toml'),'--target-dir',cls.temp.name,'--example','catalog'],check=True,timeout=120)
        cls.binary=Path(cls.temp.name)/'debug/examples/catalog'

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.library=Path(self.temp.name)/'library';self.sounds=ROOT/'MacShell/sounds'

    def call(self,op,**kwargs):
        result=subprocess.run([str(self.binary),str(self.library),str(self.sounds)],input=json.dumps(dict(op=op,**kwargs))+'\n',capture_output=True,text=True,check=True,timeout=5)
        return json.loads(result.stdout)

    def test_catalog_and_resolve_match_python(self):
        python=SoundLibrary(self.library);expected=python.catalog_state()
        actual=self.call('state');self.assertTrue(actual['success'],actual);self.assertEqual(actual['result'],expected)
        for sound in expected['sounds'][:2]+[{'id':'builtin-chime-01'}]:
            self.assertEqual(self.call('resolve',id=sound['id'])['result'],str(python.resolve(sound['id'])))
        self.assertFalse(self.call('resolve',id='../bad')['success'])

    def test_imported_metadata_and_favorites(self):
        identifier='user-'+'a'*64;directory=self.library/identifier;directory.mkdir(parents=True)
        (directory/'audio.wav').write_bytes(b'x');(directory/'metadata.json').write_text(json.dumps({'version':1,'id':identifier,'name':'Custom','file':'audio.wav','durationMs':1000,'extra':{'keep':True}}))
        (self.library/'favorites.json').write_text(json.dumps({'version':1,'favorites':[identifier],'showBuiltins':True}))
        self.assertEqual(self.call('state')['result'],SoundLibrary(self.library).catalog_state())
        self.assertEqual(self.call('resolve',id=identifier)['result'],str(directory/'audio.wav'))
        (self.library/'favorites.json').write_text('{broken')
        self.assertFalse(self.call('state')['success'])

    def test_updates_preserve_python_metadata_and_honor_lock(self):
        python=SoundLibrary(self.library);python.set_builtins_visible(True)
        favorites=self.library/'favorites.json';document=json.loads(favorites.read_text());document['futureField']={'keep':True};favorites.write_text(json.dumps(document))
        self.assertTrue(self.call('favorite',id='builtin-chime-01',value=True)['success'])
        self.assertIn('builtin-chime-01',json.loads(favorites.read_text())['favorites'])
        self.assertEqual(json.loads(favorites.read_text())['futureField'],{'keep':True})
        python.set_favorite('builtin-chime-01',False)
        self.assertTrue(self.call('visible',value=False)['success'])
        self.assertFalse(python.catalog_state()['showBuiltins'])
        with (self.library/'.lock').open('a+b') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            process=subprocess.Popen([str(self.binary),str(self.library),str(self.sounds)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
            process.stdin.write(json.dumps({'op':'visible','value':True})+'\n');process.stdin.flush()
            time.sleep(.15);self.assertIsNone(process.poll());self.assertFalse(json.loads(favorites.read_text())['showBuiltins'])
            fcntl.flock(lock,fcntl.LOCK_UN)
            self.assertTrue(json.loads(process.stdout.readline())['success'])
            process.communicate(timeout=5)
        self.assertTrue(python.catalog_state()['showBuiltins'])

    def test_rename_and_delete_imported_sound(self):
        identifier='user-'+'b'*64;directory=self.library/identifier;directory.mkdir(parents=True)
        (directory/'audio.wav').write_bytes(b'original')
        (directory/'metadata.json').write_text(json.dumps({'version':1,'id':identifier,'name':'Old','file':'audio.wav','durationMs':1000,'extra':{'keep':True}}))
        self.assertTrue(self.call('rename',id=identifier,name=' Новое имя ')['success'])
        metadata=SoundLibrary(self.library).list_imported()[0]
        self.assertEqual((metadata['name'],metadata['extra']),('Новое имя',{'keep':True}))
        self.assertEqual((directory/'audio.wav').read_bytes(),b'original')
        self.assertFalse(self.call('rename',id=identifier,name='\n')['success'])
        self.assertFalse(self.call('delete',id='builtin-chime-01')['success'])
        self.assertTrue(self.call('delete',id=identifier)['result'])
        self.assertFalse(directory.exists());self.assertEqual(SoundLibrary(self.library).list_imported(),[])


if __name__=='__main__':unittest.main()
