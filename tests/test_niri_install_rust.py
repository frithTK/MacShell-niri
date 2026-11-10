"""Opt-in installation test: builds Rust and uses only a temporary profile."""
from contextlib import nullcontext
import copy
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import install_niri as installer
from test_niri_rust_compat import FakeNiri, Runner
from test_system_stats_rust import Client
from test_night_shift_rust import Client as NightClient, fake_wlsunset, TRACE
from test_timed_modes_rust import BOOT, request as timed_request
from test_activity_preferences_rust import DEFAULTS as ACTIVITY_DEFAULTS
from test_power import PowerBus
from test_bluez_pair_rust import PairBus
from test_bluetooth_service_rust import RustClient as BluetoothClient
from test_network_session_rust import HoldingBus


@unittest.skipUnless(os.environ.get('MACSHELL_TEST_RUST_INSTALL') == '1', 'Opt-in offline Rust build test')
class RustInstallationTests(unittest.TestCase):
    def test_real_build_install_launch_and_rollback(self):
        with tempfile.TemporaryDirectory(prefix='macshell-install-rust-test-') as directory:
            root = Path(directory); config = root / 'config'; profile = config / 'macshell-niri'
            shell = config / 'quickshell/MacShell-niri'; lock = config / 'quickshell/MacLock-niri'
            paths = dict(CONFIG=config, DATA=root / 'data', BIN=root / 'bin', PROFILE=profile, SHELL=shell,
                         LOCK=lock, NIRI=config / 'niri/config.kdl',
                         SESSION_UNIT=config / 'systemd/user/niri-macshell.service',
                         SHELL_UNIT=config / 'systemd/user/macshell-niri-shell.service')
            shell.mkdir(parents=True); (shell / 'previous.txt').write_text('before')
            lock.mkdir(parents=True); (lock / 'boot-clock-rust').write_text('previous clock')
            with patch.multiple(installer, **paths), patch.object(installer, 'install_guard', side_effect=nullcontext), \
                 patch.object(installer, 'session_active', return_value=False):
                installer.install()
                for service, protocol in (('capture', 'macshell-capture 1'), ('recording', 'macshell-recording 1'), ('network', 'macshell-network 1')):
                    binary = shell / (service + '-service-rust')
                    self.assertTrue(os.access(binary, os.X_OK))
                    check = subprocess.run(['sh', str(shell / (service + '-service.sh')), '--protocol-version'],
                                           capture_output=True, text=True, check=True, timeout=5)
                    self.assertEqual(check.stdout.strip(), protocol)
                input_service = shell / 'niri-input-service.sh'
                self.assertTrue(os.access(input_service, os.X_OK))
                input_binary = shell / 'niri-input-rust'
                self.assertTrue(os.access(input_binary, os.X_OK))
                input_check = subprocess.run([str(input_service), '--protocol-version'],
                                             capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(input_check.stdout.strip(), 'macshell-niri-input 1')
                session_service = shell / 'session-service.sh'
                self.assertTrue(os.access(session_service, os.X_OK))
                session_binary = shell / 'session-service-rust'
                self.assertTrue(os.access(session_binary, os.X_OK))
                protocol = subprocess.run([str(session_binary), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(protocol.stdout.strip(), 'macshell-session-service 1')
                currency = shell / 'currency-fetch-rust'
                self.assertTrue(os.access(currency, os.X_OK))
                currency_check = subprocess.run(['sh', str(shell / 'currency-fetch.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(currency_check.stdout.strip(), 'macshell-currency-fetch 1')
                widget_fetch = shell / 'widget-fetch-rust'
                self.assertTrue(os.access(widget_fetch, os.X_OK))
                widget_check = subprocess.run(['sh', str(shell / 'widget-fetch.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(widget_check.stdout.strip(), 'macshell-widget-fetch 1')
                wallpaper_binary = shell / 'wallpaper-discovery-rust'
                self.assertTrue(os.access(wallpaper_binary, os.X_OK))
                wallpaper_check = subprocess.run(['sh', str(shell / 'wallpaper-discovery.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(wallpaper_check.stdout.strip(), 'macshell-wallpaper-discovery 1')
                notes_binary = shell / 'notes-service-rust'
                self.assertTrue(os.access(notes_binary, os.X_OK))
                notes_check = subprocess.run(['sh', str(shell / 'notes-service.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(notes_check.stdout.strip(), 'macshell-notes-service 1')
                calendar_binary = shell / 'calendar-service-rust'
                self.assertTrue(os.access(calendar_binary, os.X_OK))
                calendar_check = subprocess.run(['sh', str(shell / 'calendar-service.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(calendar_check.stdout.strip(), 'macshell-calendar-service 1')
                reminders_binary = shell / 'reminders-service-rust'
                self.assertTrue(os.access(reminders_binary, os.X_OK))
                reminders_check = subprocess.run(['sh', str(shell / 'reminders-service.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(reminders_check.stdout.strip(), 'macshell-reminders-service 1')
                clock_binary = shell / 'clock-service-prototype-rust'
                self.assertTrue(os.access(clock_binary, os.X_OK))
                clock_check = subprocess.run([str(clock_binary), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(clock_check.stdout.strip(), 'macshell-clock-service 1')
                importer_check = subprocess.run([str(shell / 'clock-sound-import-rust'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(importer_check.stdout.strip(), 'macshell-clock-import 1')
                mirroring_binary = shell / 'screen-mirroring-service-rust'
                airdrop_binary = shell / 'airdrop-service-rust'
                biometric_binary = shell / 'biometric-probe-rust'
                self.assertTrue(os.access(airdrop_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(airdrop_binary), '--protocol-version'], text=True).strip(), 'macshell-airdrop-service 1')
                self.assertTrue(os.access(biometric_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(biometric_binary), '--protocol-version'], text=True).strip(), 'macshell-biometric-probe 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'biometric-probe.sh'), '--protocol-version'], text=True).strip(), 'macshell-biometric-probe 1')
                update_binary = shell / 'update-service-rust'
                self.assertTrue(os.access(update_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(update_binary), '--protocol-version'], text=True).strip(), 'macshell-update-service 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'update-service.sh'), '--protocol-version'], text=True).strip(), 'macshell-update-service 1')
                desktop_source = shell / 'desktop-source-rust'
                self.assertTrue(os.access(desktop_source, os.X_OK))
                self.assertEqual(subprocess.check_output([str(desktop_source), '--protocol-version'], text=True).strip(), 'macshell-desktop-source 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'desktop-source.sh'), '--protocol-version'], text=True).strip(), 'macshell-desktop-source 1')
                preview_binary = shell / 'preview-rust'
                self.assertTrue(os.access(preview_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(preview_binary), '--protocol-version'], text=True).strip(), 'macshell-preview 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'preview.sh'), '--protocol-version'], text=True).strip(), 'macshell-preview 1')
                trash_binary = shell / 'trash-rust'
                self.assertTrue(os.access(trash_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(trash_binary), '--protocol-version'], text=True).strip(), 'macshell-trash 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'trash.sh'), '--protocol-version'], text=True).strip(), 'macshell-trash 1')
                app_menu_binary = shell / 'app-menu-rust'
                self.assertTrue(os.access(app_menu_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(app_menu_binary), '--protocol-version'], text=True).strip(), 'macshell-app-menu 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'app-menu.sh'), '--protocol-version'], text=True).strip(), 'macshell-app-menu 1')
                storage_binary = shell / 'storage-rust'
                self.assertTrue(os.access(storage_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(storage_binary), '--protocol-version'], text=True).strip(), 'macshell-storage 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'storage.sh'), '--protocol-version'], text=True).strip(), 'macshell-storage 1')
                drop_tools_binary = shell / 'drop-tools-rust'
                self.assertTrue(os.access(drop_tools_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(drop_tools_binary), '--protocol-version'], text=True).strip(), 'macshell-drop-tools 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'drop-tools.sh'), '--protocol-version'], text=True).strip(), 'macshell-drop-tools 1')
                file_search_binary = shell / 'file-search-rust'
                self.assertTrue(os.access(file_search_binary, os.X_OK))
                self.assertEqual(subprocess.check_output([str(file_search_binary), '--protocol-version'], text=True).strip(), 'macshell-file-search 1')
                self.assertEqual(subprocess.check_output(['sh', str(shell / 'file-search.sh'), '--protocol-version'], text=True).strip(), 'macshell-file-search 1')
                (shell / 'airdrop_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                airdrop = Client(['sh', str(shell / 'airdrop-service.sh')])
                try:
                    airdrop.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{airdrop.process.pid}/exe').resolve(), airdrop_binary.resolve())
                    airdrop.send({'id': 1, 'generation': 1, 'action': 'status', 'data': {}})
                    self.assertEqual(airdrop.message(lambda message: message.get('type') == 'state')['status'], 'off')
                finally:
                    airdrop.close()
                self.assertTrue(os.access(mirroring_binary, os.X_OK))
                mirroring_check = subprocess.run([str(mirroring_binary), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(mirroring_check.stdout.strip(), 'macshell-screen-mirroring 1')
                (shell / 'screen_mirroring.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                mirroring = Client(['sh', str(shell / 'screen-mirroring-service.sh')])
                try:
                    mirroring.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{mirroring.process.pid}/exe').resolve(), mirroring_binary.resolve())
                    mirroring.send({'id': 1, 'generation': 1, 'action': 'watch', 'data': {'enabled': False}})
                    self.assertEqual(mirroring.message(lambda message: message.get('type') == 'state')['senderState'], 'off')
                finally:
                    mirroring.close()
                clock_store = root / 'clock-check/clock.json'
                (shell / 'clock_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                clock = Client(['sh', str(shell / 'clock-service.sh'), '--store', str(clock_store)])
                try:
                    clock.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{clock.process.pid}/exe').resolve(), clock_binary.resolve())
                    clock.send({'id': 1, 'generation': 1, 'action': 'prepare', 'data': {}})
                    prepared = clock.message(lambda message: message.get('type') == 'prepared')
                    self.assertFalse(clock_store.exists())
                    envelope = dict(id=prepared['commandId'], bootId=prepared['bootId'],
                                    issuedBootMs=prepared['issuedBootMs'], revision=prepared['revision'],
                                    action='start', args={'sessionId': prepared['sessionId'], 'durationMs': 30000})
                    clock.send({'id': 2, 'generation': 1, 'action': 'command', 'data': envelope})
                    self.assertTrue(clock.message(lambda message: message.get('type') == 'result')['success'])
                    self.assertEqual(json.loads(clock_store.read_text())['timing']['timer']['state'], 'running')
                finally:
                    clock.close()
                fake_network = HoldingBus()
                network = Client(['sh', str(shell / 'network-service.sh')],
                                 env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=fake_network.address))
                try:
                    network.message(lambda message: message.get('type') == 'state')
                    self.assertEqual(Path(f'/proc/{network.process.pid}/exe').resolve(), (shell / 'network-service-rust').resolve())
                    network.send({'id': 1, 'generation': 1, 'action': 'join', 'data': {'network': fake_network.ap}})
                    self.assertTrue(fake_network.entered.wait(4))
                    network.send({'id': 2, 'generation': 1, 'action': 'cancel', 'data': {'request': 1}})
                    fake_network.release_activation()
                    result = network.message(lambda message: message.get('type') == 'result', timeout=8)
                    self.assertEqual(result['state'], 'canceled')
                    self.assertEqual(fake_network.deactivations, [fake_network.active_path])
                finally:
                    fake_network.release_activation()
                    network.close(); fake_network.close()
                installed = shell / 'niri-bridge-rust'
                self.assertTrue(os.access(installed, os.X_OK))
                clock = lock / 'boot-clock-rust'
                self.assertTrue(os.access(clock, os.X_OK))
                (lock / 'boot_clock.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                sample = subprocess.run(['sh', str(lock / 'boot-clock.sh'), '--once'],
                                        capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(json.loads(sample.stdout)['bootId'],
                                 Path('/proc/sys/kernel/random/boot_id').read_text().strip())
                (shell / 'boot_clock.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                shell_sample = subprocess.run(['sh', str(shell / 'boot-clock.sh'), '--once'],
                                              capture_output=True, text=True, check=True, timeout=5)
                self.assertEqual(json.loads(shell_sample.stdout)['bootId'],
                                 Path('/proc/sys/kernel/random/boot_id').read_text().strip())
                stats = shell / 'system-stats-rust'
                self.assertTrue(os.access(stats, os.X_OK))
                (shell / 'system_stats.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                sampler = Client(['sh', str(shell / 'system-stats.sh')])
                try:
                    sampler.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{sampler.process.pid}/exe').resolve(), stats.resolve())
                    sample = sampler.message(lambda message: message.get('type') == 'sample')
                    self.assertGreater(sample['memory']['total'], 0)
                finally:
                    sampler.close()
                night_binary = shell / 'night-shift-rust'
                self.assertTrue(os.access(night_binary, os.X_OK))
                (shell / 'night_shift.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                fake_bin = root / 'fake-bin'; fake_bin.mkdir(); fake_wlsunset(fake_bin, TRACE)
                night = NightClient(['sh', str(shell / 'night-shift.sh')], {
                    'PATH': str(fake_bin) + os.pathsep + os.environ.get('PATH', ''),
                    'NIGHT_TEST_STARTS': str(root / 'night-starts')})
                try:
                    night.wait(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{night.process.pid}/exe').resolve(), night_binary.resolve())
                    night.send(enabled=True, temperature=4000)
                    self.assertEqual(night.wait(lambda message: message.get('state') == 'on')['appliedTemperature'], 4000)
                finally:
                    night.close()
                timed_binary = shell / 'timed-modes-rust'
                self.assertTrue(os.access(timed_binary, os.X_OK))
                (shell / 'timed_modes.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                timed_env = dict(os.environ, MACSHELL_SESSION_TOKEN='install-test')
                timed = Client(['sh', str(shell / 'timed-modes.sh')], env=timed_env)
                try:
                    timed.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{timed.process.pid}/exe').resolve(), timed_binary.resolve())
                    timed.send(timed_request('restore', {'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'install-test'}}))
                    state = timed.message(lambda message: message.get('type') == 'state')
                    self.assertTrue(state['sessionKnown'])
                    self.assertEqual(state['values']['awake']['mode'], 'manual')
                finally:
                    timed.close()
                activity_binary = shell / 'activity-preferences-rust'
                self.assertTrue(os.access(activity_binary, os.X_OK))
                (shell / 'activity_preferences_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                activity_home = root / 'activity-settings'
                activity = Client(['sh', str(shell / 'activity-preferences.sh')],
                                  env=dict(os.environ, MACSHELL_SETTINGS_HOME=str(activity_home)))
                try:
                    activity.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{activity.process.pid}/exe').resolve(), activity_binary.resolve())
                    activity.send({'action': 'load', 'data': {}, 'generation': 1, 'id': 1})
                    state = activity.message(lambda message: message.get('type') == 'state')
                    activity.send({'action': 'commit', 'data': {'values': dict(ACTIVITY_DEFAULTS, cpuWarning=42),
                                                                'token': state['token']}, 'generation': 1, 'id': 2})
                    updated = activity.message(lambda message: message.get('type') == 'state')
                    self.assertEqual(updated['values']['cpuWarning'], 42)
                    self.assertTrue(activity.message(lambda message: message.get('type') == 'result')['success'])
                    self.assertEqual(json.loads((activity_home / 'macbar/activity-appearance.json').read_text())['values']['cpuWarning'], 42)
                finally:
                    activity.close()
                bar_binary = shell / 'bar-preferences-rust'
                self.assertTrue(os.access(bar_binary, os.X_OK))
                (shell / 'bar_layout_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                bar_home = root / 'bar-settings'
                bar = Client(['sh', str(shell / 'bar-preferences.sh')],
                             env=dict(os.environ, MACSHELL_SETTINGS_HOME=str(bar_home)))
                try:
                    bar.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{bar.process.pid}/exe').resolve(), bar_binary.resolve())
                    bar.send({'action': 'load', 'data': {}, 'generation': 1, 'id': 1})
                    state = bar.message(lambda message: message.get('type') == 'state')
                    values = copy.deepcopy(state['values'])
                    next(item for item in values['common'] if item['type'] == 'clock')['enabled'] = False
                    bar.send({'action': 'commit', 'data': {'values': values, 'token': state['token']}, 'generation': 1, 'id': 2})
                    updated = bar.message(lambda message: message.get('type') == 'state')
                    self.assertFalse(next(item for item in updated['values']['common'] if item['type'] == 'clock')['enabled'])
                    self.assertTrue(bar.message(lambda message: message.get('type') == 'result')['success'])
                    data = json.loads((bar_home / 'macbar/layout.json').read_text())
                    self.assertFalse(next(item for item in data['values']['common'] if item['type'] == 'clock')['enabled'])
                finally:
                    bar.close()
                widget_binary = shell / 'widget-preferences-rust'
                self.assertTrue(os.access(widget_binary, os.X_OK))
                (shell / 'widget_layout_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                widget_home = root / 'widget-settings'
                widget = Client(['sh', str(shell / 'widget-preferences.sh')],
                                env=dict(os.environ, MACSHELL_SETTINGS_HOME=str(widget_home)))
                try:
                    widget.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{widget.process.pid}/exe').resolve(), widget_binary.resolve())
                    widget.send({'action': 'load', 'data': {}, 'generation': 1, 'id': 1})
                    state = widget.message(lambda message: message.get('type') == 'state')
                    values = copy.deepcopy(state['values']); values['enabled'] = False
                    widget.send({'action': 'commit', 'data': {'values': values, 'token': state['token']}, 'generation': 1, 'id': 2})
                    self.assertFalse(widget.message(lambda message: message.get('type') == 'state')['values']['enabled'])
                    self.assertTrue(widget.message(lambda message: message.get('type') == 'result')['success'])
                    self.assertFalse(json.loads((widget_home / 'macwidgets/settings.json').read_text())['values']['enabled'])
                finally:
                    widget.close()
                locale_binary = shell / 'locale-preferences-rust'
                self.assertTrue(os.access(locale_binary, os.X_OK))
                (shell / 'locale_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                locale_config = root / 'locale-settings'
                locale_env = dict(os.environ, XDG_CONFIG_HOME=str(locale_config), HOME=str(root))
                locale_env.pop('LC_ALL', None)
                locale_client = Client(['sh', str(shell / 'locale-preferences.sh')], env=locale_env)
                try:
                    locale_client.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{locale_client.process.pid}/exe').resolve(), locale_binary.resolve())
                    locale_client.send({'action': 'load', 'data': {}, 'generation': 1, 'id': 1})
                    state = locale_client.message(lambda message: message.get('type') == 'state')
                    locale_client.message(lambda message: message.get('type') == 'result')
                    values = {'ui': 'ru', 'session': 'C', 'region': 'system'}
                    locale_client.send({'action': 'save', 'data': {'values': values, 'token': state['token']}, 'generation': 1, 'id': 2})
                    self.assertEqual(locale_client.message(lambda message: message.get('type') == 'state')['values'], values)
                    self.assertTrue(locale_client.message(lambda message: message.get('type') == 'result')['success'])
                finally:
                    locale_client.close()
                real_run = subprocess.run
                def no_daemon_reload(command, **kwargs):
                    if command[:3] == ['systemctl', '--user', 'daemon-reload'] or command[0] == 'desktop-file-validate':
                        return subprocess.CompletedProcess(command, 0)
                    return real_run(command, **kwargs)
                preflight_binary = shell / 'session-preflight-rust'
                self.assertTrue(os.access(preflight_binary, os.X_OK))
                with patch.object(installer.subprocess, 'run', side_effect=no_daemon_reload):
                    installer.session_files(locale_binary, preflight_binary)
                (profile / 'session-locale.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                session_result = subprocess.run(['sh', str(profile / 'session-locale.sh')], env=locale_env,
                                                capture_output=True, text=True, timeout=6, check=True)
                self.assertIn('LANG=C\n', session_result.stdout)
                self.assertIn('LC_MESSAGES=C\n', session_result.stdout)
                (profile / 'session-preflight.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                preflight_dir = root / 'preflight-bin'; preflight_dir.mkdir()
                import shutil
                for name in ('niri', 'qs'):
                    shutil.copy(installer.SOURCE / 'tests/fixtures/session_preflight_probe.py', preflight_dir / name)
                    (preflight_dir / name).chmod(0o755)
                fake_config = root / 'preflight-config.kdl'; fake_config.write_text('layout { gaps 10; }\n')
                preflight_env = dict(os.environ, PREFLIGHT_TEST_ROOT=str(root), TMPDIR=str(root),
                                     PATH=str(preflight_dir) + os.pathsep + os.environ.get('PATH', ''))
                preflight_result = subprocess.run(['sh', str(profile / 'session-preflight.sh'), str(fake_config), str(preflight_dir / 'qs')],
                                                  env=preflight_env, capture_output=True, text=True, timeout=15, check=True)
                self.assertIn('Quickshell runtime are ready', preflight_result.stdout)
                self.assertEqual(json.loads((root / 'qs-call.json').read_text())['qpa'], 'offscreen')
                blur_binary = shell / 'native-blur-rust'
                self.assertTrue(os.access(blur_binary, os.X_OK))
                (shell / 'native_blur.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                blur_profile = root / 'blur-profile'; blur_profile.mkdir()
                blur_config = blur_profile / 'config.kdl'
                blur_config.write_text('include "./user.kdl"\n')
                (blur_profile / 'user.kdl').write_text('layout { gaps 10; }\n')
                blur_socket = root / 'blur-niri.sock'; fake_bin = root / 'blur-bin'; fake_bin.mkdir()
                shutil.copy(installer.SOURCE / 'tests/fixtures/native_blur_validator.py', fake_bin / 'niri')
                (fake_bin / 'niri').chmod(0o755)
                server = subprocess.Popen([sys.executable, '-u', str(installer.SOURCE / 'tests/fixtures/native_blur_niri.py'),
                                           '--config', str(blur_config), '--socket', str(blur_socket)],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    self.assertEqual(server.stdout.readline().strip(), 'ready')
                    blur_env = dict(os.environ, MACSHELL_NIRI_PROFILE=str(blur_profile), NIRI_SOCKET=str(blur_socket),
                                    BLUR_TEST_PROFILE=str(blur_profile), PATH=str(fake_bin) + os.pathsep + os.environ.get('PATH', ''))
                    blur = Client(['sh', str(shell / 'native-blur.sh')], env=blur_env)
                    try:
                        blur.message(lambda message: message.get('type') == 'ready')
                        self.assertEqual(Path(f'/proc/{blur.process.pid}/exe').resolve(), blur_binary.resolve())
                        blur.send({'action': 'apply', 'data': {'level': 32}, 'generation': 1, 'id': 1})
                        self.assertEqual(blur.message(lambda message: message.get('type') == 'state')['level'], 32)
                        self.assertIn('// Level: 32', (blur_profile / 'macshell-blur.kdl').read_text())
                    finally:
                        blur.close()
                finally:
                    server.terminate(); server.wait(timeout=5); server.stdout.close(); server.stderr.close()
                power_binary = shell / 'power-profiles-rust'
                self.assertTrue(os.access(power_binary, os.X_OK))
                (shell / 'power_control.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                fake_power = PowerBus()
                power = Client(['sh', str(shell / 'power-profiles.sh')],
                               env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=fake_power.address))
                try:
                    power.message(lambda message: message.get('type') == 'ready')
                    self.assertEqual(Path(f'/proc/{power.process.pid}/exe').resolve(), power_binary.resolve())
                    power.message(lambda message: message.get('type') == 'state' and message.get('profile') == 'balanced')
                    power.send({'action': 'select', 'data': {'profile': 'power-saver'}, 'generation': 1, 'id': 1})
                    selected = power.message(lambda message: message.get('type') == 'state' and not message.get('busy') and message.get('profile') == 'power-saver')
                    self.assertTrue(selected['available'])
                finally:
                    power.close(); fake_power.close()
                bluetooth_binary = shell / 'bluetooth-service-rust'
                self.assertTrue(os.access(bluetooth_binary, os.X_OK))
                (shell / 'bluetooth_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                fake_bluetooth = PairBus()
                bluetooth = BluetoothClient(fake_bluetooth.address, command=['sh', str(shell / 'bluetooth-service.sh')])
                try:
                    bluetooth.wait(lambda m: m.get('type') == 'state' and m.get('pairingAvailable'))
                    self.assertEqual(Path(f'/proc/{bluetooth.process.pid}/exe').resolve(), bluetooth_binary.resolve())
                    request = bluetooth.send('pair', path=fake_bluetooth.device)
                    prompt = bluetooth.wait(lambda m: m.get('type') == 'prompt' and m.get('prompt'))['prompt']
                    bluetooth.send('respond', prompt=prompt['id'], accept=True)
                    self.assertTrue(bluetooth.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)['ok'])
                    self.assertTrue(fake_bluetooth.props[(fake_bluetooth.device, 'org.bluez.Device1')]['Trusted'].unpack())
                finally:
                    bluetooth.close(); fake_bluetooth.close()
                color_binary = shell / 'niri-color-rust'
                self.assertTrue(os.access(color_binary, os.X_OK))
                (shell / 'niri_tools.py').write_text('raise SystemExit("unexpected Python fallback")\n')
                color_bin = root / 'color-bin'; color_bin.mkdir()
                for name in ('niri', 'wl-copy', 'notify-send'):
                    shutil.copy(installer.SOURCE / 'tests/fixtures/niri_color_program.py', color_bin / name)
                    (color_bin / name).chmod(0o755)
                color_env = dict(os.environ, COLOR_TEST_ROOT=str(root), COLOR_REPLY='{"rgb":[0.2,0.5,1]}',
                                 PATH=str(color_bin) + os.pathsep + os.environ.get('PATH', ''))
                subprocess.run(['sh', str(shell / 'niri-color.sh')], env=color_env,
                               capture_output=True, text=True, timeout=8, check=True)
                events = [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines()]
                self.assertEqual([event['program'] for event in events], ['niri', 'wl-copy', 'notify-send'])
                self.assertEqual(events[1]['args'], ['#3380FF'])
                address = str(root / 'fake.sock'); server = FakeNiri(address)
                with patch.dict(os.environ, {'MACSHELL_NIRI_BRIDGE_BACKEND': 'rust'}):
                    runner = Runner(['sh', str(shell / 'niri-bridge.sh')], address)
                try:
                    runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1)
                    self.assertIsNotNone(runner.session)
                    self.assertEqual(Path(f'/proc/{runner.process.pid}/exe').resolve(), installed.resolve())
                    command = {'Action': {'FocusWindow': {'id': 42}}}
                    runner.command(command)
                    self.assertEqual(server.actions.get(timeout=3), command)
                finally:
                    runner.close(); server.close()
                directory = Path((installer.DATA / 'latest').read_text())
                installer.restore(directory, json.loads((directory / 'manifest.json').read_text()))
                self.assertEqual((shell / 'previous.txt').read_text(), 'before')
                self.assertFalse(installed.exists())
                self.assertEqual(clock.read_text(), 'previous clock')


if __name__ == '__main__': unittest.main()
