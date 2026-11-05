#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fails if the keyboard could reach the network: in its source, or in a built binary.

Usage: check-offline.py [path to AzkiKeyboard.appex]
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIRECTORIES = ("Sources/Keyboard", "Sources/Core", "Sources/SharedUI")
SOURCE_CALLS = re.compile(r"URLSession|URLRequest|NSURLConnection|NWConnection|NWPathMonitor|import Network\b|"
                          r"WKWebView|AsyncImage|CFStream|CFSocket|https?://|\bsocket\(|getaddrinfo")
LINKED_FRAMEWORKS = re.compile(r"/(Network|CFNetwork|WebKit|CloudKit|SafariServices)\.framework/")
SYMBOLS = re.compile(r"URLSession|NSURLConnection|_nw_|_socket$|_connect$|_getaddrinfo$|CFHTTP|CFSocket")


def source_problems():
    for directory in SOURCE_DIRECTORIES:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if SOURCE_CALLS.search(line):
                    yield f"{path.relative_to(ROOT)}:{number}"


def binary_problems(appex):
    binary = appex / appex.stem
    linked = subprocess.run(["otool", "-L", binary], capture_output=True, text=True, check=True).stdout
    yield from (line.split()[0] for line in linked.splitlines() if LINKED_FRAMEWORKS.search(line))
    symbols = subprocess.run(["nm", "-u", binary], capture_output=True, text=True, check=True).stdout
    yield from (line.strip() for line in symbols.splitlines() if SYMBOLS.search(line))


def main():
    problems = list(source_problems())
    if len(sys.argv) > 1:
        problems += binary_problems(Path(sys.argv[1]))
    print("\n".join(problems) or "keyboard is offline")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
