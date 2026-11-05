#!/usr/bin/env python3
"""Download candidate dictionary updates for review; never overwrite the project.
SPDX-License-Identifier: MIT
Copyright (c) 2026 AzkiInputMethod-Native contributors
"""
import argparse
import datetime
import gzip
import hashlib
import json
from html.parser import HTMLParser
from pathlib import Path
import re
import urllib.request


def document_text(payload):
    """Keep licensed documentation prose, never website JS/CSS code."""
    class Extractor(HTMLParser):
        def __init__(self):
            super().__init__()
            self.parts, self.ignore = [], 0

        def handle_starttag(self, tag, attrs):
            if tag in ("style", "script"):
                self.ignore += 1
            if tag in ("p", "h1", "h2", "h3", "br", "li", "div", "tr"):
                self.parts.append("\n")

        def handle_endtag(self, tag):
            if tag in ("style", "script"):
                self.ignore -= 1
            if tag in ("p", "h1", "h2", "h3", "li", "div", "tr"):
                self.parts.append("\n")

        def handle_data(self, data):
            if not self.ignore:
                self.parts.append(data)

    parser = Extractor()
    parser.feed(payload.decode("utf-8"))
    text = re.sub(r"\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", "".join(parser.parts))
    return (text.strip() + "\n").encode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="new empty directory outside this project")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    target = args.output.resolve()
    if target == root or root in target.parents or (target.exists() and any(target.iterdir())):
        parser.error("--output must be a new or empty directory outside the project")
    lock = json.loads((root / "resources.lock.json").read_text())
    lock["retrieved_date_utc"] = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    lock["review_status"] = "UNREVIEWED UPDATE CANDIDATE: inspect licenses and changes before adoption"
    for item in lock["files"]:
        # Downloads are data / notices only. HTTPS certificate verification is
        # active; no upstream shell commands, parsers or build programs run.
        with urllib.request.urlopen(item["url"], timeout=120) as response:
            payload = response.read(32 * 1024 * 1024 + 1)
        if len(payload) > 32 * 1024 * 1024:
            raise ValueError("Unexpectedly large source; inspect manually")
        if item.get("extract_html_text"):
            item["upstream_bytes"] = len(payload)
            item["upstream_sha256"] = hashlib.sha256(payload).hexdigest()
            payload = document_text(payload)
        if item.get("local_gzip_wrapper"):
            item["content_sha256"] = hashlib.sha256(payload).hexdigest()
            payload = gzip.compress(payload, compresslevel=9, mtime=0)
        elif item["path"].endswith(".gz"):
            expanded = gzip.decompress(payload)
            item["content_sha256"] = hashlib.sha256(expanded).hexdigest()
            if item["path"].endswith("cedict.txt.gz"):
                date = re.search(rb"^#! date=(.+)$", expanded, flags=re.MULTILINE)
                lock["source_versions"]["CC-CEDICT"] = date.group(1).decode() if date else "inspect source header"
            elif item["path"].endswith("JMdict_e.gz"):
                date = re.search(rb"JMdict created: ([\d-]+)", expanded[:100000])
                lock["source_versions"]["JMdict_e"] = date.group(1).decode() if date else "inspect XML creation comment"
        path = target / item["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        item["bytes"] = len(payload)
        item["sha256"] = hashlib.sha256(payload).hexdigest()
    (target / "resources.lock.candidate.json").write_text(json.dumps(lock, indent=2) + "\n")
    print(f"Review downloads, official license statements and diffs in {target}.")
    print("Refresh generated notices, test conversion, then deliberately adopt reviewed files and lock.")


if __name__ == "__main__":
    main()
