#!/usr/bin/env python3
"""Håller App/Localizable.xcstrings i takt med koden.

xcodebuild extraherar strängarna (build/…/*.stringsdata) men skriver inte in dem i
katalogen; det gör bara Xcode-gränssnittet. Det här skriptet gör det från terminalen.

  python3 scripts/strings.py check            # nycklar i koden som saknas eller saknar engelska
  python3 scripts/strings.py add översättning.json   # {"svensk nyckel": "English", …}

Kör ./scripts/build.sh (eller xcodebuild) före `check`, så att .stringsdata är färska.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "Localizable.xcstrings"


def load():
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def save(d):
    # Samma form som Xcode skriver: två blanksteg, sorterade nycklar, ingen avslutande radbrytning.
    CATALOG.write_text(json.dumps(d, indent=2, ensure_ascii=False, sort_keys=True), encoding="utf-8")


def keys_in_code():
    keys = {}
    for f in (ROOT / "build").rglob("*.stringsdata"):
        data = json.loads(f.read_text(encoding="utf-8"))
        src = pathlib.Path(data.get("source", "")).name
        for entry in data.get("tables", {}).get("Localizable", []):
            if entry["key"].strip():  # tomma etiketter (Toggle("")) översätts inte
                keys.setdefault(entry["key"], src)
    return keys


def check():
    strings = load()["strings"]
    code = keys_in_code()
    if not code:
        sys.exit("Inga .stringsdata under build/ — bygg först.")
    missing = sorted(k for k in code if k not in strings)
    untranslated = sorted(k for k, v in strings.items()
                          if "en" not in v.get("localizations", {}) and v.get("shouldTranslate", True))
    for k in missing:
        print(f"saknas: {k!r}  ({code[k]})")
    for k in untranslated:
        print(f"saknar engelska: {k!r}")
    print(f"{len(code)} nycklar i koden, {len(strings)} i katalogen, "
          f"{len(missing)} saknas, {len(untranslated)} utan engelska")
    sys.exit(1 if missing or untranslated else 0)


def add(path):
    pairs = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    d = load()
    for sv, en in pairs.items():
        d["strings"][sv] = {
            "extractionState": "extracted_with_value",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "sv": {"stringUnit": {"state": "translated", "value": sv}},
            },
        }
    save(d)
    print(f"{len(pairs)} strängar inlagda")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "check":
        check()
    elif len(sys.argv) == 3 and sys.argv[1] == "add":
        add(sys.argv[2])
    else:
        sys.exit(__doc__)
