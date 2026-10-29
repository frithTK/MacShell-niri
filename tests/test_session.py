import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts import session_preflight, session_ready
from scripts import repair_noctalia_qt612 as repair


class PreflightTests(unittest.TestCase):
    def test_probe_does_not_activate_gtk_or_desktop_services(self):
        def run(command, **kwargs):
            env = kwargs["env"]
            self.assertEqual(env["QT_QPA_PLATFORM"], "offscreen")
            self.assertEqual(env["QT_QPA_PLATFORMTHEME"], "")
            self.assertEqual(env["QT_QUICK_CONTROLS_STYLE"], "Basic")
            self.assertNotIn("DISPLAY", env)
            self.assertNotIn("WAYLAND_DISPLAY", env)
            self.assertNotEqual(env["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/1000/bus")
            return subprocess.CompletedProcess(command, 0, "Configuration Loaded", "")
        with patch.dict(os.environ, QT_QPA_PLATFORMTHEME="gtk3", DISPLAY=":1", WAYLAND_DISPLAY="wayland-1",
                        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"):
            with patch.object(session_preflight.subprocess, "run", side_effect=run):
                session_preflight.check_runtime("qs")

    def test_successful_exit_still_rejects_qt_abi_mismatch(self):
        result = subprocess.CompletedProcess([], 0, "", "Qt updated without rebuilding")
        with patch.object(session_preflight.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "runtime check failed"):
                session_preflight.check_runtime("qs")


class ReadinessTests(unittest.TestCase):
    def test_graphical_agent_discovery_ignores_terminal_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / "1").mkdir(); (proc / "1/exe").symlink_to('/usr/bin/pkttyagent')
            self.assertFalse(session_ready.graphical_polkit_agent_running(proc))
            (proc / "2").mkdir(); (proc / "2/exe").symlink_to('/usr/lib/polkit-kde-authentication-agent-1')
            self.assertTrue(session_ready.graphical_polkit_agent_running(proc))
            (proc / "2/exe").unlink()
            (proc / "2/cmdline").write_bytes(b'/usr/lib/polkit-kde-authentication-agent-1\0')
            self.assertTrue(session_ready.graphical_polkit_agent_running(proc))

    def test_agent_bootstrap_reuses_existing_and_reports_unavailable(self):
        with patch.object(session_ready, 'graphical_polkit_agent_running', return_value=True), patch.object(session_ready.subprocess, 'run') as run:
            self.assertEqual(session_ready.ensure_polkit_agent(), 'already_running')
            run.assert_not_called()
        with patch.object(session_ready, 'graphical_polkit_agent_running', return_value=False), patch.object(session_ready.os.path, 'isfile', return_value=False), patch.object(session_ready.subprocess, 'run') as run:
            self.assertEqual(session_ready.ensure_polkit_agent(), 'unavailable')
            run.assert_not_called()

    def test_agent_bootstrap_starts_session_scoped_service(self):
        result = subprocess.CompletedProcess([], 0, '', '')
        with patch.object(session_ready, 'graphical_polkit_agent_running', return_value=False), patch.object(session_ready.os.path, 'isfile', return_value=True), patch.object(session_ready.os, 'access', return_value=True), patch.object(session_ready.subprocess, 'run', return_value=result) as run:
            self.assertEqual(session_ready.ensure_polkit_agent(), 'started')
        command = run.call_args.args[0]
        self.assertIn('--property=PartOf=niri-macshell.service', command)
        self.assertEqual(command[-1], '/usr/lib/polkit-kde-authentication-agent-1')

    def test_retries_until_shell_connects(self):
        responses = [subprocess.CompletedProcess([], 1, "", "No instance"),
                     subprocess.CompletedProcess([], 0, '{"connected":false}', ""),
                     subprocess.CompletedProcess([], 0, '{"connected":true}', "")]
        with patch.object(session_ready.subprocess, "run", side_effect=responses) as run:
            with patch.object(session_ready.time, "sleep"):
                session_ready.wait_ready("/bin/macshell-niri")
        self.assertEqual(run.call_count, 3)

    def test_unresponsive_ipc_cannot_wait_forever(self):
        with patch.object(session_ready.time, "monotonic", side_effect=[0, 0, 0, 20]):
            with patch.object(session_ready.time, "sleep"):
                with patch.object(session_ready.subprocess, "run", side_effect=subprocess.TimeoutExpired("qs", 2)) as run:
                    with self.assertRaisesRegex(RuntimeError, "startup deadline"):
                        session_ready.wait_ready("qs")
        self.assertLessEqual(run.call_args.kwargs["timeout"], 2)


class SessionLauncherTests(unittest.TestCase):
    source = Path(__file__).resolve().parent.parent / "scripts/niri-macshell-session.sh"
    start = "--user --wait start niri-macshell.service"
    cleanup = "--user start --job-mode=replace-irreversibly niri-shutdown.target"

    def run_launcher(self, **overrides):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = root / "calls"
            mocks = root / "mocks.sh"
            mocks.write_text('''
systemctl() {
    printf '%s\\n' "$*" >> "$CALLS"
    if [[ $* == '--user import-environment' ]]; then
        printf 'locale %s %s %s %s\\n' "${LANG:-}" "${LANGUAGE:-}" "${LC_MESSAGES:-}" "${LC_TIME:-}" >> "$CALLS"
    fi
    if [[ $* == "${FAIL_SYSTEMCTL:-}" ]]; then
        return 1
    fi
    case "$*" in
        *is-active*) return "${ACTIVE_EXIT:-3}" ;;
        *'reset-failed niri-macshell.service'*)
            echo 'Unit niri-macshell.service not loaded.' >&2
            return 1 ;;
    esac
    return 0
}
python3() {
    if [[ ${1:-} == locale-helper ]]; then
        printf '%s\\n' "${LOCALE_VALUES:-}"
        return "${LOCALE_EXIT:-0}"
    fi
    return "${PREFLIGHT_EXIT:-0}"
}
logger() { return "${LOGGER_EXIT:-0}"; }
dbus-update-activation-environment() { return "${DBUS_EXIT:-0}"; }
''')
            fallback = root / "niri-session"
            fallback.write_text('#!/bin/sh\nprintf "fallback %s\\n" "$XDG_CURRENT_DESKTOP" >> "$CALLS"\n')
            fallback.chmod(0o755)
            script = root / "session.sh"
            script.write_text(self.source.read_text().replace("@PROFILE_CONFIG@", "config").replace("@PREFLIGHT@", "preflight").replace("@QS_BINARY@", "qs").replace("@LOCALE_HELPER@", "locale-helper").replace("/usr/bin/niri-session", str(fallback)))
            env = dict(os.environ, BASH_ENV=str(mocks), CALLS=str(calls), SHELL="",
                       XDG_STATE_HOME=str(root / "state"), XDG_CURRENT_DESKTOP="wrong", **overrides)
            result = subprocess.run(["bash", str(script)], env=env, capture_output=True, timeout=5)
            lines = calls.read_text().splitlines()
            log = (root / "state/macshell-niri/session.log").read_text()
            return result.returncode, lines, log

    def test_unloaded_unit_can_start_and_exit_normally(self):
        code, lines, log = self.run_launcher()
        self.assertEqual(code, 0, log)
        self.assertIn(self.start, lines)
        self.assertLess(lines.index("--user daemon-reload"), lines.index(self.start))
        self.assertNotIn("fallback niri", lines)
        self.assertEqual(lines.count(self.cleanup), 1)

    def test_failed_service_cleans_up_before_fallback_even_without_logger(self):
        code, lines, log = self.run_launcher(FAIL_SYSTEMCTL=self.start, LOGGER_EXIT="1")
        self.assertEqual(code, 0, log)
        self.assertEqual(lines.count(self.cleanup), 1)
        self.assertLess(lines.index(self.cleanup), lines.index("fallback niri"))
        self.assertIn("--user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP NIRI_SOCKET MACSHELL_SESSION_TOKEN MACSHELL_MANAGED_SHELL", lines)
        self.assertIn("MacShell session failed", log)

    def test_setup_errors_fall_back_before_starting_session(self):
        for overrides in ({"FAIL_SYSTEMCTL": "--user daemon-reload"},
                          {"FAIL_SYSTEMCTL": "--user import-environment"},
                          {"DBUS_EXIT": "1"}, {"PREFLIGHT_EXIT": "1"}):
            with self.subTest(overrides=overrides):
                code, lines, log = self.run_launcher(LOGGER_EXIT="1", **overrides)
                self.assertEqual(code, 0, log)
                self.assertIn("fallback niri", lines)
                self.assertNotIn(self.start, lines)
                self.assertNotIn(self.cleanup, lines)
                self.assertIn("starting the original Niri session", log)

    def test_running_session_is_left_alone(self):
        code, lines, log = self.run_launcher(ACTIVE_EXIT="0")
        self.assertEqual(code, 1, log)
        self.assertNotIn(self.start, lines)
        self.assertNotIn(self.cleanup, lines)
        self.assertNotIn("fallback niri", lines)
        self.assertIn("A niri session is already running", log)

    def test_locale_is_exported_before_user_manager_and_compositor_start(self):
        code, lines, log = self.run_launcher(LOCALE_VALUES="LANG=ru_RU.utf8\nLANGUAGE=ru:en\nLC_MESSAGES=ru_RU.utf8", LC_TIME="en_GB.UTF-8")
        self.assertEqual(code, 0, log)
        self.assertIn("locale ru_RU.utf8 ru:en ru_RU.utf8 en_GB.UTF-8", lines)
        self.assertLess(lines.index("locale ru_RU.utf8 ru:en ru_RU.utf8 en_GB.UTF-8"), lines.index(self.start))

    def test_locale_failure_does_not_deny_login_or_export_partial_output(self):
        code, lines, log = self.run_launcher(LOCALE_EXIT="1", LOCALE_VALUES="LANG=ru_RU.utf8", LANG="en_US.utf8")
        self.assertEqual(code, 0, log)
        self.assertIn(self.start, lines)
        self.assertFalse(any(line.startswith("locale ru_RU") for line in lines))


class NoctaliaRepairTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("qs"), "Quickshell is required")
    def test_real_qml_color_resolution_after_repair(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Commons").mkdir()
            (root / "Widgets").mkdir()
            (root / "runtime").mkdir(mode=0o700)
            (root / "Commons/Color.qml").write_text('pragma Singleton\nimport QtQuick\nQtObject { property color mSurface: "#123456"; function smartAlpha(c) { return c; } }\n')
            (root / "Widgets/Probe.qml").write_text('import QtQuick\nimport qs.Commons\nItem { property bool correct: typeof Color.smartAlpha === "function" && String(Color.mSurface) === "#123456"; Component.onCompleted: console.log("PALETTE_CHECK", correct, String(Color)) }\n')
            (root / "shell.qml").write_text('import QtQuick\nimport Quickshell\nimport qs.Widgets\nShellRoot { Probe { id: probe } Timer { interval: 100; running: true; onTriggered: Qt.exit(probe.correct ? 0 : 2) } }\n')
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
                       XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CACHE_HOME=temporary,
                       DBUS_SESSION_BUS_ADDRESS="unix:path=" + temporary + "/no-bus")
            for key in ("DISPLAY", "WAYLAND_DISPLAY"):
                env.pop(key, None)
            command = [shutil.which("qs"), "-p", temporary]
            before = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
            if "QQuickColor(" in before.stdout + before.stderr:
                self.assertEqual(before.returncode, 2)
            repair.pin_imports(root)
            after = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(after.returncode, 0, after.stdout + after.stderr)
            self.assertIn("PALETTE_CHECK true", after.stdout + after.stderr)

    def test_repair_and_undo_preserve_configuration_and_system_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, system, data = root / "config", root / "system", root / "data"
            source = system / "quickshell/noctalia-shell"
            (source / "Commons").mkdir(parents=True)
            (source / "Commons/Color.qml").write_text("pragma Singleton\nimport QtQuick\nQtObject {}\n")
            original = "import QtQuick\nimport QtQuick.Layouts\nimport qs.Commons\nItem { property color c: Color.mSurface }\n"
            (source / "shell.qml").write_text(original)
            plugins = config / "noctalia/plugins"
            plugins.mkdir(parents=True)
            (plugins / "Widget.qml").write_text(original)
            settings = config / "noctalia/settings.json"
            settings.write_text('{"custom":"keep me"}')
            with patch.dict(os.environ, XDG_CONFIG_DIRS=str(system)):
                self.assertIsNone(repair.repair(config, data))
                self.assertFalse((config / "quickshell").exists())
                backup = repair.repair(config, data, apply=True)
            target = config / "quickshell/noctalia-shell"
            self.assertIn("import QtQuick 6.11\n", (target / "shell.qml").read_text())
            self.assertIn("import QtQuick.Layouts\n", (target / "shell.qml").read_text())
            self.assertEqual((source / "shell.qml").read_text(), original)
            self.assertIn("import QtQuick 6.11\n", (plugins / "Widget.qml").read_text())
            self.assertEqual(json.loads(settings.read_text()), {"custom": "keep me"})
            repair.restore(backup)
            self.assertFalse(target.exists())
            self.assertEqual((plugins / "Widget.qml").read_text(), original)
            self.assertEqual(json.loads(settings.read_text()), {"custom": "keep me"})

    def test_pin_preserves_versioned_imports_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "Test.qml"
            path.write_text("import QtQuick 2.15\nimport QtQuick // comment\nimport QtQuick.Controls\n")
            self.assertEqual(repair.pin_imports(directory), 1)
            self.assertEqual(path.read_text(), "import QtQuick 2.15\nimport QtQuick 6.11 // comment\nimport QtQuick.Controls\n")
            self.assertEqual(repair.pin_imports(directory), 0)
