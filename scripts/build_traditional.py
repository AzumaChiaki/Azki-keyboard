#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Builds the simplified-to-traditional tables from OpenCC's dictionaries.

A phrase is kept only if the conversion would get it wrong without it. The Taiwan and
Hong Kong tables are a second pass over traditional text, as OpenCC's s2twp and s2hk run
them: one longest-match walk, the first dictionary winning. Prints counts only.

Usage: python3 scripts/build_traditional.py [--check]
"""
import gzip
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources/Core/Resources"
REGIONS = {"traditional-tw.tsv": ("TWPhrases", "TWVariantsPhrases", "TWVariants"),
           "traditional-hk.tsv": ("HKVariantsPhrases", "HKVariants")}


def source(name):
    return ROOT / f"DataSources/opencc-{name}-1.4.0.txt.gz"


def table(path):
    """Each simplified form with its first, most usual, traditional form."""
    with gzip.open(path, "rt", encoding="utf-8") as file:
        for line in file:
            if line.strip() and not line.startswith("#"):
                source, targets = line.rstrip("\n").split("\t")[:2]
                yield source, targets.split(" ")[0]


def convert(text, characters, phrases, longest):
    """The same longest-match walk as `TraditionalConverter`."""
    result, index = [], 0
    while index < len(text):
        for length in range(min(longest, len(text) - index), 1, -1):
            match = phrases.get(text[index:index + length])
            if match:
                result.append(match)
                index += length
                break
        else:
            result.append(characters.get(text[index], text[index]))
            index += 1
    return "".join(result)


def base_rows():
    characters = {simplified: target for simplified, target in table(source("STCharacters"))
                  if simplified != target and len(simplified) == 1}
    phrases, longest = {}, 0
    for simplified, target in sorted(table(source("STPhrases")), key=lambda pair: (len(pair[0]), pair[0])):
        if convert(simplified, characters, phrases, longest) != target:
            phrases[simplified] = target
            longest = max(longest, len(simplified))
    return sorted(characters.items()) + sorted(phrases.items())


def region_rows(names):
    rows = {}
    for name in names:
        for original, target in table(source(name)):
            rows.setdefault(original, target)
    return sorted(rows.items())


def main():
    outputs = {"traditional.tsv": base_rows()}
    outputs.update({name: region_rows(sources) for name, sources in REGIONS.items()})
    for name, rows in outputs.items():
        path = RESOURCES / name
        text = "".join(f"{original}\t{target}\n" for original, target in rows)
        if "--check" in sys.argv:
            if path.read_text(encoding="utf-8") != text:
                sys.exit(f"{name} is out of date")
            continue
        path.write_text(text, encoding="utf-8")
        print(f"{name}: {len(rows)} rows, {len(text.encode())} bytes")


if __name__ == "__main__":
    main()
