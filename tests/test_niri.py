import io
import json
import copy
from contextlib import nullcontext
import os
import queue
import select
import shutil
from pathlib import Path
import socket
import tempfile
import threading
import subprocess
import sys
import unittest
from unittest.mock import patch

from MacShell.niri_ipc import State, request
from MacShell.niri_tools import input_config, without_input_preferences, write_input
from scripts import install_niri as installer

ROOT = Path(__file__).resolve().parent.parent


class StateTests(unittest.TestCase):
    def setUp(self):
        self.state = State()
        self.state.outputs = {
            "eDP-1": {"logical": {"x": 200, "y": 0, "width": 1280, "height": 800, "scale": 1.5},
                      "modes": [{"width": 1920, "height": 1200, "refresh_rate": 60000}], "current_mode": 0},
            "disabled": {"logical": None},
        }
        self.state.apply({"WorkspacesChanged": {"workspaces": [
            {"id": 10, "idx": 1, "output": "eDP-1", "is_active": True, "is_focused": True},
            {"id": 11, "idx": 2, "output": "eDP-1", "is_active": False, "is_focused": False},
        ]}})
        self.window = {"id": 42, "app_id": "test", "workspace_id": 10, "is_focused": True,
                       "layout": {"tile_pos_in_workspace_view": [15.5, 20], "window_offset_in_tile": [2, 3], "window_size": [400, 300]}}
        self.state.apply({"WindowsChanged": {"windows": [self.window]}})

    def test_fractional_geometry_and_disabled_outputs(self):
        result = self.state.snapshot()
        self.assertEqual(len(result["monitors"]), 1)
        self.assertEqual(result["windows"][0]["at"], [217.5, 23])
        self.assertEqual(result["monitors"][0]["scale"], 1.5)
        self.assertEqual(result["monitors"][0]["logicalRect"], {"x": 200, "y": 0, "width": 1280, "height": 800})
        self.assertEqual(result["monitors"][0]["pixelWidth"], 1920)
        self.assertFalse(result["windows"][0]["hidden"])

    def test_title_only_changes_do_not_change_focus_or_geometry(self):
        self.window['title'] = 'First'
        changed = dict(self.window, title='Streaming title')
        self.assertEqual(self.state.apply({'WindowOpenedOrChanged': {'window': changed}}), 'title')
        result = self.state.snapshot()['windows'][0]
        self.assertEqual(result['title'], 'Streaming title')
        self.assertTrue(result['is_focused'])
        self.assertEqual(result['at'], [217.5, 23])

    def test_title_plus_other_changes_still_require_a_full_snapshot(self):
        self.window['title'] = 'First'
        for key, value in [('is_focused', False), ('workspace_id', 11), ('app_id', 'other'), ('future_property', True)]:
            state = State()
            state.windows = {42: copy.deepcopy(self.window)}
            changed = dict(self.window, title='Next', **{key: value})
            self.assertNotEqual(state.apply({'WindowOpenedOrChanged': {'window': changed}}), 'title')
    def test_bridge_streams_titles_without_full_state_and_keeps_mixed_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            address = str(Path(directory) / 'niri.sock')
            stream_queue, done = queue.Queue(), threading.Event()
            window = {'id': 42, 'title': 'First', 'app_id': 'test', 'workspace_id': 10, 'is_focused': True,
                      'layout': {'tile_pos_in_workspace_view': [0, 0], 'window_size': [400, 300]}}
            server = socket.socket(socket.AF_UNIX)
            server.bind(address); server.listen(); server.settimeout(.1)
            def serve():
                while not done.is_set():
                    try: connection, _ = server.accept()
                    except socket.timeout: continue
                    request = json.loads(connection.makefile('rb').readline())
                    if request == 'Outputs':
                        connection.sendall(b'{"Ok":{"Outputs":{}}}\n'); connection.close()
                    elif request == 'EventStream':
                        connection.sendall((json.dumps({'WindowsChanged': {'windows': [window]}}) + '\n').encode())
                        stream_queue.put(connection)
                        done.wait(5)
                        connection.close()
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            process = subprocess.Popen([sys.executable, str(ROOT / 'MacShell/niri_ipc.py')], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, NIRI_SOCKET=address))
            def receive():
                self.assertTrue(select.select([process.stdout], [], [], 3)[0], 'No bridge message')
                return json.loads(process.stdout.readline())
            try:
                stream = stream_queue.get(timeout=3)
                self.assertEqual(receive()['state']['windows'][0]['title'], 'First')
                changed = dict(window, title='Streamed')
                stream.sendall((json.dumps({'WindowOpenedOrChanged': {'window': changed}}) + '\n').encode())
                delta = receive()
                self.assertEqual(delta, {'connected': True, 'titles': {'42': 'Streamed'}})
                mixed = copy.deepcopy(changed); mixed['title'] = 'Mixed'; mixed['layout']['window_size'] = [600, 300]
                events = [{'WindowOpenedOrChanged': {'window': dict(changed, title='Intermediate')}},
                          {'WindowOpenedOrChanged': {'window': mixed}}]
                stream.sendall(('\n'.join(json.dumps(event) for event in events) + '\n').encode())
                full = receive()['state']['windows'][0]
                self.assertEqual(full['title'], 'Mixed'); self.assertEqual(full['size'], [600, 300])
            finally:
                process.stdin.close()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                done.set(); thread.join(timeout=2); server.close()
                errors = process.stderr.read().decode()
                process.stdout.close(); process.stderr.close()
                self.assertFalse(errors, errors)

    def test_output_identity_preserves_device_details_without_using_the_index(self):
        self.state.outputs['eDP-1'].update(make='Demo', model='Display', serial='unique')
        monitor = self.state.snapshot()['monitors'][0]
        self.assertEqual((monitor['name'], monitor['make'], monitor['model'], monitor['serial']), ('eDP-1', 'Demo', 'Display', 'unique'))

    def test_workspace_activation_and_close(self):
        self.state.apply({"WorkspaceActivated": {"id": 11, "focused": True}})
        self.assertTrue(self.state.snapshot()["windows"][0]["hidden"])
        self.state.apply({"WindowClosed": {"id": 42}})
        self.assertEqual(self.state.snapshot()["windows"], [])

    def test_layout_without_position_does_not_invent_capture_geometry(self):
        self.state.apply({"WindowLayoutsChanged": {"changes": [[42, {"window_size": [300, 200]}]]}})
        window = self.state.snapshot()["windows"][0]
        self.assertFalse(window["geometryKnown"])
        self.assertTrue(window["hidden"])
        # Unknown capture geometry must not make a visible tiled window disappear
        # from the decision whether a wallpaper reconstruction is accurate.
        self.assertTrue(window["workspaceActive"])

    def test_focus_is_unique_after_open(self):
        self.state.apply({"WindowOpenedOrChanged": {"window": {**self.window, "id": 43}}})
        self.assertEqual([w["id"] for w in self.state.windows.values() if w["is_focused"]], [43])
        self.state.apply({"WindowFocusChanged": {"id": None}})
        self.assertFalse(any(w["is_focused"] for w in self.state.windows.values()))

    def test_keyboard_and_unknown_events(self):
        self.state.apply({"KeyboardLayoutsChanged": {"keyboard_layouts": {"names": ["English", "Russian"], "current_idx": 0}}})
        self.state.apply({"KeyboardLayoutSwitched": {"idx": 1}})
        self.state.apply({"FutureEvent": {"anything": True}})
        self.assertEqual(self.state.keyboard["current_idx"], 1)

    def test_rotated_output_uses_logical_dimensions_for_layout(self):
        output = self.state.outputs["eDP-1"]
        output["logical"].update(width=800, height=1280)
        monitor = self.state.snapshot()["monitors"][0]
        self.assertEqual((monitor["width"], monitor["height"]), (1200, 1920))
        self.assertEqual((monitor["modeWidth"], monitor["modeHeight"]), (1920, 1200))
        self.assertEqual((monitor["logicalRect"]["width"], monitor["logicalRect"]["height"]), (800, 1280))
        self.assertEqual((monitor["pixelWidth"], monitor["pixelHeight"]), (1920, 1200))

    def test_fullscreen_inference_requires_both_dimensions(self):
        self.window["layout"].update(tile_pos_in_workspace_view=[0, 0], window_offset_in_tile=[0, 0], window_size=[1280, 500])
        self.assertFalse(self.state.snapshot()["windows"][0]["fullscreen"])
        self.window["layout"]["window_size"] = [1280, 800]
        self.assertTrue(self.state.snapshot()["windows"][0]["fullscreen"])


class SocketTests(unittest.TestCase):
    def test_real_unix_request_and_error_response(self):
        with tempfile.TemporaryDirectory() as directory:
            address = str(Path(directory) / "niri.sock")
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(address)
                server.listen()
                received = []
                def respond():
                    for response in ({"Ok": {"Outputs": {}}}, {"Err": "window disappeared"}):
                        connection, _ = server.accept()
                        with connection:
                            received.append(json.loads(connection.makefile("rb").readline()))
                            connection.sendall((json.dumps(response) + "\n").encode())
                worker = threading.Thread(target=respond, daemon=True)
                worker.start()
                self.assertEqual(request("Outputs", address), {"Outputs": {}})
                with self.assertRaisesRegex(RuntimeError, "disappeared"):
                    request({"Action": {"CloseWindow": {"id": 42}}}, address)
                worker.join(timeout=3)
                self.assertEqual(received[0], "Outputs")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        config = self.base / "config"
        self.patch = patch.multiple(installer, CONFIG=config, DATA=self.base / "data", BIN=self.base / "bin",
                                    PROFILE=config / "macshell-niri", SHELL=config / "quickshell/MacShell-niri",
                                    LOCK=config / "quickshell/MacLock-niri", NIRI=config / "niri/config.kdl",
                                    SESSION_UNIT=config / "systemd/user/niri-macshell.service",
                                    SHELL_UNIT=config / "systemd/user/macshell-niri-shell.service")
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.guard_patch = patch.object(installer, "install_guard", side_effect=nullcontext)
        self.guard_patch.start()
        self.addCleanup(self.guard_patch.stop)
        self.session_patch = patch.object(installer, "session_active", return_value=False)
        self.session_patch.start()
        self.addCleanup(self.session_patch.stop)
        artifact = self.base / "fixture-bridge"
        artifact.write_text('#!/bin/sh\necho fixture\n'); artifact.chmod(0o755)
        self.bridge_patch = patch.object(installer, "build_niri_bridge", return_value=artifact)
        self.bridge_patch.start()
        self.addCleanup(self.bridge_patch.stop)
        self.clock_patch = patch.object(installer, "build_boot_clock", return_value=artifact)
        self.clock_patch.start()
        self.addCleanup(self.clock_patch.stop)
        self.stats_patch = patch.object(installer, "build_system_stats", return_value=artifact)
        self.stats_patch.start()
        self.addCleanup(self.stats_patch.stop)
        self.night_patch = patch.object(installer, "build_night_shift", return_value=artifact)
        self.night_patch.start()
        self.addCleanup(self.night_patch.stop)
        self.timed_patch = patch.object(installer, "build_timed_modes", return_value=artifact)
        self.timed_patch.start()
        self.addCleanup(self.timed_patch.stop)
        self.activity_patch = patch.object(installer, "build_activity_preferences", return_value=artifact)
        self.activity_patch.start()
        self.addCleanup(self.activity_patch.stop)
        self.bar_patch = patch.object(installer, "build_bar_preferences", return_value=artifact)
        self.bar_patch.start()
        self.addCleanup(self.bar_patch.stop)
        self.widget_patch = patch.object(installer, "build_widget_preferences", return_value=artifact)
        self.widget_patch.start()
        self.addCleanup(self.widget_patch.stop)
        self.locale_patch = patch.object(installer, "build_locale_preferences", return_value=artifact)
        self.locale_patch.start()
        self.addCleanup(self.locale_patch.stop)
        self.blur_patch = patch.object(installer, "build_native_blur", return_value=artifact)
        self.blur_patch.start()
        self.addCleanup(self.blur_patch.stop)
        self.preflight_patch = patch.object(installer, "build_session_preflight", return_value=artifact)
        self.preflight_patch.start()
        self.addCleanup(self.preflight_patch.stop)
        self.power_patch = patch.object(installer, "build_power_profiles", return_value=artifact)
        self.power_patch.start()
        self.addCleanup(self.power_patch.stop)
        self.color_patch = patch.object(installer, "build_niri_color", return_value=artifact)
        self.color_patch.start()
        self.addCleanup(self.color_patch.stop)
        self.bluetooth_patch = patch.object(installer, "build_bluetooth", return_value=artifact)
        self.bluetooth_patch.start()
        self.addCleanup(self.bluetooth_patch.stop)
        self.media_patch = patch.object(installer, "build_media_service", return_value=artifact)
        self.media_patch.start()
        self.addCleanup(self.media_patch.stop)
        self.network_patch = patch.object(installer, "build_network", return_value=artifact)
        self.network_patch.start()
        self.addCleanup(self.network_patch.stop)
        installer.NIRI.parent.mkdir(parents=True)
        installer.NIRI.write_text('include "./keys.kdl"\nspawn-sh-at-startup "qs -c noctalia-shell"\n')
        (installer.NIRI.parent / "keys.kdl").write_text('binds {\n Mod+Space { spawn "qs -c noctalia-shell ipc call launcher toggle"; }\n}\n')

    @unittest.skipUnless(shutil.which("niri"), "niri is required")
    def test_prepare_preserves_sources_and_existing_bind(self):
        original = {p: p.read_bytes() for p in installer.NIRI.parent.glob("*.kdl")}
        target = self.base / "generated"
        self.assertTrue(installer.prepare_niri(target))
        self.assertIn("macshell-niri ipc call spotlight toggle", (target / "keys.kdl").read_text())
        self.assertNotIn('spawn "qs"', (target / "macshell.kdl").read_text())
        self.assertNotIn("Mod+Space", (target / "macshell.kdl").read_text())
        self.assertTrue(all(path.read_bytes() == content for path, content in original.items()))

    def test_install_and_rollback_preserve_existing_tree(self):
        installer.SHELL.mkdir(parents=True)
        (installer.SHELL / "previous.txt").write_bytes(b"previous\x00content")
        original = installer.NIRI.read_bytes()
        installer.install(False)
        self.assertEqual(installer.NIRI.read_bytes(), original)
        self.assertTrue((installer.SHELL / "Niri.qml").is_file())
        self.assertTrue((installer.SHELL / "niri-bridge-rust").is_file())
        self.assertTrue((installer.LOCK / "boot-clock-rust").is_file())
        self.assertTrue((installer.SHELL / "boot-clock-rust").is_file())
        self.assertTrue((installer.SHELL / "system-stats-rust").is_file())
        self.assertTrue((installer.SHELL / "night-shift-rust").is_file())
        self.assertTrue((installer.SHELL / "timed-modes-rust").is_file())
        self.assertTrue((installer.SHELL / "activity-preferences-rust").is_file())
        self.assertTrue((installer.SHELL / "bar-preferences-rust").is_file())
        self.assertTrue((installer.SHELL / "widget-preferences-rust").is_file())
        self.assertTrue((installer.SHELL / "locale-preferences-rust").is_file())
        self.assertTrue((installer.SHELL / "native-blur-rust").is_file())
        self.assertTrue((installer.SHELL / "session-preflight-rust").is_file())
        self.assertTrue((installer.SHELL / "power-profiles-rust").is_file())
        self.assertTrue((installer.SHELL / "niri-color-rust").is_file())
        self.assertTrue((installer.SHELL / "bluetooth-service-rust").is_file())
        self.assertTrue((installer.SHELL / "capture-service-rust").is_file())
        self.assertTrue((installer.SHELL / "recording-service-rust").is_file())
        self.assertTrue((installer.SHELL / "network-service-rust").is_file())
        self.assertEqual((installer.SHELL / "VERSION").read_text(), (installer.SOURCE / "VERSION").read_text())
        self.assertIn("MACSHELL_SETTINGS_HOME", (installer.BIN / "macshell-niri").read_text())
        directory = Path((installer.DATA / "latest").read_text())
        manifest = json.loads((directory / "manifest.json").read_text())
        installer.restore(directory, manifest)
        self.assertEqual((installer.SHELL / "previous.txt").read_bytes(), b"previous\x00content")
        self.assertFalse((installer.BIN / "macshell-niri").exists())
        self.assertTrue((directory / "after/0/Niri.qml").exists())

    def test_rust_bridge_install_and_rollback(self):
        installer.SHELL.mkdir(parents=True)
        (installer.SHELL / "previous.txt").write_text("before")
        artifact = self.base / "built-bridge"
        artifact.write_text('#!/bin/sh\necho fixture\n'); artifact.chmod(0o755)
        with patch.object(installer, "build_niri_bridge", return_value=artifact) as build:
            installer.install(rust_bridge=True)
        build.assert_called_once()
        binary = installer.SHELL / "niri-bridge-rust"
        self.assertTrue(binary.is_file())
        self.assertEqual(binary.read_text(), artifact.read_text())
        self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
        directory = Path((installer.DATA / "latest").read_text())
        installer.restore(directory, json.loads((directory / "manifest.json").read_text()))
        self.assertEqual((installer.SHELL / "previous.txt").read_text(), "before")
        self.assertFalse(binary.exists())

    def test_rust_build_failure_does_not_change_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "niri-bridge-rust"
        existing.write_bytes(b"prior version")
        with patch.object(installer, "build_niri_bridge", side_effect=RuntimeError("build failed")) as build:
            with self.assertRaisesRegex(RuntimeError, "build failed"):
                installer.install()
        build.assert_called_once()
        self.assertEqual(existing.read_bytes(), b"prior version")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_explicit_legacy_install_does_not_build_rust(self):
        with patch.object(installer, "build_niri_bridge", side_effect=AssertionError("unexpected Rust build")):
            installer.install(rust_bridge=False)
        self.assertFalse((installer.SHELL / "niri-bridge-rust").exists())
        self.assertFalse((installer.LOCK / "boot-clock-rust").exists())
        self.assertFalse((installer.SHELL / "boot-clock-rust").exists())
        self.assertFalse((installer.SHELL / "system-stats-rust").exists())
        self.assertFalse((installer.SHELL / "night-shift-rust").exists())
        self.assertFalse((installer.SHELL / "timed-modes-rust").exists())
        self.assertFalse((installer.SHELL / "activity-preferences-rust").exists())
        self.assertFalse((installer.SHELL / "bar-preferences-rust").exists())
        self.assertFalse((installer.SHELL / "widget-preferences-rust").exists())
        self.assertFalse((installer.SHELL / "locale-preferences-rust").exists())
        self.assertFalse((installer.SHELL / "native-blur-rust").exists())
        self.assertFalse((installer.SHELL / "session-preflight-rust").exists())
        self.assertFalse((installer.SHELL / "power-profiles-rust").exists())
        self.assertFalse((installer.SHELL / "niri-color-rust").exists())
        self.assertFalse((installer.SHELL / "bluetooth-service-rust").exists())
        self.assertFalse((installer.SHELL / "capture-service-rust").exists())
        self.assertFalse((installer.SHELL / "recording-service-rust").exists())
        self.assertFalse((installer.SHELL / "network-service-rust").exists())

    def test_clock_build_failure_preserves_existing_install(self):
        installer.LOCK.mkdir(parents=True)
        existing = installer.LOCK / "boot-clock-rust"
        existing.write_bytes(b"prior clock")
        with patch.object(installer, "build_boot_clock", side_effect=RuntimeError("clock build failed")):
            with self.assertRaisesRegex(RuntimeError, "clock build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior clock")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_stats_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "system-stats-rust"
        existing.write_bytes(b"prior sampler")
        with patch.object(installer, "build_system_stats", side_effect=RuntimeError("stats build failed")):
            with self.assertRaisesRegex(RuntimeError, "stats build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior sampler")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_night_shift_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "night-shift-rust"
        existing.write_bytes(b"prior night shift")
        with patch.object(installer, "build_night_shift", side_effect=RuntimeError("night shift build failed")):
            with self.assertRaisesRegex(RuntimeError, "night shift build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior night shift")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_timed_modes_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "timed-modes-rust"
        existing.write_bytes(b"prior timed modes")
        with patch.object(installer, "build_timed_modes", side_effect=RuntimeError("timed modes build failed")):
            with self.assertRaisesRegex(RuntimeError, "timed modes build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior timed modes")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_activity_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "activity-preferences-rust"
        existing.write_bytes(b"prior Activity preferences")
        with patch.object(installer, "build_activity_preferences", side_effect=RuntimeError("Activity build failed")):
            with self.assertRaisesRegex(RuntimeError, "Activity build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior Activity preferences")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_bar_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "bar-preferences-rust"
        existing.write_bytes(b"prior menu bar preferences")
        with patch.object(installer, "build_bar_preferences", side_effect=RuntimeError("menu bar build failed")):
            with self.assertRaisesRegex(RuntimeError, "menu bar build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior menu bar preferences")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_widget_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "widget-preferences-rust"
        existing.write_bytes(b"prior widget preferences")
        with patch.object(installer, "build_widget_preferences", side_effect=RuntimeError("widget build failed")):
            with self.assertRaisesRegex(RuntimeError, "widget build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior widget preferences")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_locale_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "locale-preferences-rust"
        existing.write_bytes(b"prior locale preferences")
        with patch.object(installer, "build_locale_preferences", side_effect=RuntimeError("locale build failed")):
            with self.assertRaisesRegex(RuntimeError, "locale build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior locale preferences")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_blur_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "native-blur-rust"
        existing.write_bytes(b"prior native blur")
        with patch.object(installer, "build_native_blur", side_effect=RuntimeError("blur build failed")):
            with self.assertRaisesRegex(RuntimeError, "blur build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior native blur")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_session_preflight_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "Niri.qml"
        existing.write_bytes(b"prior shell")
        with patch.object(installer, "build_session_preflight", side_effect=RuntimeError("preflight build failed")):
            with self.assertRaisesRegex(RuntimeError, "preflight build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior shell")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_power_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "power-profiles-rust"
        existing.write_bytes(b"prior power profiles")
        with patch.object(installer, "build_power_profiles", side_effect=RuntimeError("power build failed")):
            with self.assertRaisesRegex(RuntimeError, "power build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior power profiles")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_color_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "niri-color-rust"
        existing.write_bytes(b"prior color helper")
        with patch.object(installer, "build_niri_color", side_effect=RuntimeError("color build failed")):
            with self.assertRaisesRegex(RuntimeError, "color build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior color helper")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_bluetooth_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "bluetooth-service-rust"
        existing.write_bytes(b"prior bluetooth")
        with patch.object(installer, "build_bluetooth", side_effect=RuntimeError("bluetooth build failed")):
            with self.assertRaisesRegex(RuntimeError, "bluetooth build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior bluetooth")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_missing_cargo_fails_before_install(self):
        self.bridge_patch.stop()
        with patch.object(installer.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "needs Cargo"):
                installer.install()
        self.assertFalse(installer.SHELL.exists())
        self.assertFalse((installer.DATA / "latest").exists())

    def test_media_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "recording-service-rust"
        existing.write_bytes(b"prior recorder")
        with patch.object(installer, "build_media_service", side_effect=RuntimeError("media build failed")):
            with self.assertRaisesRegex(RuntimeError, "media build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior recorder")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_network_build_failure_preserves_existing_install(self):
        installer.SHELL.mkdir(parents=True)
        existing = installer.SHELL / "network-service-rust"
        existing.write_bytes(b"prior network service")
        with patch.object(installer, "build_network", side_effect=RuntimeError("network build failed")):
            with self.assertRaisesRegex(RuntimeError, "network build failed"):
                installer.install()
        self.assertEqual(existing.read_bytes(), b"prior network service")
        self.assertFalse((installer.DATA / "latest").exists())

    def test_build_rejects_incompatible_binary(self):
        self.bridge_patch.stop()
        target = self.base / "target"
        target.joinpath("release").mkdir(parents=True)
        target.joinpath("release/macshell-niri-bridge").write_bytes(b"fixture")
        success = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        wrong = subprocess.CompletedProcess([], 0, stdout="wrong protocol\n", stderr="")
        with patch.object(installer.shutil, "which", return_value="/test/cargo"), \
             patch.object(installer.subprocess, "run", side_effect=[success, wrong]) as run:
            with self.assertRaisesRegex(RuntimeError, "protocol check"):
                installer.build_niri_bridge(target)
        self.assertIn("--locked", run.call_args_list[0].args[0])
        self.assertIn("--offline", run.call_args_list[0].args[0])

    def test_rollback_refuses_unrelated_config_edits(self):
        directory, manifest = installer.snapshot([installer.NIRI])
        manifest["niri_digest"] = installer.digest(installer.NIRI)
        installer.NIRI.write_text("// edited after install\n")
        with self.assertRaisesRegex(RuntimeError, "changed after"):
            installer.restore(directory, manifest)
        self.assertEqual(installer.NIRI.read_text(), "// edited after install\n")

    @unittest.skipUnless(shutil.which("niri"), "niri is required")
    def test_separate_session_preserves_original_and_restores_own_files(self):
        original = {p: p.read_bytes() for p in installer.NIRI.parent.glob("*.kdl")}
        real_run = subprocess.run
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            if command[:3] == ["systemctl", "--user", "daemon-reload"]:
                return subprocess.CompletedProcess(command, 0)
            return real_run(command, **kwargs)
        with patch.object(installer, "runtime_check"), patch.object(installer.subprocess, "run", side_effect=run):
            installer.install(session=True)
        self.assertTrue(all(path.read_bytes() == content for path, content in original.items()))
        self.assertIn('--config "' + str(installer.PROFILE / "niri/config.kdl") + '"', installer.SESSION_UNIT.read_text())
        self.assertIn("TimeoutStartSec=30", installer.SESSION_UNIT.read_text())
        self.assertIn("ExecStartPost=/usr/bin/python3", installer.SESSION_UNIT.read_text())
        self.assertIn("ExecStopPost=-/usr/bin/systemctl --user stop macshell-niri-shell.service", installer.SESSION_UNIT.read_text())
        shell_unit = installer.SHELL_UNIT.read_text()
        self.assertIn("PartOf=niri-macshell.service", shell_unit)
        self.assertIn("Restart=on-failure", shell_unit)
        self.assertIn("StartLimitBurst=5", shell_unit)
        self.assertIn("KillMode=control-group", shell_unit)
        self.assertNotIn("After=niri-macshell.service", shell_unit)
        self.assertTrue((installer.PROFILE / "session-ready.py").is_file())
        self.assertTrue((installer.PROFILE / "session-preflight.sh").is_file())
        self.assertTrue((installer.PROFILE / "session-preflight-rust").is_file())
        self.assertTrue((installer.PROFILE / "shell-supervisor.py").is_file())
        self.assertTrue((installer.PROFILE / "session-locale.py").is_file())
        self.assertTrue((installer.PROFILE / "session-locale.sh").is_file())
        self.assertTrue((installer.PROFILE / "locale-preferences-rust").is_file())
        self.assertTrue((installer.PROFILE / "locale_preferences.py").is_file())
        session = (installer.BIN / "niri-macshell-session").read_text()
        self.assertNotIn("@PROFILE_CONFIG@", session)
        self.assertNotIn("@LOCALE_HELPER@", session)
        self.assertNotIn("NIRI_CONFIG=", session)
        self.assertIn("/usr/bin/niri-session", session)
        self.assertTrue((installer.DATA / "session/register-session.sh").is_file())
        self.assertFalse(any(command[0] == "qs" or command[:2] == ["niri", "msg"] for command in calls))
        self.assertFalse(any("start" in command or "stop" in command for command in calls))
        directory = Path((installer.DATA / "latest").read_text())
        manifest = json.loads((directory / "manifest.json").read_text())
        self.assertTrue(manifest["session_only"])
        installer.restore(directory, manifest)
        self.assertFalse(installer.SESSION_UNIT.exists())
        self.assertFalse(installer.SHELL_UNIT.exists())
        self.assertFalse((installer.BIN / "niri-macshell-session").exists())
        self.assertTrue(all(path.read_bytes() == content for path, content in original.items()))

    @unittest.skipUnless(shutil.which("niri"), "niri is required")
    def test_reactivation_has_no_recursive_includes(self):
        staged = installer.PROFILE / "niri"
        staged.parent.mkdir()
        installer.prepare_niri(staged)
        installer.NIRI.write_text('// Original config snapshot: test\ninclude ' + json.dumps(str(staged / "config.kdl")) + '\n')
        target = self.base / "second"
        installer.prepare_niri(target)
        self.assertNotIn(str(staged), (target / "config.kdl").read_text())
        self.assertEqual((target / "config.kdl").read_text().count('include "./macshell.kdl"'), 1)

    def test_failed_activation_restores_original_configuration(self):
        original = installer.NIRI.read_bytes()
        result = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(installer, "runtime_check"), patch.object(installer, "validate"), patch.object(installer, "stop_shell", return_value=True), patch.object(installer.subprocess, "run", return_value=result), patch.object(installer.subprocess, "Popen") as popen:
            popen.return_value.poll.return_value = 1
            with self.assertRaisesRegex(RuntimeError, "did not become ready"):
                installer.install(True)
        self.assertEqual(installer.NIRI.read_bytes(), original)
        self.assertFalse(installer.SHELL.exists())
        self.assertFalse((installer.DATA / "latest").exists())

    def test_active_session_rejects_install_before_modifying_files(self):
        self.session_patch.stop()
        with patch.object(installer, "session_active", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "Log out"):
                installer.install(session=True)
        self.assertFalse(installer.SHELL.exists())

    def test_stop_waits_for_instance_to_exit(self):
        with patch.object(installer, "instances", side_effect=[[{}], [{}], []]), patch.object(installer.subprocess, "run") as run, patch.object(installer.time, "sleep"):
            self.assertTrue(installer.stop_shell("MacShell-niri"))
        self.assertEqual(run.call_args.args[0][-1], "kill")

    def test_instances_accepts_quickshell_empty_message(self):
        result = subprocess.CompletedProcess([], 0, stdout='No running instances for "/tmp/shell.qml"\nUse --all to list all instances.\n')
        with patch.object(installer.subprocess, "run", return_value=result):
            self.assertEqual(installer.instances("MacLock-niri"), [])


class InstallationGuardTests(unittest.TestCase):
    def test_locked_or_unknown_locker_blocks_installation(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_RUNTIME_DIR": directory}), \
             patch.object(installer, "instances", return_value=[{"pid": 123}]):
            for state, code in (("busy", 0), ("stopping", 0), ("", 1)):
                with self.subTest(state=state), patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], code, state, "")):
                    with self.assertRaisesRegex(RuntimeError, "unlock"):
                        with installer.install_guard():
                            self.fail("guard must not admit changes")
            with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "ready", "")):
                with installer.install_guard():
                    pass


class InputTests(unittest.TestCase):
    def test_remove_only_known_input_settings(self):
        original = 'input { keyboard { repeat-rate 30; xkb { layout "us,ru"; }; }; mouse { natural-scroll; accel-profile "flat"; }; }\n// repeat-rate 100\n'
        edited = without_input_preferences(original)
        self.assertNotIn("repeat-rate 30", edited)
        self.assertNotIn("natural-scroll;", edited)
        self.assertIn('layout "us,ru"', edited)
        self.assertIn('accel-profile "flat"', edited)
        self.assertIn("// repeat-rate 100", edited)

    @unittest.skipUnless(shutil.which("niri"), "niri is required")
    def test_generated_flags_validate_with_niri(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.kdl"
            for enabled in (False, True):
                path.write_text(input_config(dict(repeatRate=30, repeatDelay=500, mouseSens=0, mouseNatural=enabled,
                                                 tpNatural=enabled, tpTap=enabled, tpDwt=enabled, tpScroll=.7)))
                subprocess.run(["niri", "validate", "-c", str(path)], check=True, capture_output=True)

    @unittest.skipUnless(shutil.which("niri"), "niri is required")
    def test_input_preferences_modify_only_generated_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            (profile / "config.kdl").write_text('include "./original.kdl"\ninclude "./macshell-input.kdl"\n')
            (profile / "original.kdl").write_text('input { keyboard { repeat-rate 20; xkb { layout "us,ru"; }; }; mouse { natural-scroll; }; }\n')
            fragment = profile / "macshell-input.kdl"
            fragment.write_text("// empty\n")
            with patch.dict(os.environ, MACSHELL_INPUT_FRAGMENT=str(fragment), MACSHELL_NIRI_PROFILE=str(profile)):
                write_input(dict(repeatRate=30, repeatDelay=500, mouseSens=0, mouseNatural=False, tpNatural=True, tpTap=True, tpDwt=True, tpScroll=.7))
            self.assertIn('layout "us,ru"', (profile / "original.kdl").read_text())
            self.assertNotIn("natural-scroll", (profile / "original.kdl").read_text())
            self.assertIn("repeat-rate 30", fragment.read_text())


if __name__ == "__main__":
    unittest.main()
