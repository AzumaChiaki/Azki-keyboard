#!/usr/bin/env python3
"""Build the emoji suggestion table from Unicode CLDR annotations.

SPDX-License-Identifier: MIT
Inputs are the pinned cldr-json 46.1.0 files in DataSources. A keyword shared by
too many emoji says nothing about any of them, so those are left out, as are flags
and keycaps. Python standard library only. Prints counts, never the table.
"""
import gzip
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/Core/Resources/emoji.json"
SOURCES = {
    "zh": ("cldr-annotations-zh-46.1.0.json.gz", "c57fcb31e7f2ace00343b8578ae30a7856270bb23dc94e5ea02f3858ed875ef2", 2),
    "en": ("cldr-annotations-en-46.1.0.json.gz", "2405d3f2e4c5812a4faf93d965630246269e0177ce907d863c7d6bb197e957c1", 3),
}
MOST_EMOJI_PER_KEYWORD = 12
KEPT_PER_KEYWORD = 3


def usable(emoji):
    points = [ord(character) for character in emoji]
    return not any(0x1F1E6 <= point <= 0x1F1FF or point == 0x20E3 for point in points)


def table(file, digest, shortest):
    raw = gzip.decompress((ROOT / "DataSources" / file).read_bytes())
    if hashlib.sha256(raw).hexdigest() != digest:
        sys.exit(f"{file} does not match its pinned digest")
    annotations = json.loads(raw)["annotations"]["annotations"]
    keywords = {}
    for emoji, fields in annotations.items():
        if not usable(emoji):
            continue
        names = fields.get("tts", [])
        for keyword in fields.get("default", []) + names:
            keyword = keyword.strip().lower()
            if len(keyword) >= shortest and " " not in keyword:
                listed = keywords.setdefault(keyword, [])
                if emoji not in listed:
                    # An emoji named for the keyword goes ahead of ones merely tagged with it.
                    listed.insert(0, emoji) if keyword in [name.lower() for name in names] else listed.append(emoji)
    return {keyword: emoji[:KEPT_PER_KEYWORD] for keyword, emoji in sorted(keywords.items())
            if len(emoji) <= MOST_EMOJI_PER_KEYWORD}


def main():
    result = {language: table(*source) for language, source in SOURCES.items()}
    text = json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
    if "--check" in sys.argv:
        if OUTPUT.read_text(encoding="utf-8") != text:
            sys.exit("emoji.json is out of date; run scripts/build_emoji.py")
        return
    OUTPUT.write_text(text, encoding="utf-8")
    print({language: len(words) for language, words in result.items()}, OUTPUT.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
