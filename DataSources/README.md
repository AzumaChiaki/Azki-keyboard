# Dictionary source data and reproducible conversion

Only explicitly licensed data is imported. No old Fcitx build artifacts,
GPL-family dictionary files, upstream programs, packages, or build scripts
are used. The converter is an original MIT Python standard-library program.
Runtime uses the platform SQLite implementation.

The committed `resources.lock.json` pins the bytes and SHA-256 hashes of
all upstream inputs and required upstream notices. For Wordnik it also pins
the immutable Git commit. Official CC-CEDICT/JMdict download URLs are mutable;
the compressed originals are therefore included here. Wordnik's exact raw
text is wrapped in deterministic gzip, with the original byte hash recorded.
The converter streams JMdict XML; no expanded XML is persisted.

Run from the project root:

```sh
python3 scripts/build_dictionary.py
```

This rebuild is entirely offline. Changed or missing pinned input fails
before conversion. `Resources/dictionary-manifest.json` records raw input
entry counts, deduplicated output counts, database bytes/hash, SQLite writer
version and verified examples. The default output is `Resources/lexicon.sqlite`.
SQLite file bytes are reproducible with the same converter and SQLite writer
version; across SQLite versions compare ordered records as well as the file.

CC-CEDICT conversion keeps simplified Han entries with 1–24 characters and
valid compact alphabetic pinyin of at most 80 letters. JMdict conversion
selects common priorities (`news1`, `ichi1`, `spec1`, `spec2`, `gai1`) and
requires a shared priority marker on both sides of each kanji/reading pair.
It honors reading restrictions, keeps valid multiple readings, and emits
kana surfaces for common readings. Lookup kana must be supported hiragana
or prolonged sound marks and at most 48 characters. English retains all
lowercase ASCII words of 1–32 letters, not just an arbitrary alphabetical
first slice. The manifest distinguishes source entries from lookup pairs.

Weights are documented editorial preferences, JMdict hints, and deterministic
length/order fallbacks. They are not measured Chinese/English frequency or
a predictive language model. Only dictionary forms are supplied; this
resource layer does not implement Japanese grammar or inflection.

## Regular update procedure

The EDRDG statement requires a regular update procedure. Maintainers review
the latest official sources at least monthly and before each release:

```sh
python3 scripts/refresh_dictionary_sources.py --output /tmp/azki-dictionary-update
```

The destination must be empty and outside the project. This writes candidate
sources and a candidate lock; it does not silently update a pinned build.
Check official license statements, dates, record-count changes and hashes.
Refresh the source-header/attribution documentation. Adopt reviewed source
files, upstream notices and the candidate lock (remove the unreviewed flag),
then rebuild and run conversion tests. Review example queries and counts;
include the new manifest, all notices and new compressed originals in the
next distribution. The app remains offline and does not auto-download data.

The original ftp.edrdg.org HTTPS hostname had a certificate mismatch during
this snapshot. We used the same official archive through the certificate-
verified https://www.edrdg.org/pub/Nihongo/JMdict_e.gz endpoint; its archive
index links JMdict_e and identifies it as the Japanese/English edition.
TLS verification was not disabled.

License statements and JMdict documentation are preserved as plain text.
The refresh script strips HTML presentation, scripts and styles, retaining
documentation prose. The lock records both the upstream document hash and
the locally included text hash. Raw website HTML and MediaWiki code are
not distributed and are never executed.

## Distribution

Runtime: `Resources/lexicon.sqlite`, `Resources/dictionary-manifest.json`,
and every file in `Resources/Licenses`. Source archive additionally contains
this directory, `resources.lock.json`, and the original conversion scripts.
The adapted database is CC-BY-SA-4.0; preserve Wordnik's MIT notice as well.
Program/converter MIT licensing does not replace dictionary licenses.

The EDRDG license document mentions historical, withdrawn GPL licensing of
unrelated KANJD212/EDICTH files. This is a historical statement, not a GPL
license applied to the current Japanese/English JMdict data used here.

## Chinese ranking and sentence decoding

No Chinese word list or ranking is written by hand. Every signal comes from a
pinned open source, and quality changes come from the algorithm:

| Input | Use | License |
| --- | --- | --- |
| `jieba-dict-0.42.1.txt.gz` | word frequency | MIT |
| `wordfreq-large_zh.msgpack.gz` | word frequency from newer web and subtitle text | CC-BY-SA-4.0 |
| `unihan-kMandarin-16.0.0.txt.gz` | each character's customary reading | Unicode-3.0 |
| `zh-bigrams.tsv.gz` | counts of adjacent words | derived from OPUS OpenSubtitles v2018 |

A word keeps the larger of its two frequencies. A character's customary reading
keeps its whole frequency, and any other reading is capped by how often compound
words use it. The database stores the syllables of each word for abbreviation
matching, and every syllable the sources use, so the engine has no syllable table.

`zh-bigrams.tsv.gz` is generated, because the corpus is too large to keep here:

```sh
python3 scripts/build_bigrams.py PATH/zh_cn.txt.gz
```

## Regional dialect catalogue

The optional dialect ranking layer is `Sources/Core/Resources/dialects.json`, built by
`scripts/build_dialects.py` (run `--check` to verify it). It combines an editorial word
list with researched endings and intensifiers from `dialect-sources.json`, where each row
names its source. See [docs/DIALECT-DATA.md](../docs/DIALECT-DATA.md). It is not a complete dialect
dictionary or an academic survey corpus.

## 表情推荐

`cldr-annotations-{zh,en}-46.1.0.json.gz` 来自 Unicode CLDR（cldr-json 46.1.0，Unicode License V3），哈希锁定在 `resources.lock.json`。`scripts/build_emoji.py` 由它生成 `Sources/Core/Resources/emoji.json`：去掉国旗和按键帽，去掉同时对应超过 12 个表情的泛化关键词，每个关键词最多保留 3 个表情。

## Traditional Chinese

`opencc-STCharacters-1.4.0.txt.gz` and `opencc-STPhrases-1.4.0.txt.gz` are OpenCC 1.4.0
dictionaries (Apache-2.0). `scripts/build_traditional.py` turns them into
`Sources/Core/Resources/traditional.tsv`.
