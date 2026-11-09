"""Exercise snapshot and restore without touching the user's desktop."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTransactionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='installer-build-')
        cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/installer/Cargo.toml'), '--target-dir', cls.build.name], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/macshell-installer'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='installer-transaction-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.data = self.root / 'data'
        self.data.mkdir()
        self.niri = self.root / 'niri.kdl'
        self.niri.write_text('original')

    def call(self, *args, check=True):
        return subprocess.run([str(self.binary), *map(str, args)], text=True, capture_output=True, check=check, timeout=10)

    def test_doctor_without_python_still_checks_gstreamer(self):
        tools = self.root / 'tools'; tools.mkdir()
        def tool(name, body):
            path = tools / name
            path.write_text('#!/bin/sh\n' + body + '\n')
            path.chmod(0o755)
        for name in ('niri', 'systemctl', 'systemd-run', 'flock', 'qs', 'qsb'):
            tool(name, 'exit 0')
        (tools / 'timeout').symlink_to('/usr/bin/timeout')
        (tools / 'mkdir').symlink_to('/usr/bin/mkdir')
        tool('cargo', '''
while [ "$#" -gt 0 ]; do
    if [ "$1" = --target-dir ]; then target=$2; shift; fi
    shift
done
mkdir -p "$target/release"
printf '#!/bin/sh\\nexit 0\\n' > "$target/release/macshell-session-preflight"
/usr/bin/chmod +x "$target/release/macshell-session-preflight"''')
        tool('gst-inspect-1.0', '[ "$1" != "${MISSING_PLUGIN:-}" ]')
        env = dict(os.environ, HOME=str(self.root), PATH=str(tools), MACSHELL_QS_BIN=str(tools / 'qs'))
        command = [str(self.binary), 'cli', str(ROOT), '--check']
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('Python capture dependencies', result.stdout)
        env['MISSING_PLUGIN'] = 'pipewiresrc'
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ERROR: missing GStreamer element: pipewiresrc', result.stdout)

    def snapshot(self, *paths):
        result = json.loads(self.call('snapshot', self.data, *paths).stdout)
        return Path(result['directory']), result['manifest']

    def test_round_trip_restores_symlinks_modes_and_preserves_post_install_changes(self):
        tree = self.root / 'tree'; tree.mkdir()
        script = tree / 'script'; script.write_bytes(b'original\x00data'); script.chmod(0o751)
        os.utime(script, ns=(1_600_000_000_123_456_789, 1_600_000_000_123_456_789))
        (tree / 'broken').symlink_to('missing')
        absent = self.root / 'new'
        (self.data / 'latest').write_text('old backup\n')
        backup, manifest = self.snapshot(tree, absent)
        self.assertEqual(manifest['previous_latest'], 'old backup\n')
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        script.write_text('modified'); (tree / 'broken').unlink(); absent.write_text('created')
        (self.data / 'latest').write_text(str(backup))
        self.call('restore', self.data, backup, self.niri, 'safe')
        self.assertEqual(script.read_bytes(), b'original\x00data')
        self.assertEqual(script.stat().st_mode & 0o777, 0o751)
        self.assertEqual(script.stat().st_mtime_ns, 1_600_000_000_123_456_789)
        self.assertEqual(os.readlink(tree / 'broken'), 'missing')
        self.assertFalse(absent.exists())
        self.assertEqual((backup / 'after/0/script').read_text(), 'modified')
        self.assertEqual((backup / 'after/1').read_text(), 'created')
        self.assertEqual((self.data / 'latest').read_text(), 'old backup\n')

    def test_refuses_changed_niri_before_modifying_destinations(self):
        import hashlib
        target = self.root / 'target'; target.write_text('before')
        backup, manifest = self.snapshot(target)
        manifest['niri_digest'] = hashlib.sha256(b'original').hexdigest()
        (backup / 'manifest.json').write_text(json.dumps(manifest))
        target.write_text('after'); self.niri.write_text('user edit')
        result = self.call('restore', self.data, backup, self.niri, 'safe', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'after')
        self.call('restore', self.data, backup, self.niri, 'force')
        self.assertEqual(target.read_text(), 'before')

    def test_missing_backup_is_detected_before_any_restore(self):
        first = self.root / 'first'; first.write_text('before 1')
        second = self.root / 'second'; second.write_text('before 2')
        backup, _ = self.snapshot(first, second)
        (backup / 'before/0').unlink()
        first.write_text('after 1'); second.write_text('after 2')
        result = self.call('restore', self.data, backup, self.niri, 'safe', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(first.read_text(), 'after 1')
        self.assertEqual(second.read_text(), 'after 2')

    def test_restores_python_installer_manifest_and_python_restores_rust_manifest(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('scripts.install_niri', ROOT / 'scripts/install_niri.py')
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        target = self.root / 'profile'; target.mkdir()
        (target / 'value').write_text('before')
        with patch.object(installer, 'DATA', self.data), patch.object(installer, 'NIRI', self.niri):
            python_backup, _ = installer.snapshot([target])
            (target / 'value').write_text('updated')
            self.call('restore', self.data, python_backup, self.niri, 'safe')
            self.assertEqual((target / 'value').read_text(), 'before')
            rust_backup, manifest = self.snapshot(target)
            (target / 'value').write_text('updated again')
            installer.restore(rust_backup, manifest)
            self.assertEqual((target / 'value').read_text(), 'before')

    def test_prepare_niri_matches_python_and_never_edits_source_symlink(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('scripts.install_niri', ROOT / 'scripts/install_niri.py')
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        source = self.root / 'niri'; source.mkdir()
        niri = source / 'config.kdl'
        niri.write_text('include "./keys.kdl"\nspawn-sh-at-startup "qs -c noctalia-shell"\n// untouched qs -c noctalia-shell-other\n// repeated qs -c noctalia-shell qs -c noctalia-shell\n')
        external = self.root / 'external.kdl'
        original = 'binds {\n Mod+Space { spawn "qs -c noctalia-shell ipc call launcher toggle"; }\n}\n'
        external.write_text(original); (source / 'keys.kdl').symlink_to(external)
        (source / 'macshell-input.kdl').write_text('// custom input\n')
        profile = self.root / 'profile'; binary_dir = self.root / "bin with 'quote"; binary_dir.mkdir()
        fake_bin = self.root / 'tools'; fake_bin.mkdir()
        validator = fake_bin / 'niri'; validator.write_text('#!/bin/sh\nexit 0\n'); validator.chmod(0o755)
        python_output = self.root / 'python'; rust_output = self.root / 'rust'
        with patch.object(installer, 'NIRI', niri), patch.object(installer, 'PROFILE', profile), patch.object(installer, 'BIN', binary_dir), patch.object(installer, 'validate'):
            self.assertTrue(installer.prepare_niri(python_output))
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ.get('PATH', ''))
        result = subprocess.run([str(self.binary), 'prepare-niri', str(niri), str(profile), str(binary_dir / 'macshell-niri'), str(ROOT / 'config/macshell.kdl'), str(rust_output)], env=env, text=True, capture_output=True, check=True)
        self.assertTrue(json.loads(result.stdout)['previous_shell'])
        for name in ('config.kdl', 'keys.kdl', 'macshell.kdl', 'macshell-input.kdl'):
            self.assertEqual((rust_output / name).read_text(), (python_output / name).read_text(), name)
        self.assertEqual(external.read_text(), original)
        self.assertFalse((rust_output / 'keys.kdl').is_symlink())

    def test_prepare_niri_rejects_invalid_config_and_symlink_cycles(self):
        source = self.root / 'niri'; source.mkdir()
        config = source / 'config.kdl'; config.write_text('invalid')
        tools = self.root / 'tools'; tools.mkdir()
        validator = tools / 'niri'; validator.write_text('#!/bin/sh\nexit 1\n'); validator.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''))
        command = [str(self.binary), 'prepare-niri', str(config), str(self.root / 'profile'), str(self.root / 'bin/macshell-niri'), str(ROOT / 'config/macshell.kdl'), str(self.root / 'out')]
        self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)
        self.assertEqual(config.read_text(), 'invalid')
        (source / 'cycle').symlink_to(source, target_is_directory=True)
        command[-1] = str(self.root / 'out2')
        result = subprocess.run(command, env=env, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'cycle', result.stderr)

    def test_prepare_reuses_installed_profile_and_preserves_input(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('scripts.install_niri', ROOT / 'scripts/install_niri.py')
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        config = self.root / 'config.kdl'; config.write_text('// Original config snapshot: /backup\n')
        profile = self.root / 'profile'; source = profile / 'niri'; source.mkdir(parents=True)
        (source / 'config.kdl').write_text('include "./macshell.kdl"\ninclude "./macshell-input.kdl"\n')
        (source / 'macshell.kdl').write_text('// old generated\n')
        (source / 'macshell-input.kdl').write_text('// custom user settings\n')
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        validator = bin_dir / 'niri'; validator.write_text('#!/bin/sh\nexit 0\n'); validator.chmod(0o755)
        py = self.root / 'py'; rs = self.root / 'rs'
        with patch.object(installer, 'NIRI', config), patch.object(installer, 'PROFILE', profile), patch.object(installer, 'BIN', bin_dir), patch.object(installer, 'validate'):
            self.assertFalse(installer.prepare_niri(py))
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ.get('PATH', ''))
        subprocess.run([str(self.binary), 'prepare-niri', str(config), str(profile), str(bin_dir / 'macshell-niri'), str(ROOT / 'config/macshell.kdl'), str(rs)], env=env, capture_output=True, check=True)
        for name in ('config.kdl', 'macshell.kdl', 'macshell-input.kdl'):
            self.assertEqual((rs / name).read_text(), (py / name).read_text())
        self.assertEqual((source / 'macshell.kdl').read_text(), '// old generated\n')

    def guard_environment(self):
        runtime = self.root / 'runtime'; runtime.mkdir()
        tools = self.root / 'tools'; tools.mkdir()
        qs = tools / 'qs'; qs.write_text('#!/bin/sh\ncase "$*" in *list*) printf "%s\\n" "$TEST_INSTANCES";; *) printf "%s\\n" "$TEST_LOCK";; esac\n'); qs.chmod(0o755)
        systemctl = tools / 'systemctl'; systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_SESSION"\nexit "${TEST_SYSTEMCTL_EXIT:-0}"\n'); systemctl.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''), XDG_RUNTIME_DIR=str(runtime), TEST_INSTANCES='[]', TEST_LOCK='ready', TEST_SESSION='inactive')
        return runtime, qs, env

    def test_guard_rejects_unsafe_and_unknown_states(self):
        _runtime, qs, env = self.guard_environment()
        marker = self.root / 'ran'
        command = [str(self.binary), 'guard-run', str(qs), '--', '/usr/bin/touch', str(marker)]
        for update in ({'TEST_INSTANCES':'[{}]', 'TEST_LOCK':'locked'}, {'TEST_INSTANCES':'malformed'}, {'TEST_SESSION':'active'}, {'TEST_SESSION':'activating'}, {'TEST_SYSTEMCTL_EXIT':'1'}):
            with self.subTest(update=update):
                result = subprocess.run(command, env=dict(env, **update), capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
        subprocess.run(command, env=dict(env, TEST_INSTANCES='[{}]', TEST_LOCK='ready', TEST_SESSION='failed'), check=True, timeout=10)
        self.assertTrue(marker.exists())

    def test_guard_serializes_and_survives_parent_death(self):
        import fcntl
        runtime, qs, env = self.guard_environment()
        started = self.root / 'started'
        first = subprocess.Popen([str(self.binary), 'guard-run', str(qs), '--', '/bin/sh', '-c', 'touch "$1"; sleep 1', 'sh', str(started)], env=env)
        deadline = time.monotonic() + 5
        while not started.exists() and time.monotonic() < deadline: time.sleep(.01)
        self.assertTrue(started.exists())
        first.kill(); first.wait(timeout=3)
        with (runtime / 'macshell-niri-lock.guard').open('a') as lock:
            with self.assertRaises(BlockingIOError): fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            deadline = time.monotonic() + 4
            while True:
                try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break
                except BlockingIOError:
                    if time.monotonic() >= deadline: self.fail('lock not released after child exited')
                    time.sleep(.05)

    def test_guard_propagates_child_failure(self):
        _runtime, qs, env = self.guard_environment()
        result = subprocess.run([str(self.binary), 'guard-run', str(qs), '--', '/bin/sh', '-c', 'exit 42'], env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 42)

    def test_guard_waits_for_existing_maclock_lock_before_checking(self):
        import fcntl
        runtime, qs, env = self.guard_environment()
        marker = self.root / 'ran'
        with (runtime / 'macshell-niri-lock.guard').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = subprocess.Popen([str(self.binary), 'guard-run', str(qs), '--', '/usr/bin/touch', str(marker)], env=env)
            time.sleep(.15)
            self.assertIsNone(child.poll())
            self.assertFalse(marker.exists())
            fcntl.flock(lock, fcntl.LOCK_UN)
            self.assertEqual(child.wait(timeout=5), 0)
        self.assertTrue(marker.exists())

    def test_component_build_plan_and_protocol_failure(self):
        tools = self.root / 'tools'; tools.mkdir()
        cargo = tools / 'cargo'; cargo.write_text((ROOT / 'tests/fixtures/fake_installer_cargo.py').read_text())
        cargo.chmod(0o755)
        log = self.root / 'cargo.log'
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''), FAKE_CARGO_LOG=str(log), MACSHELL_CURRENCY_TEST_API='bad', MACSHELL_WIDGET_TEST_API='bad')
        command = [str(self.binary), 'build-components', str(ROOT), str(self.root / 'build')]
        result = subprocess.run(command, env=env, text=True, capture_output=True, check=True, timeout=30)
        artifacts = json.loads(result.stdout)
        self.assertIn('fingerprint-operation', artifacts)
        self.assertIn('clock-audio-worker', artifacts)
        self.assertIn('macshell-screen-mirroring', artifacts)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(calls), 30)
        self.assertTrue(all('--locked' in call['args'] and '--offline' in call['args'] and '--release' in call['args'] for call in calls))
        self.assertTrue(all(call['currency'] is None and call['widget'] is None for call in calls))
        result = subprocess.run(command, env=dict(env, FAKE_CARGO_BAD_PROTOCOL='fingerprint-operation'), text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('protocol check failed', result.stderr)
        result = subprocess.run(command, env=dict(env, FAKE_CARGO_FAIL='niri-bridge'), text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('build failed', result.stderr)

    def test_session_files_and_launchers_match_python(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('scripts.install_niri', ROOT / 'scripts/install_niri.py')
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        config = self.root / 'config % "quote'; config.mkdir()
        profile = config / 'macshell profile'; profile.mkdir()
        bin_dir = self.root / "bin 'quoted"; bin_dir.mkdir()
        cache = self.root / 'cache'; data = self.root / 'data'
        lock = self.root / 'lock'; qs = self.root / "qs 'test"
        locale = self.root / 'locale'; locale.write_text('locale-binary')
        preflight = self.root / 'preflight'; preflight.write_text('preflight-binary')
        session_unit = config / 'systemd/user/niri-macshell.service'
        shell_unit = config / 'systemd/user/macshell-niri-shell.service'
        patches = dict(PROFILE=profile, BIN=bin_dir, CACHE=cache, DATA=data, LOCK=lock, SESSION_UNIT=session_unit, SHELL_UNIT=shell_unit)
        with patch.multiple(installer, **patches), patch.object(installer, 'quickshell', return_value=str(qs)), patch.object(installer.subprocess, 'run'):
            expected_lock = installer.launcher(True)
            installer.session_files(locale, preflight)
        expected = {str(path.relative_to(self.root)): path.read_bytes() for base in (profile, bin_dir, config / 'systemd', data / 'session') for path in base.rglob('*') if path.is_file()}
        self.call('launchers', profile, bin_dir, cache, lock, qs)
        self.assertEqual((bin_dir / 'maclock-niri').read_text(), expected_lock)
        tools = self.root / 'tools'; tools.mkdir()
        for name in ('systemctl', 'desktop-file-validate'):
            path = tools / name; path.write_text('#!/bin/sh\nexit 0\n'); path.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''))
        subprocess.run([str(self.binary), 'session-files', str(ROOT), str(profile), str(bin_dir), str(data), str(config), str(qs), str(locale), str(preflight)], env=env, capture_output=True, check=True)
        for name, content in expected.items():
            if Path(name).name in ('session-preflight.sh', 'session-ready.sh', 'shell-supervisor.sh', 'session-locale.sh'):
                continue
            self.assertEqual((self.root / name).read_bytes(), content, name)
        for name in ('session-preflight.sh', 'session-ready.sh', 'shell-supervisor.sh', 'session-locale.sh', 'session-preflight-rust', 'locale-preferences-rust'):
            self.assertEqual((profile / name).stat().st_mode & 0o777, 0o755)

    def test_legacy_session_replaces_rust_only_policy(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('scripts.install_niri', ROOT / 'scripts/install_niri.py')
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        config = self.root / 'config'; profile = config / 'macshell-niri'; profile.mkdir(parents=True)
        (profile / '.macshell-rust-only').write_text('1\n')
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        patches = dict(PROFILE=profile, BIN=bin_dir, DATA=self.data,
                       SESSION_UNIT=config / 'systemd/user/niri-macshell.service',
                       SHELL_UNIT=config / 'systemd/user/macshell-niri-shell.service')
        with patch.multiple(installer, **patches), patch.object(installer, 'quickshell', return_value='/bin/true'), patch.object(installer.subprocess, 'run'):
            installer.session_files()
        self.assertFalse((profile / '.macshell-rust-only').exists())
        self.assertTrue((profile / 'shell-supervisor.py').exists())

    def test_full_session_install_and_rollback_and_failed_install(self):
        _runtime, qs, env = self.guard_environment()
        tools = qs.parent
        cargo = tools / 'cargo'; cargo.write_text((ROOT / 'tests/fixtures/fake_installer_cargo.py').read_text()); cargo.chmod(0o755)
        for name in ('niri', 'desktop-file-validate', 'systemd-run', 'flock'):
            path = tools / name; path.write_text('#!/bin/sh\nexit 0\n'); path.chmod(0o755)
        env['FAKE_CARGO_LOG'] = str(self.root / 'cargo.log')
        config = self.root / 'config'; (config / 'niri').mkdir(parents=True)
        (config / 'niri/config.kdl').write_text('// user niri\n')
        shell = config / 'quickshell/MacShell-niri'; shell.mkdir(parents=True); (shell / 'user').write_text('original')
        bin_dir = self.root / 'bin'; cache = self.root / 'cache'
        common = [str(ROOT), str(config), str(cache), str(self.data), str(bin_dir), str(qs)]
        result = subprocess.run([str(self.binary), 'install-profile', *common, 'session'], env=env, capture_output=True, text=True, check=True, timeout=60)
        backup = Path(json.loads(result.stdout)['directory'])
        self.assertTrue((shell / 'fingerprint-operation-rust').exists())
        self.assertTrue((shell / '.macshell-rust-only').is_file())
        self.assertTrue((config / 'quickshell/MacLock-niri/.macshell-rust-only').is_file())
        self.assertTrue((config / 'macshell-niri/.macshell-rust-only').is_file())
        self.assertTrue((config / 'systemd/user/niri-macshell.service').exists())
        self.assertEqual((config / 'niri/config.kdl').read_text(), '// user niri\n')
        (shell / 'new-user-file').write_text('preserve me')
        subprocess.run([str(self.binary), 'rollback-profile', *common, 'safe'], env=env, capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual((shell / 'user').read_text(), 'original')
        self.assertEqual((backup / 'after/0/new-user-file').read_text(), 'preserve me')
        self.assertFalse((config / 'systemd/user/niri-macshell.service').exists())
        self.assertFalse((config / 'macshell-niri/.macshell-rust-only').exists())
        self.assertFalse((self.data / 'latest').exists())
        (tools / 'desktop-file-validate').write_text('#!/bin/sh\nexit 1\n')
        failed = subprocess.run([str(self.binary), 'install-profile', *common, 'session'], env=env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        self.assertEqual((shell / 'user').read_text(), 'original')
        self.assertFalse((self.data / 'latest').exists())
        self.assertFalse((config / 'systemd/user/niri-macshell.service').exists())

    def test_plain_install_launcher_works_with_existing_legacy_session(self):
        profile = self.root / 'legacy profile'; profile.mkdir()
        legacy = profile / 'shell-supervisor.py'
        legacy.write_text('import sys\nprint("legacy supervisor:", *sys.argv[1:])\n')
        bin_dir = self.root / 'bin'
        self.call('launchers', profile, bin_dir, self.root / 'cache', self.root / 'lock', self.root / 'qs')
        env = dict(os.environ, MACSHELL_MANAGED_SHELL='1')
        result = subprocess.run([str(bin_dir / 'macshell-niri')], env=env, capture_output=True, text=True, timeout=10, check=True)
        self.assertEqual(result.stdout.strip(), 'legacy supervisor: start')
        (profile / 'shell-supervisor.sh').write_text('#!/bin/sh\nprintf "new supervisor: %s\\n" "$1"\n')
        result = subprocess.run([str(bin_dir / 'macshell-niri')], env=env, capture_output=True, text=True, timeout=10, check=True)
        self.assertEqual(result.stdout.strip(), 'new supervisor: start')

    def test_activation_rollback_checks_digest_and_recovers_failed_start(self):
        _runtime, qs, env = self.guard_environment()
        tools = qs.parent
        cargo = tools / 'cargo'; cargo.write_text((ROOT / 'tests/fixtures/fake_installer_cargo.py').read_text()); cargo.chmod(0o755)
        for name in ('niri', 'systemd-run', 'flock'):
            path = tools / name; path.write_text('#!/bin/sh\nexit 0\n'); path.chmod(0o755)
        qs.write_text('''#!/bin/sh
case "$*" in *list*) echo '[]';; *"status state"*) echo '{"connected":true}';; *) exit 0;; esac
''')
        env['FAKE_CARGO_LOG'] = str(self.root / 'cargo.log')
        config = self.root / 'config'; (config / 'niri').mkdir(parents=True)
        niri = config / 'niri/config.kdl'; niri.write_text('// original\n')
        bin_dir = self.root / 'bin'; cache = self.root / 'cache'
        common = [str(ROOT), str(config), str(cache), str(self.data), str(bin_dir), str(qs)]
        command = [str(self.binary), 'install-profile', *common, 'activate']
        subprocess.run(command, env=env, capture_output=True, text=True, check=True, timeout=60)
        installed = niri.read_text(); self.assertIn('Original config snapshot:', installed)
        niri.write_text('// user edit\n')
        refused = subprocess.run([str(self.binary), 'rollback-profile', *common, 'safe'], env=env, capture_output=True, timeout=10)
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(niri.read_text(), '// user edit\n')
        subprocess.run([str(self.binary), 'rollback-profile', *common, 'force'], env=env, capture_output=True, check=True, timeout=10)
        self.assertEqual(niri.read_text(), '// original\n')
        qs.write_text('''#!/bin/sh
case "$*" in *list*) echo '[]';; *"status state"*) echo '{"connected":false}';; *) exit 1;; esac
''')
        failed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(niri.read_text(), '// original\n')
        self.assertFalse((self.data / 'latest').exists())

    def test_cli_plain_install_and_rollback(self):
        _runtime, qs, env = self.guard_environment()
        tools = qs.parent
        cargo = tools / 'cargo'; cargo.write_text((ROOT / 'tests/fixtures/fake_installer_cargo.py').read_text()); cargo.chmod(0o755)
        env['FAKE_CARGO_LOG'] = str(self.root / 'cargo.log')
        config = self.root / 'config'; config.mkdir()
        env.update(XDG_CONFIG_HOME=str(config), XDG_DATA_HOME=str(self.root / 'xdg-data'), XDG_CACHE_HOME=str(self.root / 'cache'), MACSHELL_BIN_DIR=str(self.root / 'bin'), MACSHELL_QS_BIN=str(qs))
        shell = config / 'quickshell/MacShell-niri'; shell.mkdir(parents=True); (shell / 'before').write_text('original')
        install = subprocess.run([str(self.binary), 'cli', str(ROOT)], env=env, capture_output=True, text=True, timeout=60)
        if os.geteuid() == 0:
            self.assertNotEqual(install.returncode, 0)
            self.assertIn('without sudo', install.stderr)
            return
        self.assertEqual(install.returncode, 0, install.stderr)
        self.assertTrue((shell / 'niri-bridge-rust').is_file())
        result = subprocess.run([str(self.binary), 'cli', str(ROOT), '--rollback'], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((shell / 'before').read_text(), 'original')


if __name__ == '__main__': unittest.main()
