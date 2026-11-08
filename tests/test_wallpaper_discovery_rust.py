import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class WallpaperDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='wallpaper-build-')
        cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/wallpaper-discovery/Cargo.toml'), '--target-dir', cls.build.name], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/macshell-wallpaper-discovery'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config/noctalia'
        self.cache = self.root / 'cache/noctalia'
        self.config.mkdir(parents=True); self.cache.mkdir(parents=True)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), XDG_CONFIG_HOME=str(self.config.parent), XDG_CACHE_HOME=str(self.cache.parent), MACSHELL_WALLPAPER_CACHE_HOME=str(self.cache.parent), PATH=str(self.bin))
        self.images = []
        for name in ['one', 'two', 'three']:
            path = self.root / (name + '.png'); path.write_bytes(b'x'); self.images.append(str(path))

    def run_program(self, command):
        output = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True, timeout=8).stdout
        return dict(line.split('\t', 1) for line in output.splitlines())

    def compare_python(self):
        rust = self.run_program([str(self.binary)])
        python = self.run_program([shutil.which('python3'), str(ROOT / 'MacShell/niri_wallpaper.py')])
        self.assertEqual(rust, python)
        return rust

    def test_json_and_toml_precedence_and_unicode(self):
        a, b, c = self.images
        (self.cache / 'wallpapers.json').write_text(json.dumps({'wallpapers': {'eDP-1': {'dark': a}, 'DP-1': b}, 'defaultWallpaper': a}))
        (self.config / 'wallpapers.json').write_text(json.dumps({'wallpapers': {'eDP-1': {'light': c}}}))
        (self.config / 'settings.toml').write_text(f'[wallpaper.last]\npath = {json.dumps(b)}\n[wallpaper.monitors."DP-1"]\npath = {json.dumps(c)}\n')
        result = self.compare_python()
        self.assertEqual(result, {'wallpaper.monitors.eDP-1': c, 'wallpaper.monitors.DP-1': b, 'wallpaper.default': a, 'wallpaper.last': b})

    def test_invalid_inputs_and_command_fallback(self):
        (self.cache / 'wallpapers.json').write_text('{broken')
        (self.config / 'settings.toml').write_text('invalid = [')
        tool = self.bin / 'awww'; tool.write_text('#!/bin/sh\nprintf "monitor: image: %s\\n" "$TEST_IMAGE"\n'); tool.chmod(0o755)
        self.env['TEST_IMAGE'] = self.images[0]
        self.assertEqual(self.compare_python(), {'wallpaper.default': self.images[0]})

    def test_timed_out_tool_is_stopped(self):
        tool = self.bin / 'awww'; tool.write_text('#!/bin/sh\nexec /usr/bin/sleep 10\n'); tool.chmod(0o755)
        start = time.monotonic()
        self.assertEqual(self.run_program([str(self.binary)]), {})
        self.assertLess(time.monotonic() - start, 4)


if __name__ == '__main__':
    unittest.main()
