#!/usr/bin/env python3
"""Import offline copies of pinned Unicode CLDR 48 locale data."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parents[1]
REVISION = "acd6d88ae493633240e19a87a721076a8a75c310"
FILES = ("ru-annotations.xml", "ru-derived.xml", "ru-main.xml", "en-main.xml", "LICENSE")
EXPECTED = {
    "ru-annotations.xml": "325bc6bb96aff4a5a9124a9087313669b0e88da920b84e261d61a402ea9405a8",
    "ru-derived.xml": "cd3aa5d40a42d473c7796584d560cac9b35f223561dd3e0e57594fec5003c010",
    "ru-main.xml": "c3c8a1c92689b2d9f9c1357e0f7329e2a3bcd105bbf92049fbe7dc5c2334d253",
    "en-main.xml": "416fb34c500e969a9e3e9bd1e363f8af5938df3cdda72aa7e636fa7e72123aae",
    "LICENSE": "b4c0ae8ef04f7059f96ce5bbe0467f9fe6f6d81bbe13517701dfeb961fb4d0b6",
}


def normalize(value):
    return value.replace("\ufe0f", "")


def build(directory):
    data = dict(revision=REVISION, sources={}, emoji={}, currencies={}, cities={})
    for filename in FILES:
        data["sources"][filename] = hashlib.sha256((directory / filename).read_bytes()).hexdigest()
        if data["sources"][filename] != EXPECTED[filename]:
            raise ValueError("CLDR file does not match pinned revision: " + filename)
    for filename in ("ru-annotations.xml", "ru-derived.xml"):
        for annotation in ET.parse(directory / filename).getroot().iter("annotation"):
            emoji = normalize(annotation.attrib.get("cp", ""))
            if not emoji or any(0x1F3FB <= ord(character) <= 0x1F3FF for character in emoji):
                continue
            value = (annotation.text or "").strip()
            if not value or value == "↑↑↑":
                continue
            key = "name" if annotation.attrib.get("type") == "tts" else "keywords"
            data["emoji"].setdefault(emoji, {})[key] = value
    roots = {language: ET.parse(directory / (language + "-main.xml")).getroot() for language in ("en", "ru")}
    for language, root in roots.items():
        for currency in root.findall(".//currencies/currency"):
            name = next((entry.text for entry in currency.findall("displayName") if "count" not in entry.attrib), None)
            if name:
                data["currencies"].setdefault(currency.attrib["type"], {})[language] = name
        for zone in root.findall(".//timeZoneNames/zone"):
            name = zone.findtext("exemplarCity")
            if name:
                data["cities"].setdefault(zone.attrib["type"], {})[language] = name
    data["currencies"] = {key: value for key, value in data["currencies"].items() if "ru" in value and "en" in value}
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Contains the five files listed in FILES")
    args = parser.parse_args()
    data = build(args.directory)
    target = PROJECT / "MacShell/Locale/UnicodeData.js"
    target.write_text(".pragma library\n// Unicode CLDR 48, Unicode License v3; see docs/licenses/unicode-cldr.txt.\nvar data = " + json.dumps(data, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + ";\n")
    license_path = PROJECT / "docs/licenses/unicode-cldr.txt"
    license_path.parent.mkdir(exist_ok=True)
    license_path.write_bytes((args.directory / "LICENSE").read_bytes())
    print("CLDR", data["revision"], "emoji", len(data["emoji"]), "currencies", len(data["currencies"]), "cities", len(data["cities"]))


if __name__ == "__main__":
    main()
