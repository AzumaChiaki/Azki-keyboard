#!/usr/bin/env python3
"""Original offline dictionary conversion for Azki Native.

SPDX-License-Identifier: MIT
Copyright (c) 2026 AzkiInputMethod-Native contributors

Only Python's standard library is used. No upstream program is executed.
The output data retains its own MIT / CC-BY-SA-4.0 notices.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import unicodedata
import xml.etree.ElementTree as ET

COMMON = {"news1", "ichi1", "spec1", "spec2", "gai1"}
# Original editorial preferences, not corpus frequency estimates or an LM.
# These only change the order of existing source entries; they add no words.
# Rescales wordfreq's relative frequencies to jieba's corpus size.
ZH_CORPUS_SIZE = 60_000_000
ZH_MINIMUM_ADDED_FREQUENCY = 50
EN_PREFERRED = "the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us hello world help thanks please thank yes welcome name input language keyboard text word words home love water cat dog english chinese japanese test testing tomorrow today computer phone app".split()
JA_PREFERRED = {"水", "猫", "日本語", "日本", "私", "今日", "明日", "昨日", "世界", "東京", "言葉", "入力", "漢字", "学校", "仕事", "人", "ありがとう", "こんにちは", "こんばんは", "おはよう", "すみません", "お願いします", "おめでとう"}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def verify_sources(root, lock):
    for item in lock["files"]:
        path = root / item["path"]
        if not path.is_file():
            raise ValueError(f"Missing pinned input: {item['path']}")
        if path.stat().st_size != item["bytes"] or digest(path) != item["sha256"]:
            raise ValueError(f"Pinned input changed: {item['path']}; review and repin intentionally")
        if item.get("content_sha256"):
            with gzip.open(path, "rb") as stream:
                h = hashlib.sha256()
                for part in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(part)
            if h.hexdigest() != item["content_sha256"]:
                raise ValueError(f"Uncompressed input changed: {item['path']}")


def pinyin_code(text):
    # Numeric tone suffixes disappear. v is the standard keyboard substitute
    # for ü. Apostrophes and syllable spacing are omitted from lookup keys.
    text = text.lower().replace("u:", "v").replace("ü", "v")
    if not re.fullmatch(r"[a-z]+[1-5]?(?:[\s'’·-]+[a-z]+[1-5]?)*", text):
        return None
    text = re.sub(r"[1-5\s'’·-]", "", text)
    return text if re.fullmatch(r"[a-z]{1,80}", text) else None


def hiragana(text):
    text = unicodedata.normalize("NFC", text)
    return "".join(chr(ord(c) - 0x60) if 0x30A1 <= ord(c) <= 0x30F6 else c for c in text)


def usable_japanese(code, surface):
    return (1 <= len(code) <= 48 and 1 <= len(surface) <= 48
            and bool(re.fullmatch(r"[\u3041-\u3096\u309d\u309eー]+", code)))


def syllables_of(reading):
    """Tone-free syllables of a CC-CEDICT reading, or None for mixed entries."""
    parts = re.split(r"[\s'’·-]+", reading.lower().replace("u:", "v").replace("ü", "v"))
    parts = [re.sub(r"[1-5]$", "", part) for part in parts if part]
    return tuple(parts) if parts and all(re.fullmatch(r"[a-z]+", p) for p in parts) else None


def is_han(text):
    return all("CJK UNIFIED IDEOGRAPH" in unicodedata.name(c, "") or c in "〇々" for c in text)


def read_msgpack(data, position=0):
    """Decode the small MessagePack subset used by wordfreq's data files."""
    first = data[position]
    if first <= 0x7f:
        return first, position + 1
    if 0xa0 <= first <= 0xbf or first in (0xd9, 0xda):
        size, start = ((first & 31, position + 1) if first < 0xc0 else
                       (data[position + 1], position + 2) if first == 0xd9 else
                       (int.from_bytes(data[position + 1:position + 3], "big"), position + 3))
        return data[start:start + size].decode("utf-8"), start + size
    if 0x90 <= first <= 0x9f or first in (0xdc, 0xdd):
        size, position = ((first & 15, position + 1) if first < 0xa0 else
                          (int.from_bytes(data[position + 1:position + 3], "big"), position + 3) if first == 0xdc else
                          (int.from_bytes(data[position + 1:position + 5], "big"), position + 5))
        values = []
        for _ in range(size):
            value, position = read_msgpack(data, position)
            values.append(value)
        return values, position
    if 0x80 <= first <= 0x8f:
        values, position = {}, position + 1
        for _ in range(first & 15):
            key, position = read_msgpack(data, position)
            values[key], position = read_msgpack(data, position)
        return values, position
    raise ValueError(f"Unsupported MessagePack byte {first:#x}")


def word_frequencies(jieba_path, wordfreq_path):
    """Combine an older news corpus with a newer web and subtitle corpus.

    Each is blind to words the other covers, so a word keeps the larger count.
    """
    frequencies, tags = {}, {}
    with gzip.open(jieba_path, "rt", encoding="utf-8") as stream:
        for line in stream:
            fields = line.split()
            if len(fields) >= 2 and fields[1].isdigit():
                frequencies[fields[0]] = int(fields[1])
                tags[fields[0]] = fields[2] if len(fields) > 2 else ""
    with gzip.open(wordfreq_path, "rb") as stream:
        buckets = read_msgpack(stream.read())[0][1:]
    for centibels, words in enumerate(buckets):
        count = int(ZH_CORPUS_SIZE * 10 ** (-centibels / 100))
        for word in words:
            frequencies[word] = max(frequencies.get(word, 0), count)
    return frequencies, tags


def customary_readings(path):
    """Map each character to the first, most customary kMandarin reading."""
    readings = {}
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            codepoint, _field, values = line.rstrip("\n").split("\t")
            first = unicodedata.normalize("NFD", values.split()[0])
            plain = "".join(c for c in first if not unicodedata.combining(c) or c == "\u0308")
            readings[chr(int(codepoint[2:], 16))] = plain.replace("u\u0308", "v")
    return readings


def cedict_readings(path, stats):
    """Map each simplified word to its readings; True marks a proper noun."""
    readings = {}
    pattern = re.compile(r"^(\S+) (\S+) \[([^]]+)\] /(.*)/$")
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("#") or not line.strip():
                continue
            stats["source_records"] += 1
            match = pattern.match(line.rstrip("\r\n"))
            if not match:
                stats["skipped_syntax"] += 1
                continue
            _traditional, simplified, reading, _gloss = match.groups()
            code = pinyin_code(reading)
            syllables = syllables_of(reading)
            # Han text only, including extension planes. Mixed digit / Latin
            # entries are omitted instead of assigning ambiguous keyboard codes.
            if (not code or not syllables or not is_han(simplified) or not 1 <= len(simplified) <= 24
                    or len(syllables) != len(simplified)):
                stats["skipped_bounds_or_alphabet"] += 1
                continue
            stats["selected_source_records"] += 1
            stats["emitted_before_deduplication"] += 1
            proper = reading[:1].isupper()
            known = readings.setdefault(simplified, {})
            known[syllables] = known.get(syllables, True) and proper
    return readings


def compound_usage(readings, frequencies):
    """Count how often each character takes each reading inside longer words."""
    usage = {}
    for word, options in readings.items():
        if len(word) < 2:
            continue
        for syllables, proper in options.items():
            count = frequencies.get(word, 0) * (0.2 if proper else 1) / len(options)
            for character, syllable in zip(word, syllables):
                row = usage.setdefault(character, {})
                row[syllable] = row.get(syllable, 0) + count
    return usage


def character_weights(readings, frequencies, customary, usage):
    """Split a character's frequency across its readings.

    The customary reading keeps the full count. Another reading is capped by
    the compound-word evidence for it, because a character's own count mostly
    reflects its main use: 目的 says little about how often 的 alone reads di.
    """
    weights = {}
    for character, options in ((w, o) for w, o in readings.items() if len(w) == 1):
        names = {syllables[0] for syllables in options}
        frequency = frequencies.get(character, 0)
        evidence = usage.get(character, {})
        main = customary.get(character)
        if main not in names:
            main = max(sorted(names), key=lambda name: evidence.get(name, 0))
        row = {name: 0.5 * min(frequency, evidence.get(name, 0)) for name in names}
        row[main] = frequency
        weights[character] = row
    return weights


def compose_reading(word, readings, weights):
    """Compose a word missing from CC-CEDICT from its longest known parts."""
    def primary(part):
        if len(part) == 1:
            return (max(sorted(weights[part]), key=weights[part].get),)
        return min(readings[part].items(), key=lambda item: (item[1], item[0]))[0]
    syllables, start = [], 0
    while start < len(word):
        for end in range(len(word), start, -1):
            if word[start:end] in readings:
                syllables.extend(primary(word[start:end]))
                start = end
                break
        else:
            return None
    return tuple(syllables)


def chinese_lexicon(root, stats):
    """Return (code, surface, weight, syllables) rows ranked by measured usage."""
    sources = root / "DataSources"
    readings = cedict_readings(sources / "cedict.txt.gz", stats)
    frequencies, tags = word_frequencies(sources / "jieba-dict-0.42.1.txt.gz",
                                         sources / "wordfreq-large_zh.msgpack.gz")
    usage = compound_usage(readings, frequencies)
    weights = character_weights(readings, frequencies, customary_readings(sources / "unihan-kMandarin-16.0.0.txt.gz"), usage)
    rows = {}

    def add(syllables, word, weight):
        key = ("".join(syllables), word)
        if key not in rows or rows[key][0] < weight:
            rows[key] = (weight, syllables)
        # The source spells erhua as a bare r, but people type the whole syllable.
        if syllables[-1] == "r":
            add(syllables[:-1] + ("er",), word, weight)

    for word, options in readings.items():
        for syllables, proper in options.items():
            if len(word) == 1:
                weight = weights[word][syllables[0]]
            else:
                # A word's readings are rarely equally common; prefer the common noun.
                weight = frequencies.get(word, 0) * (0.2 if proper and not all(options.values()) else 1)
            add(syllables, word, max(int(weight), 1))
    for word, frequency in frequencies.items():
        if word in readings or not 2 <= len(word) <= 6 or not is_han(word):
            continue
        if frequency >= ZH_MINIMUM_ADDED_FREQUENCY and not tags.get(word, "").startswith("nr"):
            syllables = compose_reading(word, readings, weights)
            if syllables:
                add(syllables, word, frequency)
                stats["added_from_frequency_list"] = stats.get("added_from_frequency_list", 0) + 1
    return [(code, word, weight, syllables) for (code, word), (weight, syllables) in sorted(rows.items())]


def english_rows(path, stats):
    preferred = {s: 12000 - i * 10 for i, s in enumerate(EN_PREFERRED)}
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            stats["source_records"] += 1
            word = json.loads(line)
            if not isinstance(word, str) or not re.fullmatch(r"[a-z]{1,32}", word):
                stats["skipped_bounds_or_alphabet"] += 1
                continue
            stats["emitted_before_deduplication"] += 1
            stats["selected_source_records"] += 1
            # The free list has no usage-frequency field. Length is only a
            # transparent fallback tie-break heuristic for prefix completion.
            yield "en", word, word, preferred.get(word, 200 + max(0, 32 - len(word)))


def japanese_pairs(entry):
    """Yield source-supported common reading/surface pairs.

    Both spelling and reading priorities are checked for kanji pairs. The
    same common marker must occur on both sides, because upstream uses tags
    to identify particular common pairs. re_restr / re_nokanji are binding.
    """
    kanji = [(k.findtext("keb", ""), {p.text for p in k.findall("ke_pri")})
             for k in entry.findall("k_ele")]
    for reading in entry.findall("r_ele"):
        text = reading.findtext("reb", "")
        code = hiragana(text)
        rpri = {p.text for p in reading.findall("re_pri")}
        if not rpri & COMMON:
            continue
        if usable_japanese(code, text):
            # Kana remains a valid surface, including re_nokanji readings.
            yield code, text, 1100
        if reading.find("re_nokanji") is not None:
            continue
        restrictions = {p.text for p in reading.findall("re_restr")}
        for order, (surface, kpri) in enumerate(kanji):
            if restrictions and surface not in restrictions:
                continue
            shared = kpri & rpri
            if not shared & COMMON or not usable_japanese(code, surface):
                continue
            nf = [int(tag[2:]) for tag in shared if re.fullmatch(r"nf\d\d", tag or "")]
            score = 2000 + 100 * len(shared & COMMON) + (500 - 10 * min(nf) if nf else 0)
            yield code, surface, score - min(order, 20)


def japanese_rows(path, stats):
    # Iterative parsing limits memory; neither expanded XML nor glosses are
    # written to disk. ElementTree does not fetch external DTDs or execute code.
    with gzip.open(path, "rb") as stream:
        parser = ET.iterparse(stream, events=("start", "end"))
        _event, root = next(parser)
        for event, entry in parser:
            if event != "end" or entry.tag != "entry":
                continue
            stats["source_records"] += 1
            emitted = False
            for code, surface, score in japanese_pairs(entry):
                emitted = True
                stats["emitted_before_deduplication"] += 1
                yield "ja", code, surface, 12000 if surface in JA_PREFERRED else score
            if emitted:
                stats["selected_source_records"] += 1
            root.clear()


def new_stats():
    return {"source_records": 0, "selected_source_records": 0,
            "emitted_before_deduplication": 0, "skipped_syntax": 0,
            "skipped_bounds_or_alphabet": 0}


def build(root, output):
    lock = json.loads((root / "resources.lock.json").read_text())
    verify_sources(root, lock)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".building.sqlite")
    if temporary.exists():
        temporary.unlink()
    connection = sqlite3.connect(temporary)
    connection.execute("PRAGMA page_size=4096")
    connection.execute("PRAGMA journal_mode=OFF")
    connection.execute("PRAGMA synchronous=OFF")
    connection.execute("PRAGMA user_version=2")
    connection.execute("CREATE TABLE entries (language TEXT NOT NULL CHECK(language IN ('zh','en','ja')), code TEXT NOT NULL, surface TEXT NOT NULL, weight INTEGER NOT NULL)")
    connection.execute("CREATE UNIQUE INDEX unique_entry ON entries(language, code, surface)")
    stats = {language: new_stats() for language in ("en", "ja", "zh")}
    converters = [("en", english_rows, "wordlist-20210729.txt.gz"),
                  ("ja", japanese_rows, "JMdict_e.gz")]
    for language, convert, name in converters:
        connection.executemany("INSERT INTO entries VALUES(?,?,?,?) ON CONFLICT(language,code,surface) DO UPDATE SET weight=max(weight,excluded.weight)",
                               convert(root / "DataSources" / name, stats[language]))
    chinese = chinese_lexicon(root, stats["zh"])
    connection.executemany("INSERT INTO entries VALUES('zh',?,?,?)", ((c, w, n) for c, w, n, _s in chinese))
    # Abbreviations match the first letters of syllables, then the typed pieces.
    # Words with no measured usage stay out, because they only add noise here.
    connection.execute("CREATE TABLE zh_abbreviations (initials TEXT NOT NULL, syllables TEXT NOT NULL, surface TEXT NOT NULL, weight INTEGER NOT NULL)")
    connection.executemany("INSERT INTO zh_abbreviations VALUES(?,?,?,?)",
                           [("".join(s[0] for s in syllables), " ".join(syllables), word, weight)
                            for _c, word, weight, syllables in chinese if len(syllables) >= 2 and weight > 1])
    connection.execute("CREATE INDEX zh_abbreviations_initials ON zh_abbreviations(initials, weight DESC)")
    # Word pairs for sentence decoding. An empty right word holds the left word's total.
    connection.execute("CREATE TABLE zh_bigrams (left_word TEXT NOT NULL, right_word TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(left_word, right_word)) WITHOUT ROWID")
    pairs, totals = [], {}
    with gzip.open(root / "DataSources" / "zh-bigrams.tsv.gz", "rt", encoding="utf-8") as stream:
        for line in stream:
            left, right, count = line.rstrip("\n").split("\t")
            pairs.append((left, right, int(count)))
            totals[left] = totals.get(left, 0) + int(count)
    connection.executemany("INSERT INTO zh_bigrams VALUES(?,?,?)", pairs)
    connection.executemany("INSERT INTO zh_bigrams VALUES(?,'',?)", sorted(totals.items()))
    # Every syllable the sources use, so the engine can split pinyin without its own table.
    connection.execute("CREATE TABLE zh_syllables (syllable TEXT PRIMARY KEY) WITHOUT ROWID")
    connection.executemany("INSERT INTO zh_syllables VALUES(?)",
                           [(s,) for s in sorted({s for row in chinese for s in row[3]})])
    # The dedicated prefix index has the exact requested columns.
    connection.execute("CREATE INDEX entries_language_code ON entries(language, code)")
    connection.execute("DROP INDEX unique_entry")
    connection.commit()
    connection.execute("VACUUM")
    for language in stats:
        stats[language]["output_rows"] = connection.execute("SELECT count(*) FROM entries WHERE language=?", (language,)).fetchone()[0]
        stats[language]["distinct_codes"] = connection.execute("SELECT count(DISTINCT code) FROM entries WHERE language=?", (language,)).fetchone()[0]
    assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    examples = [("zh", "nihao", "你好"), ("zh", "zhongguo", "中国"),
                ("zh", "shijie", "世界"), ("zh", "wo", "我"),
                ("zh", "ai", "爱"), ("zh", "zhege", "这个"),
                ("ja", "みず", "水"), ("ja", "ねこ", "猫"),
                ("ja", "にほんご", "日本語"), ("ja", "ありがとう", "ありがとう"),
                ("ja", "こんにちは", "こんにちは"), ("en", "hello", "hello")]
    for example in examples:
        assert connection.execute("SELECT 1 FROM entries WHERE language=? AND code=? AND surface=?", example).fetchone(), example
    connection.close()
    temporary.replace(output)
    manifest = {
        "format_version": 1, "file": output.name, "sha256": digest(output),
        "bytes": output.stat().st_size, "total_entries": sum(s["output_rows"] for s in stats.values()),
        "languages": stats, "source_snapshot_date_utc": lock["retrieved_date_utc"],
        "sqlite_writer_version": sqlite3.sqlite_version,
        "data_licenses": {"en": "MIT (Wordnik)", "ja": "CC-BY-SA-4.0 (JMdict / EDRDG)", "zh": "CC-BY-SA-4.0 (CC-CEDICT, wordfreq); MIT (jieba); Unicode-3.0 (Unihan)"},
        "adapted_database_license": "CC-BY-SA-4.0; Wordnik MIT attribution remains applicable to English rows",
        "ranking": "Chinese uses jieba and wordfreq frequencies; a character's customary reading comes from Unihan and other readings are capped by compound-word usage. Japanese and English keep editorial boosts, JMdict priority hints and deterministic fallbacks. No learned language model.",
        "lookup_codes": {"zh": "compact lowercase numeric-tone-free pinyin; ü/u: becomes v; simplified Han surfaces", "ja": "hiragana lookup; permitted common kanji and kana surfaces", "en": "lowercase ASCII word prefix"},
        "verified_examples": [{"language": l, "code": c, "surface": s} for l, c, s in examples],
        "notices": "Licenses/ATTRIBUTION.txt", "rebuild": "python3 scripts/build_dictionary.py"
    }
    (output.parent / "dictionary-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"entries": manifest["total_entries"], "bytes": manifest["bytes"], "languages": stats}, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    build(args.root, args.output or args.root / "Resources" / "lexicon.sqlite")


if __name__ == "__main__":
    main()
