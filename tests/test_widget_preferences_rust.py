"""Compare widget backends using isolated temporary settings only."""
import concurrent.futures
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from widget_layout import Preferences, defaults, migrate
from test_system_stats_rust import Client
from scripts.install_niri import quickshell

BINARY = os.environ.get('MACSHELL_TEST_WIDGET_PREFERENCES_BINARY')
ORIGIN = {'name': 'DP-1', 'make': 'Demo', 'model': 'Display', 'serial': 'one', 'width': 1920, 'height': 1080}

@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_WIDGET_PREFERENCES_BINARY')
class WidgetPreferencesRustTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.path = self.root / 'macwidgets/settings.json'
        self.path.parent.mkdir(parents=True)
    def start(self, python=False):
        command = [sys.executable, '-u', str(ROOT / 'MacShell/widget_layout_service.py')] if python else [BINARY]
        client = Client(command, env=dict(os.environ, MACSHELL_SETTINGS_HOME=str(self.root)))
        self.addCleanup(client.close); client.message(lambda m: m.get('type') == 'ready'); return client
    def load(self, client, origin=ORIGIN):
        client.send({'action':'load', 'data':{'origin':origin}, 'generation':8, 'id':1})
        return client.message(lambda m: m.get('type') == 'state')
    def commit(self, client, state, values=None, recover=False):
        client.send({'action':'recover' if recover else 'commit', 'data':{'token':state['token'], 'values': values if values is not None else state['values']}, 'generation':8, 'id':2})
        after = client.message(lambda m: m.get('type') == 'state')
        result = client.message(lambda m: m.get('type') == 'result')
        return after, result
    def write(self, value): self.path.write_text(json.dumps(value,ensure_ascii=False))
    def legacy(self):
        return {'tempUnit':'F','cityName':'Тест','style':'normal','future':{'large':10**70}, 'widgets':[
            {'id':'same','type':'calendar','size':'medium','x':42,'y':56,'custom':False},
            {'id':'same','type':'clock','style':'dark','x':456,'y':56},
            {'id':7,'type':'future','version':4,'position':{'x':1}}]}
    def test_legacy_migration_matches_python_and_binds_once(self):
        original = self.legacy(); self.write(original); raw = self.path.read_bytes()
        expected = Preferences(self.path, ORIGIN).load()['values']
        rust = self.start(); state = self.load(rust)
        self.assertEqual(state['values'],expected); self.assertFalse(state['migrationPending'])
        self.assertEqual(next(self.path.parent.glob('settings.before-v1-*.json')).read_bytes(),raw)
        self.assertEqual(json.loads(self.path.read_text())['widgets'], original['widgets'])
        self.assertEqual(self.load(rust, dict(ORIGIN,name='HDMI-1'))['values'],expected)
        self.assertEqual(self.load(rust, {})['values'],expected)
    def test_legacy_ids_and_record_extensions_match_python(self):
        rust = self.start()
        variants = [
            [{'id': 10**30, 'type': 'agenda'}, {'id': 1.0, 'type': 'clock', 'x': -2.5}],
            [{'id': 1e20, 'type': 'agenda'}, {'id': 1e-5, 'type': 'clock'}],
            [{'id': 'x', 'type': 'agenda', 'version': 99, 'output': 'original', 'settings': {'future': True}}],
            [{'id': 'w0', 'type': 'clock'}, {'type': 'clock'}, {'id': 'w1', 'type': 'clock'}],
            [{'id': 'w1', 'type': 'clock'}, {'id': True, 'type': 'clock'}],
            [{'id': 'w1', 'type': 'clock'}, {'id': '', 'type': 'clock'}],
            [{'id': 'w1', 'type': 'clock'}, {'id': [], 'type': 'clock'}],
        ]
        for records in variants:
            with self.subTest(records=records):
                self.write({'widgets': records})
                expected=Preferences(self.path,ORIGIN).load()['values']
                self.assertEqual(self.load(rust)['values'],expected)
    def test_ambiguous_composite_legacy_id_is_not_automatically_rewritten(self):
        rust=self.start()
        self.write({'widgets':[{'id':'w1','type':'clock'},{'id':['legacy'],'type':'clock'}]})
        before=self.path.read_bytes(); state=self.load(rust)
        self.assertTrue(state['readOnly']); self.assertEqual(self.path.read_bytes(),before)
    def test_wait_for_display_and_corrupt_or_future(self):
        rust = self.start(); python = self.start(True)
        self.write(self.legacy()); raw = self.path.read_bytes()
        self.assertEqual(self.load(rust, {}),self.load(python, {}))
        state = self.load(rust, {}); self.assertTrue(state['awaitingDisplay']); self.assertFalse(state['canRecover'])
        self.assertFalse(self.commit(rust,state)[1]['success']); self.assertEqual(raw,self.path.read_bytes())
        for content in (b'{broken', b'{"version":99,"future":[]}', b'\xff', b'x'*262145):
            self.path.write_bytes(content); self.assertEqual(self.load(rust),self.load(python)); self.assertEqual(self.path.read_bytes(),content)
    def test_current_documents_and_validation_match_python(self):
        rust = self.start(); python = self.start(True)
        base = migrate(self.legacy(),ORIGIN)
        variations = [base, dict(base,enabled=False),dict(base,enabled=True),dict(base,enabled=0),
          dict(base,outputs=[]),dict(base,bindings={'DP-1':'missing'}),dict(base,desktopOutput='missing'),
          dict(base,defaults={'styles':False}),dict(base,widgets=[False]),dict(base,widgets=[{}]*257)]
        future=copy.deepcopy(base); future['widgets'].append({'id':'future','type':'clock','version':10**70,'newShape':[False,0]}); variations.append(future)
        for kind, options in [('activity',[{}, {'metrics':['cpu','cpu']}, {'metrics':['gpu']}, {'view':'graphs'}]),
                              ('batteries',[{}, {'devices':['bluetooth:AA:BB:CC:DD:EE:01']}, {'devices':['laptop','laptop']}, {'devices':['bluetooth:aa:bb:cc:dd:ee:01']}]),
                              ('timer',[{}, {'presets':[1,25,1440]}, {'presets':[1,2,True]}, {'presets':[0,2,3]}])]:
            for option in options:
                value=copy.deepcopy(base); value['widgets'][0]['type']=kind; value['widgets'][0]['settings'][kind]=option; variations.append(value)
        for option in ({'textScale':True},{'textScale':1.2},{'fontFamily':'bad\nfont'},{'tint':'#fff000'},{'secondsMode':'fast'}):
            value=copy.deepcopy(base); value['widgets'][0]['settings']['appearance']=option; variations.append(value)
        for values in variations:
            with self.subTest(values=values):
                self.write({'version':1,'revision':4,'values':values}); before=self.path.read_bytes()
                self.assertEqual(self.load(rust),self.load(python)); self.assertEqual(before,self.path.read_bytes())
    def test_cross_backend_edits_optional_fields_and_conflict(self):
        rust=self.start(); python=self.start(True); a=self.load(rust); b=self.load(python)
        values=copy.deepcopy(a['values']); values['enabled']=False
        after,result=self.commit(rust,a,values); self.assertTrue(result['success']); self.assertFalse(after['values']['enabled'])
        _,result=self.commit(python,b,b['values']); self.assertTrue(result['conflict'])
        values=copy.deepcopy(after['values']); del values['enabled']; values['defaults']['cityName']='Москва'
        after,result=self.commit(python,after,values); self.assertTrue(result['success']); self.assertNotIn('enabled',after['values'])
        self.assertEqual(self.load(rust)['values'],after['values'])
    def test_invalid_records_recovery_preserves_original(self):
        rust=self.start(); base=migrate(self.legacy(),ORIGIN); base['widgets'][0]['position']['row']=True
        self.write({'version':1,'values':base}); raw=self.path.read_bytes(); state=self.load(rust)
        self.assertTrue(state['readOnly']); self.assertTrue(state['canRecover'])
        self.assertFalse(self.commit(rust,state)[1]['success']); self.assertEqual(self.path.read_bytes(),raw)
        state,result=self.commit(rust,state,recover=True); self.assertTrue(result['success']); self.assertEqual(state['values']['widgets'],[])
        self.assertEqual(next(self.path.parent.glob('settings.recovery-*.json')).read_bytes(),raw)
    def test_two_writers_only_one_succeeds(self):
        a=self.start(); b=self.start(); first=self.load(a); second=self.load(b)
        def save(pair):
            client,state,value=pair; candidate=copy.deepcopy(state['values']); candidate['enabled']=value
            return self.commit(client,state,candidate)[1]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(save,[(a,first,True),(b,second,False)]))
        self.assertEqual(sum(bool(r['success']) for r in results),1); self.assertEqual(sum(bool(r.get('conflict')) for r in results),1)
    def test_python_and_rust_race_to_migrate_only_once(self):
        self.write(self.legacy()); raw=self.path.read_bytes()
        a=self.start(); b=self.start(True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda pair:self.load(*pair),[(a,ORIGIN),(b,dict(ORIGIN,name='HDMI-1'))]))
        document=json.loads(self.path.read_text())
        self.assertEqual(document['version'],1); self.assertEqual(document['revision'],1)
        profile=document['values']['desktopOutput']; connector=document['values']['outputs'][profile]['identity']['connector']
        self.assertIn(connector,('DP-1','HDMI-1'))
        backups=list(self.path.parent.glob('settings.before-v1-*.json'))
        self.assertEqual(len(backups),1); self.assertEqual(backups[0].read_bytes(),raw)
        self.assertEqual(self.load(a)['values'],self.load(b)['values'])
    def test_launcher_prefers_compatible_rust_and_falls_back(self):
        folder=self.root/'launcher'; folder.mkdir()
        shutil.copy(ROOT/'MacShell/widget-preferences.sh',folder/'widget-preferences.sh')
        (folder/'widget_layout_service.py').write_text('print("legacy")\n')
        binary=folder/'widget-preferences-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-widget-preferences 1"; else echo rust; fi\n'); binary.chmod(0o755)
        def launch(check=True):
            return subprocess.run(['sh',str(folder/'widget-preferences.sh')],capture_output=True,text=True,timeout=5,check=check)
        self.assertEqual(launch().stdout.strip(),'rust')
        binary.write_text('#!/bin/sh\necho incompatible\n')
        incompatible = launch(check=False)
        self.assertNotEqual(incompatible.returncode, 0)
        self.assertNotIn('legacy', incompatible.stdout)
        self.assertIn('Rust', incompatible.stderr)
        binary.unlink()
        missing = launch(check=False)
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotIn('legacy', missing.stdout)
    def test_legacy_home_path_ignores_xdg_config(self):
        home=self.root/'home'; home.mkdir()
        env=dict(os.environ,HOME=str(home),XDG_CONFIG_HOME=str(self.root/'unrelated'))
        env.pop('MACSHELL_SETTINGS_HOME',None)
        client=Client([BINARY],env=env); self.addCleanup(client.close)
        client.message(lambda m:m.get('type')=='ready')
        state=self.load(client); values=copy.deepcopy(state['values']); values['enabled']=True
        self.assertTrue(self.commit(client,state,values)[1]['success'])
        self.assertTrue((home/'.config/macwidgets/settings.json').is_file())
        self.assertFalse((self.root/'unrelated/macwidgets/settings.json').exists())
    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_saves_using_rust_service(self):
        shell=self.root/'shell'; shutil.copytree(ROOT/'MacShell',shell)
        shutil.copy(ROOT/'tests/widget-preferences-rust.qml',shell/'shell.qml')
        shutil.copy(BINARY,shell/'widget-preferences-rust')
        (shell/'widget_layout_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        for name in ('runtime','config','cache'): (self.root/name).mkdir()
        (self.root/'runtime').chmod(0o700)
        env=dict(os.environ,MACSHELL_SETTINGS_HOME=str(self.root),XDG_RUNTIME_DIR=str(self.root/'runtime'),
                 XDG_CONFIG_HOME=str(self.root/'config'),XDG_CACHE_HOME=str(self.root/'cache'),
                 QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',QT_QUICK_BACKEND='software',
                 DBUS_SESSION_BUS_ADDRESS='unix:path='+str(self.root/'no-bus'))
        env.pop('DISPLAY',None); env.pop('WAYLAND_DISPLAY',None)
        result=subprocess.run([quickshell(),'-p',str(shell)],env=env,capture_output=True,text=True,timeout=16)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('WIDGET_RUST_QML_PASS',result.stdout+result.stderr)
        self.assertFalse(json.loads(self.path.read_text())['values']['enabled'])
