#!/usr/bin/env python3
"""Count adjacent word pairs in a subtitle corpus, for sentence decoding.

SPDX-License-Identifier: MIT
Input is the OPUS OpenSubtitles v2018 monolingual zh_cn file, which is not
stored here; only the pruned counts are. Words are split with the lexicon's own
frequencies, so rerun this if the Chinese lexicon changes substantially.
Python standard library only. Prints counts, never corpus text.
"""
import argparse
import gzip
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
import itertools
import math
from pathlib import Path
import re
import sqlite3

LONGEST_WORD = 7
HAN = re.compile(r"[一-鿿]+")
weights = {}


def load(database):
    db = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    for surface, weight in db.execute("SELECT surface, max(weight) FROM entries WHERE language='zh' GROUP BY surface"):
        weights[surface] = math.log(max(weight, 1) / 60_000_000)


def split(text):
    """The likeliest word split under unigram frequencies."""
    best = [None] * (len(text) + 1)
    best[0] = (0.0, 0)
    for start in range(len(text)):
        if best[start] is None:
            continue
        for end in range(start + 1, min(len(text), start + LONGEST_WORD) + 1):
            weight = weights.get(text[start:end])
            if weight is not None and (best[end] is None or best[start][0] + weight > best[end][0]):
                best[end] = (best[start][0] + weight, start)
    if best[len(text)] is None:
        return None
    words, end = [], len(text)
    while end:
        start = best[end][1]
        words.append(text[start:end])
        end = start
    return words[::-1]


def count(lines):
    pairs = Counter()
    for line in lines:
        for clause in HAN.findall(line.replace(" ", "")):
            words = split(clause)
            if words:
                pairs.update(zip(words, words[1:]))
    return pairs


def chunks(stream, limit, size=20000):
    lines = itertools.islice(stream, limit)
    while chunk := list(itertools.islice(lines, size)):
        yield chunk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--database", type=Path, default=Path(__file__).resolve().parents[1] / "Resources" / "lexicon.sqlite")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "DataSources" / "zh-bigrams.tsv.gz")
    parser.add_argument("--lines", type=int, default=100_000_000)
    parser.add_argument("--keep", type=int, default=800_000)
    args = parser.parse_args()
    total = Counter()
    with gzip.open(args.corpus, "rt", encoding="utf-8", errors="ignore") as stream, \
            ProcessPoolExecutor(initializer=load, initargs=(args.database,)) as pool:
        for pairs in pool.map(count, chunks(stream, args.lines)):
            total.update(pairs)
    kept = sorted(total.items(), key=lambda item: (-item[1], item[0]))[:args.keep]
    with args.output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as out:
        for (left, right), value in sorted(kept):
            out.write(f"{left}\t{right}\t{value}\n".encode("utf-8"))
    print(f"pairs seen {len(total)}, kept {len(kept)}, smallest kept count {kept[-1][1]}, bytes {args.output.stat().st_size}")


if __name__ == "__main__":
    main()
