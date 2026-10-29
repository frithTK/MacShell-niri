#!/usr/bin/env python3
"""Validate RU/EN catalog parity and literal translation calls in migrated sources."""
import json
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1]
FORMS = {"en": {"one", "other"}, "ru": {"one", "few", "many", "other"}}
PLACEHOLDER = re.compile(r"\{([a-zA-Z][a-zA-Z0-9_]*)\}")
CALL = re.compile(r"\b(?:I18n|i18n|translations)\.(text|plural|english)\(\s*[\"']([^\"']+)[\"']")


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate catalog key: " + key)
        result[key] = value
    return result


def read_catalog(path):
    source = re.sub(r"(?m)^\s*//[^\n]*", "", path.read_text())
    match = re.fullmatch(r"\s*\.pragma library\s+var messages = (\{[\s\S]*\});\s*", source)
    if not match:
        raise ValueError("Catalog must contain only a strict JSON messages assignment")
    return json.loads(match[1], object_pairs_hook=unique_pairs)


def placeholders(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Translation must be a nonempty string")
    if "{" in PLACEHOLDER.sub("", value) or "}" in PLACEHOLDER.sub("", value):
        raise ValueError("Malformed placeholder: " + value)
    return set(PLACEHOLDER.findall(value))


def validate(catalog):
    if not isinstance(catalog, dict) or set(catalog) != set(FORMS):
        raise ValueError("Catalog must have exactly en and ru")
    if not all(isinstance(catalog[language], dict) and catalog[language] for language in FORMS):
        raise ValueError("Each language must have a nonempty message map")
    if set(catalog["en"]) != set(catalog["ru"]):
        raise ValueError("RU/EN keys differ")
    for key, english in catalog["en"].items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+", key):
            raise ValueError("Invalid message ID: " + key)
        expected = None
        for language, forms in FORMS.items():
            value = catalog[language][key]
            if isinstance(english, dict):
                if not isinstance(value, dict) or set(value) != forms:
                    raise ValueError("Missing/invalid plural forms: " + language + ":" + key)
                values = value.values()
            else:
                if not isinstance(value, str):
                    raise ValueError("Message kind differs: " + key)
                values = [value]
            for template in values:
                params = placeholders(template)
                if expected is None:
                    expected = params
                if params != expected:
                    raise ValueError("Placeholder mismatch: " + language + ":" + key)
            if isinstance(english, dict) and "count" not in expected:
                raise ValueError("Plural requires {count}: " + key)


def validate_calls(catalog, sources):
    count = 0
    for path in sources:
        for kind, key in CALL.findall(path.read_text()):
            if key not in catalog["en"]:
                raise ValueError(str(path) + ": unknown message ID " + key)
            if isinstance(catalog["en"][key], dict) != (kind == "plural"):
                raise ValueError(str(path) + ": wrong text/plural call for " + key)
            count += 1
    return count


def main():
    catalog = read_catalog(PROJECT / "MacShell/Locale/TranslationCatalog.js")
    validate(catalog)
    sources = [path for folder in ("MacShell", "MacLock") for path in (PROJECT / folder).rglob("*")
               if path.suffix in (".qml", ".js")]
    calls = validate_calls(catalog, sources)
    print(f"Translation catalog: {len(catalog['en'])} matching RU/EN IDs; {calls} migrated literal calls checked.")
    print("Catalog integrity and literal call IDs checked; user content and external diagnostics retain their original text.")


if __name__ == "__main__":
    main()
