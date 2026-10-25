import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import native_blur as blur


class NativeBlurTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.profile = Path(self.directory.name)
        self.config = self.profile / 'config.kdl'
        self.fragment = self.profile / 'macshell-blur.kdl'
        self.original = b'include "./user.kdl"\nblur { noise 0.1; saturation 1.2; off; }\n'
        self.config.write_bytes(self.original)
        (self.profile / 'user.kdl').write_text('layout { gaps 10; }\n')

    def validator(self, args, **kwargs):
        candidate = Path(args[-1])
        self.assertEqual(candidate.parent, self.profile)
        self.assertIn('include "./user.kdl"', candidate.read_text())
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse(self.fragment.exists())
        self.assertIn('passes 3; offset 4.00000;', (next(self.profile.glob('.macshell-blur-*/blur.kdl'))).read_text())
        return subprocess.CompletedProcess(args, 0)

    def test_validate_before_commit_and_preserve_other_preferences(self):
        with patch.object(blur.subprocess, 'run', side_effect=self.validator):
            blur.apply_blur(self.config, 80)
        self.assertTrue(self.config.read_bytes().startswith(self.original))
        self.assertTrue(self.config.read_text().endswith(blur.INCLUDE + '\n'))
        self.assertEqual((self.profile / 'macshell-blur-config.before').read_bytes(), self.original)
        self.assertEqual(self.fragment.read_text(), blur.blur_config(80))
        self.assertEqual((self.profile / 'user.kdl').read_text(), 'layout { gaps 10; }\n')
        self.assertFalse(list(self.profile.glob('.macshell-blur-*')))

    def test_failed_validation_never_changes_live_files(self):
        for outcome in (subprocess.CompletedProcess([], 1), subprocess.TimeoutExpired('niri', 5)):
            with self.subTest(outcome=outcome), patch.object(blur.subprocess, 'run') as run:
                if isinstance(outcome, Exception):
                    run.side_effect = outcome
                else:
                    run.return_value = outcome
                with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)):
                    blur.apply_blur(self.config, 50)
                self.assertEqual(self.config.read_bytes(), self.original)
                self.assertFalse(self.fragment.exists())
                self.assertFalse(list(self.profile.glob('.macshell-blur-*')))

    def test_external_edit_during_validation_is_preserved(self):
        def edit(*args, **kwargs):
            self.config.write_bytes(self.original + b'// concurrent edit\n')
            return subprocess.CompletedProcess([], 0)
        with patch.object(blur.subprocess, 'run', side_effect=edit), self.assertRaises(RuntimeError):
            blur.apply_blur(self.config, 25)
        self.assertTrue(self.config.read_text().endswith('// concurrent edit\n'))
        self.assertFalse(self.fragment.exists())

    def test_repeated_value_is_noop_and_include_remains_unique(self):
        with patch.object(blur.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            blur.apply_blur(self.config, 7)
            blur.apply_blur(self.config, 7)
            self.assertEqual(run.call_count, 1)
            blur.apply_blur(self.config, 0)
        self.assertEqual(self.config.read_text().count(blur.INCLUDE), 1)
        self.assertNotIn(' off;', self.fragment.read_text())
        self.assertEqual((self.profile / 'macshell-blur-config.before').read_bytes(), self.original)

    def test_only_owned_fragment_can_be_updated(self):
        self.fragment.write_text('// hand-written config\nblur { passes 2; }\n')
        with patch.object(blur.subprocess, 'run') as run, self.assertRaises(RuntimeError):
            blur.apply_blur(self.config, 80)
        run.assert_not_called()
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertIn('hand-written', self.fragment.read_text())

    def test_strength_changes_actual_kawase_parameters_monotonically(self):
        offsets = []
        for level in range(81):
            text = blur.blur_config(level)
            offsets.append(float(text.split('offset ')[1].split(';')[0]))
            self.assertNotIn('noise', text)
            self.assertNotIn('saturation', text)
        self.assertEqual(offsets, sorted(set(offsets)))
        self.assertEqual(offsets[0], .5)
        self.assertEqual(offsets[-1], 4)
        self.assertEqual(blur.blur_config(-5), blur.blur_config(0))
        self.assertEqual(blur.blur_config(500), blur.blur_config(80))

    def test_missing_session_cannot_modify_profile(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(RuntimeError):
            blur.active_profile()

    def test_inactive_profile_is_rejected(self):
        env = {'MACSHELL_NIRI_PROFILE': str(self.profile), 'NIRI_SOCKET': '/tmp/test-niri.sock'}
        with patch.dict(os.environ, env, clear=True), patch.object(blur.socket, 'socket') as connection, \
                patch.object(Path, 'read_bytes', return_value=b'niri\0--config\0/some/other/config.kdl\0'):
            connection.return_value.__enter__.return_value.getsockopt.return_value = blur.struct.pack('3i', 123, os.getuid(), 0)
            with self.assertRaises(RuntimeError):
                blur.active_profile()

    def test_active_profile_uses_server_credentials_and_explicit_config(self):
        env = {'MACSHELL_NIRI_PROFILE': str(self.profile), 'NIRI_SOCKET': '/tmp/test-niri.sock'}
        for arguments in (['niri', '--config', str(self.config)], ['niri', '--config=' + str(self.config)]):
            with self.subTest(arguments=arguments), patch.dict(os.environ, env, clear=True), \
                    patch.object(blur.socket, 'socket') as connection, \
                    patch.object(Path, 'read_bytes', return_value='\0'.join(arguments).encode()):
                connection.return_value.__enter__.return_value.getsockopt.return_value = blur.struct.pack('3i', 123, os.getuid(), 0)
                self.assertEqual(blur.active_profile(), self.config)

    def test_atomic_config_failure_restores_previous_fragment(self):
        original_write = blur.atomic_write
        def fail_config(path, data):
            if path == self.config:
                raise OSError('read-only config')
            original_write(path, data)
        with patch.object(blur.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(blur, 'atomic_write', side_effect=fail_config), self.assertRaises(OSError):
            blur.apply_blur(self.config, 50)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse(self.fragment.exists())
