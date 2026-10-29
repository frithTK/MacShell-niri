import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "MacShell"))
import locale_preferences as locale
import locale_service


class LocalePreferencesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "environment.d/90-macshell-locale.conf"
        self.locales = ["C", "en_US.utf8", "ru_RU.utf8"]
        self.preferences = locale.Preferences(self.path, self.locales, {"LANG": "en_US.utf8", "LC_TIME": "en_GB.UTF-8"})
        self.russian = dict(ui="ru", session="ru_RU.utf8", region="system")

    def test_one_atomic_document_for_ui_and_session_preserves_regional_overrides(self):
        state = self.preferences.save(self.russian, "missing")
        values, environment = locale.parse(self.path.read_bytes())
        self.assertEqual(values, self.russian)
        self.assertEqual(environment["LANG"], "ru_RU.utf8")
        self.assertEqual(environment["LC_MESSAGES"], "ru_RU.utf8")
        self.assertNotIn("LC_TIME", environment)
        self.assertTrue(state["pending"])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(state["current"]["LC_TIME"], "en_GB.UTF-8")

    def test_region_independent_of_interface_and_messages(self):
        values = dict(self.russian, region="en_US.utf8")
        self.preferences.save(values, "missing")
        _, environment = locale.parse(self.path.read_bytes())
        self.assertEqual(environment["LANG"], "ru_RU.utf8")
        self.assertTrue(all(environment[key] == "en_US.utf8" for key in locale.REGIONAL))

    def test_missing_locale_and_injection_leave_document_unchanged(self):
        for value in ("de_DE.utf8", "ru_RU.utf8\nPATH=/tmp", "$(touch /tmp/not-created)", "../ru_RU"):
            with self.subTest(value=value), self.assertRaises(locale.LocaleError):
                self.preferences.save(dict(self.russian, session=value), "missing")
            self.assertFalse(self.path.exists())

    def test_lc_all_conflict_blocks_session_change_but_allows_ui_only(self):
        preferences = locale.Preferences(self.path, self.locales, {"LC_ALL": "C.UTF-8"})
        with self.assertRaisesRegex(locale.LocaleError, "lc_all_conflict"):
            preferences.save(self.russian, "missing")
        preferences.save(dict(ui="ru", session="system", region="system"), "missing")
        self.assertEqual(locale.parse(self.path.read_bytes())[0]["ui"], "ru")

    def test_two_writers_and_exact_backup(self):
        old = self.preferences.save(self.russian, "missing")
        previous = self.path.read_bytes()
        other = locale.Preferences(self.path, self.locales, {})
        other.save(dict(self.russian, region="en_US.utf8"), old["token"])
        with self.assertRaisesRegex(locale.LocaleError, "conflict"):
            self.preferences.save(dict(self.russian, ui="en"), old["token"])
        self.assertEqual(self.path.with_suffix(".conf.previous").read_bytes(), previous)

    def test_future_unowned_corrupt_and_symlink_are_preserved(self):
        self.path.parent.mkdir()
        for raw in (b"# MacShell locale preferences v2\n", b"LANG=en_US.utf8\n", b"\xff"):
            with self.subTest(raw=raw):
                self.path.write_bytes(raw)
                with self.assertRaises(locale.LocaleError):
                    self.preferences.save(self.russian, locale.token(raw))
                self.assertEqual(self.path.read_bytes(), raw)
        target = self.path.parent / "owned-elsewhere"
        target.write_bytes(b"untouched")
        self.path.unlink(); self.path.symlink_to(target)
        with self.assertRaisesRegex(locale.LocaleError, "symlink"):
            self.preferences.load()
        self.assertEqual(target.read_bytes(), b"untouched")

    def test_failed_replace_retains_both_ui_and_environment(self):
        state = self.preferences.save(self.russian, "missing")
        original = self.path.read_bytes()
        real_replace = os.replace
        def replace(source, target):
            if target == self.path:
                raise OSError("owned failure")
            return real_replace(source, target)
        with patch.object(locale.os, "replace", side_effect=replace):
            with self.assertRaises(OSError):
                self.preferences.save(dict(self.russian, ui="en"), state["token"])
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(list(self.path.parent.glob(".macshell-locale-*")))

    def test_removed_locale_does_not_prevent_editing(self):
        self.preferences.save(self.russian, "missing")
        other = locale.Preferences(self.path, ["C", "en_US.utf8"], {})
        state = other.load()
        self.assertEqual(state["missing"], ["ru_RU.utf8"])
        other.save(dict(ui="en", session="en_US.utf8", region="system"), state["token"])

    def test_real_session_helper_emits_only_safe_locale_assignments(self):
        self.preferences.save(dict(self.russian, session="C"), "missing")
        project = Path(__file__).resolve().parents[1]
        env = dict(os.environ, XDG_CONFIG_HOME=self.directory.name)
        env.pop("LC_ALL", None)
        result = subprocess.run([sys.executable, str(project / "scripts/session_locale.py")], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(exported["LANG"], "C")
        self.assertTrue(set(exported) <= locale.ALLOWED)
        # Actual libc process, with no changes to the current desktop/user manager.
        child = subprocess.run(["locale"], env=dict(env, **exported), capture_output=True, text=True, timeout=5)
        self.assertIn("LC_MESSAGES=", child.stdout)
        self.assertIn("LANG=C", child.stdout)

    def service(self):
        service = locale_service.LocaleService.__new__(locale_service.LocaleService)
        service.preferences = self.preferences
        messages = []
        service.emit = lambda **message: messages.append(message)
        return service, messages

    def test_reload_refreshes_installed_locales(self):
        service, messages = self.service()
        with patch.object(locale_service, "installed_locales", return_value=["C", "de_DE.utf8"]):
            service.command({"action": "load", "id": 1})
        self.assertEqual(messages[0]["locales"], ["C", "de_DE.utf8"])
        self.assertTrue(messages[-1]["success"])

    def test_save_rejects_locale_removed_after_opening_settings(self):
        service, messages = self.service()
        with patch.object(locale_service, "installed_locales", return_value=["C"]):
            service.command({"action": "save", "id": 1, "data": {"values": self.russian, "token": "missing"}})
        self.assertEqual(messages[-1]["code"], "locale_missing")
        self.assertFalse(self.path.exists())

    def test_registry_timeout_returns_a_code_without_writing(self):
        service, messages = self.service()
        with patch.object(locale_service, "installed_locales", side_effect=subprocess.TimeoutExpired("locale", 4)):
            service.command({"action": "load", "id": 1})
        self.assertEqual(messages[-1]["code"], "locale_query_failed")
        self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
