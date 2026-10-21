#!/usr/bin/env python3
"""Puts translations into the string catalogs.

    scripts/import-translations.py translations.json [more.json …]

Each file is {"languages": [...], "strings": {key: {"en": …, "<lang>": …}}}, the format the
strings are handed out for translation in (exported with xcodebuild -exportLocalizations). Keys
starting "Widget:" go to the widget's catalog and "AppShortcuts.strings:" to the Siri phrases'.
Info.plist strings (the app's name and copyright) are the same in every language and are skipped.
Existing translations are replaced; keys no longer in the app are reported and left out.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = {
    "app": ROOT / "Songtide/Resources/Localizable.xcstrings",
    "widget": ROOT / "SongtideWidget/Localizable.xcstrings",
    "shortcuts": ROOT / "Songtide/Resources/AppShortcuts.xcstrings",
}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)|\$\{applicationName\}")


def placeholders(text):
    return sorted(re.sub(r"%\d+\$", "%", p) for p in PLACEHOLDER.findall(text.replace("%%", "")))


def load(path):
    if path.exists():
        return json.loads(path.read_text())
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def route(key):
    if key.startswith("Widget:"):
        key = key[len("Widget:"):]
        return (None, None) if key.startswith("InfoPlist.strings:") else ("widget", key)
    if key.startswith("InfoPlist.strings:"):
        return None, None
    if key.startswith("AppShortcuts.strings:"):
        return "shortcuts", key[len("AppShortcuts.strings:"):]
    return "app", key


def main(files):
    catalogs = {name: load(path) for name, path in CATALOGS.items()}
    added, missing, problems = 0, [], []
    for file in files:
        data = json.loads(Path(file).read_text())
        for key, entry in data["strings"].items():
            name, catalog_key = route(key)
            if not name:
                continue
            strings = catalogs[name]["strings"]
            # The Siri phrases' catalog only holds what's imported; the others must already have the key.
            if catalog_key not in strings and name != "shortcuts":
                missing.append(key)
                continue
            unit = strings.setdefault(catalog_key, {})
            localizations = unit.setdefault("localizations", {})
            for lang in data["languages"]:
                value = (entry.get(lang) or "").strip()
                if not value:
                    continue
                if placeholders(value) != placeholders(entry["en"]):
                    problems.append(f"{lang} {key!r}: {value!r}")
                    continue
                localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}
                added += 1
    for name, path in CATALOGS.items():
        if catalogs[name]["strings"]:
            path.write_text(json.dumps(catalogs[name], ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"{added} translations in.")
    if missing:
        print(f"{len(missing)} keys no longer in the app (left out):")
        for key in missing:
            print("  ", key)
    if problems:
        print(f"{len(problems)} left out for mismatched placeholders:")
        for line in problems:
            print("  ", line)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
