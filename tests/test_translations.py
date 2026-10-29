import importlib.util
from pathlib import Path
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("translation_check", PROJECT / "scripts/check-translations.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class TranslationCatalogTests(unittest.TestCase):
    def setUp(self):
        self.catalog = check.read_catalog(PROJECT / "MacShell/Locale/TranslationCatalog.js")

    def test_shipped_catalog_and_migrated_calls(self):
        check.validate(self.catalog)
        sources = [path for folder in ("MacShell", "MacLock") for path in (PROJECT / folder).rglob("*")
                   if path.suffix in (".qml", ".js")]
        self.assertGreater(check.validate_calls(self.catalog, sources), 0)

    def test_missing_translation_rejected(self):
        del self.catalog["ru"]["common.apply"]
        with self.assertRaisesRegex(ValueError, "keys differ"):
            check.validate(self.catalog)

    def test_placeholder_mismatch_rejected(self):
        self.catalog["ru"]["language.app_restart"] = "Перезапустите {application}"
        with self.assertRaisesRegex(ValueError, "Placeholder mismatch"):
            check.validate(self.catalog)

    def test_missing_russian_plural_form_rejected(self):
        del self.catalog["ru"]["clock.timers_count"]["few"]
        with self.assertRaisesRegex(ValueError, "plural forms"):
            check.validate(self.catalog)

    def test_plural_kind_mismatch_rejected(self):
        self.catalog["ru"]["common.apply"] = {"one": "Применить"}
        with self.assertRaisesRegex(ValueError, "kind differs"):
            check.validate(self.catalog)

    def test_bad_placeholder_rejected(self):
        self.catalog["ru"]["common.apply"] = "Применить {wrong"
        with self.assertRaisesRegex(ValueError, "Malformed placeholder"):
            check.validate(self.catalog)

    def test_duplicate_ids_rejected_in_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Catalog.js"
            path.write_text('.pragma library\nvar messages = {"en": {"x.y": "One", "x.y": "Two"}};\n')
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                check.read_catalog(path)

    def test_unknown_and_wrong_kind_calls_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Pane.qml"
            for call, message in [('i18n.text("unknown.key")', "unknown message"),
                                  ('root.translations.text("clock.timers_count")', "wrong text/plural"),
                                  ('i18n.plural("common.apply", 2)', "wrong text/plural")]:
                with self.subTest(call=call):
                    path.write_text(call)
                    with self.assertRaisesRegex(ValueError, message):
                        check.validate_calls(self.catalog, [path])


if __name__ == "__main__":
    unittest.main()
