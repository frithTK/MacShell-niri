"""Compare the new session locale reader with the current Python contract."""
import os
import concurrent.futures
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'MacShell'))
import locale_preferences as locale
from test_system_stats_rust import Client
from scripts.install_niri import quickshell

BINARY=os.environ.get('MACSHELL_TEST_LOCALE_PREFERENCES_BINARY')

@unittest.skipUnless(BINARY,'Set MACSHELL_TEST_LOCALE_PREFERENCES_BINARY')
class LocaleSessionRustTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.config=self.root/'config'; self.config.mkdir()
        self.path=self.config/'environment.d/90-macshell-locale.conf'; self.path.parent.mkdir()
        fake=self.root/'bin'; fake.mkdir(); command=fake/'locale'
        command.write_text('#!/bin/sh\nprintf "C\\nen_US.utf8\\nru_RU.utf8\\n"\n'); command.chmod(0o755)
        self.env=dict(os.environ,XDG_CONFIG_HOME=str(self.config),HOME=str(self.root),PATH=str(fake)+os.pathsep+os.environ.get('PATH',''))
        self.env.pop('LC_ALL',None)
    def write(self,raw): self.path.write_bytes(raw)
    def run_both(self):
        args=([BINARY,'--session'],[sys.executable,str(ROOT/'scripts/session_locale.py')])
        return [subprocess.run(cmd,env=self.env,capture_output=True,text=True,timeout=7) for cmd in args]
    def compare(self):
        rust,python=self.run_both()
        self.assertEqual(rust.returncode,python.returncode,(rust.stderr,python.stderr))
        self.assertEqual(rust.stdout,python.stdout)
        self.assertEqual(rust.stderr,python.stderr)
    def test_valid_documents_match_and_are_not_modified(self):
        for values in (dict(ui='system',session='system',region='system'),dict(ui='ru',session='C',region='system'),
                       dict(ui='en',session='ru_RU.utf8',region='en_US.utf8'),dict(ui='ru',session='system',region='C')):
            with self.subTest(values=values):
                raw,_=locale.serialize(values,{'C','en_US.utf8','ru_RU.utf8'})
                self.write(raw); self.compare(); self.assertEqual(self.path.read_bytes(),raw)
        self.path.unlink(); self.compare()
    def test_unknown_unsafe_and_inconsistent_documents_are_rejected(self):
        valid,_=locale.serialize(dict(ui='ru',session='C',region='system'),{'C'})
        for raw in (b'',b'LANG=C\n',b'# MacShell locale preferences v2\n',b'\xff',valid+b'PATH=/tmp\n',
                    valid+b'LANG=C\n',valid.replace(b'LANG=C',b'LANG=ru_RU.utf8'),
                    valid.replace(b'LC_MESSAGES=C',b'LC_MESSAGES=$(echo_bad)'),b'x'*16385):
            with self.subTest(raw=raw[:80]):
                self.write(raw); self.compare(); self.assertEqual(self.path.read_bytes(),raw)
    def test_missing_installed_locale_and_lc_all_conflict(self):
        raw,_=locale.serialize(dict(ui='ru',session='de_DE.utf8',region='system'),{'de_DE.utf8'})
        self.write(raw); self.compare()
        raw,_=locale.serialize(dict(ui='ru',session='C',region='system'),{'C'})
        self.write(raw); self.env['LC_ALL']='C'; self.compare()
        raw,_=locale.serialize(dict(ui='ru',session='system',region='system'),set())
        self.write(raw); self.compare()
    def test_symlink_never_follows_or_changes_target(self):
        target=self.root/'external'; target.write_bytes(b'private'); self.path.symlink_to(target)
        self.compare(); self.assertEqual(target.read_bytes(),b'private')
    def test_multiple_line_separators_follow_python_parser(self):
        raw,_=locale.serialize(dict(ui='ru',session='C',region='system'),{'C'})
        for separator in (b'\r\n',b'\r',b'\x0b',b'\xc2\x85',b'\xe2\x80\xa8'):
            with self.subTest(separator=separator):
                altered=raw.replace(b'\n',separator); self.write(altered); self.compare(); self.assertEqual(self.path.read_bytes(),altered)
    def start(self,python=False):
        command=[sys.executable,'-u',str(ROOT/'MacShell/locale_service.py')] if python else [BINARY]
        client=Client(command,env=self.env); self.addCleanup(client.close)
        client.message(lambda m:m.get('type')=='ready'); return client
    def request(self,client,action,data=None):
        client.send({'action':action,'data':data or {},'generation':13,'id':2})
        message=client.message(lambda m:m.get('type') in ('result','state'))
        if message['type']=='result': return None,message
        return message,client.message(lambda m:m.get('type')=='result')
    def test_services_share_documents_tokens_and_backups(self):
        rust=self.start(); python=self.start(True)
        first,result=self.request(rust,'load'); second,_=self.request(python,'load')
        self.assertEqual(first,second); self.assertTrue(result['success'])
        selected={'ui':'ru','session':'ru_RU.utf8','region':'en_US.utf8'}
        after,result=self.request(rust,'save',{'values':selected,'token':first['token']})
        self.assertTrue(result['success']); self.assertEqual(after['values'],selected)
        original=self.path.read_bytes(); self.compare()
        mtime=self.path.stat().st_mtime_ns
        same,result=self.request(rust,'save',{'values':selected,'token':after['token']})
        self.assertTrue(result['success']); self.assertEqual(same,after)
        self.assertEqual(self.path.stat().st_mtime_ns,mtime); self.assertFalse(self.path.with_suffix('.conf.previous').exists())
        _,result=self.request(python,'save',{'values':selected,'token':first['token']}); self.assertEqual(result['code'],'conflict')
        selected['ui']='en'
        after,result=self.request(python,'save',{'values':selected,'token':after['token']})
        self.assertTrue(result['success']); self.assertEqual(self.path.with_suffix('.conf.previous').read_bytes(),original)
        self.assertEqual(self.request(rust,'load')[0],after)
    def test_service_validation_lc_all_missing_and_corruption(self):
        self.env['LC_ALL']='C'; rust=self.start(); python=self.start(True)
        for values in ({'ui':'ru','session':'ru_RU.utf8','region':'system'},
                       {'ui':'ru','session':'missing','region':'system'},
                       {'ui':'ru','session':'C\nPATH=/tmp','region':'system'}):
            a=self.request(rust,'save',{'values':values,'token':'missing'})[1]
            b=self.request(python,'save',{'values':values,'token':'missing'})[1]
            self.assertEqual(a,b); self.assertFalse(self.path.exists())
        for raw in (b'{bad',b'# MacShell locale preferences v2\n',b'\xff'):
            self.write(raw); self.assertEqual(self.request(rust,'load'),self.request(python,'load')); self.assertEqual(self.path.read_bytes(),raw)
        self.path.unlink(); target=self.root/'external'; target.write_bytes(b'kept'); self.path.symlink_to(target)
        self.assertEqual(self.request(rust,'load'),self.request(python,'load')); self.assertEqual(target.read_bytes(),b'kept')
    def test_python_and_rust_race_with_same_token(self):
        a=self.start(); b=self.start(True); first=self.request(a,'load')[0]; self.assertEqual(first,self.request(b,'load')[0])
        def save(pair):
            client,language=pair
            return self.request(client,'save',{'values':{'ui':language,'session':'system','region':'system'},'token':first['token']})[1]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(save,[(a,'en'),(b,'ru')]))
        self.assertEqual(sum(bool(r['success']) for r in results),1)
        self.assertEqual(sum(r.get('code')=='conflict' for r in results),1)
        self.compare()
    def test_missing_locale_can_be_replaced_and_registry_refreshes(self):
        raw,_=locale.serialize(dict(ui='ru',session='de_DE.utf8',region='system'),{'de_DE.utf8'})
        self.write(raw); rust=self.start(); python=self.start(True)
        state,result=self.request(rust,'load'); self.assertTrue(result['success']); self.assertEqual(state,self.request(python,'load')[0])
        self.assertEqual(state['missing'],['de_DE.utf8']); self.compare()
        # Registry is queried again for every save, including an already-open dialog.
        registry=self.root/'bin/locale'; registry.write_text('#!/bin/sh\nprintf "C\\n"\n'); registry.chmod(0o755)
        _,result=self.request(rust,'save',{'values':{'ui':'en','session':'ru_RU.utf8','region':'system'},'token':state['token']})
        self.assertEqual(result['code'],'locale_missing'); self.assertEqual(self.path.read_bytes(),raw)
        after,result=self.request(rust,'save',{'values':{'ui':'en','session':'C','region':'system'},'token':state['token']})
        self.assertTrue(result['success']); self.assertEqual(after['missing'],[]); self.compare()
    def test_lock_symlink_and_inconsistent_assignments_are_never_overwritten(self):
        rust=self.start(); target=self.root/'other'; target.write_bytes(b'private')
        lock=self.path.with_suffix('.lock'); lock.symlink_to(target)
        _,result=self.request(rust,'save',{'values':{'ui':'ru','session':'system','region':'system'},'token':'missing'})
        self.assertEqual(result['code'],'io_error'); self.assertEqual(target.read_bytes(),b'private'); self.assertFalse(self.path.exists())
        lock.unlink()
        raw,_=locale.serialize(dict(ui='ru',session='C',region='system'),{'C'})
        bad=raw.replace(b'LANG=C',b'LANG=ru_RU.utf8'); self.write(bad)
        _,result=self.request(rust,'save',{'values':{'ui':'ru','session':'system','region':'system'},'token':locale.token(bad)})
        self.assertEqual(result['code'],'invalid'); self.assertEqual(self.path.read_bytes(),bad)
    def test_registry_timeout_does_not_write(self):
        registry=self.root/'bin/locale'; registry.write_text('#!/bin/sh\nexec /usr/bin/sleep 10\n'); registry.chmod(0o755)
        rust=self.start(); start=time.monotonic()
        _,result=self.request(rust,'load')
        self.assertEqual(result['code'],'locale_query_failed'); self.assertLess(time.monotonic()-start,6)
        self.assertFalse(self.path.exists())
    def test_oversized_generated_document_is_rejected_before_write(self):
        name='a'*3000
        registry=self.root/'bin/locale'; registry.write_text('#!/bin/sh\nprintf "%s\\n" '+name+'\n'); registry.chmod(0o755)
        rust=self.start()
        _,result=self.request(rust,'save',{'values':{'ui':'system','session':'system','region':name},'token':'missing'})
        self.assertEqual(result['code'],'invalid_selection'); self.assertFalse(self.path.exists())
    def test_both_launchers_select_compatible_binary_and_fallback(self):
        folder=self.root/'launchers'; folder.mkdir()
        shutil.copy(ROOT/'MacShell/locale-preferences.sh',folder/'locale-preferences.sh')
        shutil.copy(ROOT/'scripts/session-locale.sh',folder/'session-locale.sh')
        (folder/'locale_service.py').write_text('print("legacy service")\n')
        (folder/'session-locale.py').write_text('print("legacy session")\n')
        binary=folder/'locale-preferences-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-locale-preferences 1"; else echo "rust ${1-service}"; fi\n'); binary.chmod(0o755)
        def launch(name):
            return subprocess.run(['sh',str(folder/name)],env=self.env,capture_output=True,text=True,timeout=5,check=True).stdout.strip()
        self.assertEqual(launch('locale-preferences.sh'),'rust service')
        self.assertEqual(launch('session-locale.sh'),'rust --session')
        binary.write_text('#!/bin/sh\necho incompatible\n')
        self.assertEqual(launch('locale-preferences.sh'),'legacy service')
        self.assertEqual(launch('session-locale.sh'),'legacy session')
    def test_session_fallback_reads_the_same_document(self):
        folder=self.root/'fallback'; folder.mkdir()
        shutil.copy(ROOT/'scripts/session-locale.sh',folder/'session-locale.sh')
        shutil.copy(ROOT/'scripts/session_locale.py',folder/'session-locale.py')
        shutil.copy(ROOT/'MacShell/locale_preferences.py',folder/'locale_preferences.py')
        raw,_=locale.serialize(dict(ui='ru',session='C',region='system'),{'C'}); self.write(raw)
        fallback=subprocess.run(['sh',str(folder/'session-locale.sh')],env=self.env,capture_output=True,text=True,timeout=6,check=True)
        rust=subprocess.run([BINARY,'--session'],env=self.env,capture_output=True,text=True,timeout=6,check=True)
        self.assertEqual(fallback.stdout,rust.stdout); self.assertEqual(self.path.read_bytes(),raw)
    @unittest.skipUnless(shutil.which(quickshell()),'Quickshell is required')
    def test_qml_saves_and_session_reader_exports_same_document(self):
        shell=self.root/'shell'; shutil.copytree(ROOT/'MacShell',shell)
        shutil.copy(ROOT/'tests/locale-preferences-rust.qml',shell/'shell.qml')
        shutil.copy(BINARY,shell/'locale-preferences-rust')
        (shell/'locale_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        for name in ('runtime','cache'): (self.root/name).mkdir()
        (self.root/'runtime').chmod(0o700)
        env=dict(self.env,XDG_RUNTIME_DIR=str(self.root/'runtime'),XDG_CACHE_HOME=str(self.root/'cache'),
                 QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',QT_QUICK_BACKEND='software',
                 DBUS_SESSION_BUS_ADDRESS='unix:path='+str(self.root/'no-bus'))
        env.pop('DISPLAY',None); env.pop('WAYLAND_DISPLAY',None)
        result=subprocess.run([quickshell(),'-p',str(shell)],env=env,capture_output=True,text=True,timeout=16)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('LOCALE_RUST_QML_PASS',result.stdout+result.stderr)
        self.assertEqual(locale.parse(self.path.read_bytes())[0],{'ui':'ru','session':'C','region':'system'})
        self.assertEqual(self.path.stat().st_mode & 0o777,0o600); self.compare()
