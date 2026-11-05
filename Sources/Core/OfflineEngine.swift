// SPDX-License-Identifier: MIT
// Original offline lookup and composition engine. This is not a Rime or Mozc implementation.
import Foundation
import SQLite3

public final class OfflineEngine: @unchecked Sendable {
    public static let maximumInputCharacters = 128
    public static let maximumCandidates = 32
    /// Source labels shown only in diagnostics and used by learning policy.
    public static let memorySource = "记忆"
    public static let dialectSource = "方言"
    private static let regionalEndings = 2
    public static let sentenceSource = "拼接"
    public static let emojiSource = "表情"
    public let isDatabaseAvailable: Bool
    private let dialectCatalog: DialectCatalog?
    private let mutex = NSLock()
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Scale of the frequency counts, which turns a count into a log probability.
    private static let corpusSize = 60_000_000.0
    private var syllables = Set<String>()
    private var syllablePrefixes = Set<String>()
    private var longestSyllable = 0
    /// Typing re-decodes the same substrings on every key.
    private var wordCache: [String: [UserWord]] = [:]
    private var followerCache: [String: [String: Int]] = [:]
    private var abbreviationCache: [String: [UserWord]] = [:]
    private var homophoneStatement: OpaquePointer?

    public init(databaseURL: URL?, dialectCatalog: DialectCatalog? = DialectCatalog.bundled()) {
        self.dialectCatalog = dialectCatalog
        var handle: OpaquePointer?
        if let databaseURL,
           sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(handle, "SELECT language, code, surface, weight FROM entries LIMIT 1", -1, &statement, nil)
            sqlite3_finalize(statement)
            if result == SQLITE_OK {
                database = handle; isDatabaseAvailable = true
                loadSyllables()
                return
            }
        }
        if let handle { sqlite3_close(handle) }
        database = nil; isDatabaseAvailable = false
    }

    deinit {
        sqlite3_finalize(homophoneStatement)
        if let database { sqlite3_close(database) }
    }

    public func preedit(input: String, language: KeyboardLanguage) -> String {
        let bounded = String(input.prefix(Self.maximumInputCharacters))
        switch language {
        case .japanese: return Romaji.hiragana(bounded)
        case .english: return bounded
        case .chinese:
            // v only stands in for ü, which is what the reader expects to see.
            guard bounded.contains(where: { $0 == "v" || $0 == "V" }) else { return bounded }
            return bounded.replacingOccurrences(of: "([jlnqxyJLNQXY])v", with: "$1ü", options: .regularExpression)
        }
    }

    public static let phraseSource = "快捷输入"

    /// Text the engine assembled rather than a dictionary surface. Learning
    /// marks these as the user's own coinages so they climb a little faster.
    public static func isSelfCreated(source: String) -> Bool {
        source == sentenceSource || source == "原文"
    }

    /// `alternatives` maps a position in `input` to the letters that touch may have
    /// meant, for keys pressed in the gap between two keys.
    public func candidates(input: String, language: KeyboardLanguage, custom: [UserWord] = [],
                           phrases: [QuickPhrase] = [], alternatives: [Int: [Character]] = [:],
                           memory: InputMemory = .empty,
                           dialectRegionID: String? = nil, emoji: Bool = false) -> [LexiconCandidate] {
        var ranked = rankedCandidates(input: input, language: language, custom: custom, phrases: phrases,
                                      alternatives: alternatives, memory: memory, dialectRegionID: dialectRegionID)
        if language == .chinese, let dialectRegionID {
            ranked = withRegionalEnding(ranked, reading: Reading.canonical(input, language: language), regionID: dialectRegionID)
        }
        return emoji ? withEmoji(ranked, input: Reading.canonical(input, language: language), language: language) : ranked
    }

    /// Where a sentence may end on what this region ends sentences with, that sentence is
    /// offered behind the likeliest one. The first place is never taken: only input memory
    /// moves it there, so someone who doesn't write this way loses nothing.
    private func withRegionalEnding(_ candidates: [LexiconCandidate], reading: String, regionID: String) -> [LexiconCandidate] {
        guard let dialectCatalog else { return candidates }
        var result = candidates
        for ending in dialectCatalog.endings(of: reading, regionID: regionID).prefix(Self.regionalEndings) {
            let opening = String(reading.dropLast(ending.reading.count))
            guard endsOnSyllable(opening, in: reading),
                  let start = rankedCandidates(input: opening, language: .chinese).first,
                  start.consumed == nil, start.source != "原文" else { continue }
            let text = start.text + ending.text
            let place = ending.tier == 3 ? 1 : 2
            if let found = result.firstIndex(where: { $0.text == text }) {
                guard found > place else { continue }
                result.remove(at: found)
            }
            result.insert(LexiconCandidate(text: text, reading: reading, source: Self.dialectSource), at: min(place, result.count))
        }
        return Array(result.prefix(Self.maximumCandidates))
    }

    /// Reading from the start in the longest syllables, so that `hua` is one and not `hu` `a`.
    private func endsOnSyllable(_ opening: String, in reading: String) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        let letters = Array(reading)
        var position = 0
        while position < opening.count {
            guard let next = syllableEnds(letters, from: position).max() else { return false }
            position = next
        }
        return position == opening.count
    }

    private func rankedCandidates(input: String, language: KeyboardLanguage, custom: [UserWord] = [],
                                  phrases: [QuickPhrase] = [], alternatives: [Int: [Character]] = [:],
                                  memory: InputMemory = .empty, dialectRegionID: String? = nil) -> [LexiconCandidate] {
        guard !input.isEmpty else { return [] }
        let raw = String(input.prefix(Self.maximumInputCharacters))
        let reading = Reading.canonical(raw, language: language)
        guard !reading.isEmpty else { return [] }
        // Positions only carry over when the reading keeps one letter per typed letter.
        let slips = raw.count == reading.count ? alternatives.filter { $0.key < reading.count } : [:]
        mutex.lock(); defer { mutex.unlock() }
        let now = Int64(Date().timeIntervalSince1970)
        let memoryMatches = memory.matches(reading: reading, language: language, now: now)
        let dialectMatches = language == .chinese
            ? (dialectCatalog?.matches(input: reading, regionID: dialectRegionID) ?? []) : []
        let dialectBoost = { (text: String) -> Double in
            let value = self.dialectCatalog?.boost(forText: text, regionID: dialectRegionID) ?? 0
            return min(Double(value) * 1.8, 9.0)
        }
        let supplemental = memory.supplementalWords(language: language, now: now)
            + (language == .chinese ? (dialectCatalog?.words(regionID: dialectRegionID) ?? []) : [])
        var results: [LexiconCandidate] = []
        var seen = Set<String>()
        var candidateLimit = Self.maximumCandidates - 2
        func append(_ text: String, _ code: String, _ source: String) {
            guard !text.isEmpty, results.count < candidateLimit, seen.insert(text).inserted else { return }
            results.append(LexiconCandidate(text: text, reading: code, source: source))
        }
        let abbreviation = QuickPhrase.normalizedAbbreviation(raw)
        let matchedPhrases = abbreviation == nil ? [] : phrases.filter { $0.abbreviation == abbreviation }
        // Work remains bounded even when callers supply an oversized in-memory custom list.
        let personal = custom.prefix(ProfileStore.maximumEntries).filter {
            $0.language == language && $0.reading.hasPrefix(reading)
        }.sorted {
            let firstExact = $0.reading == reading, secondExact = $1.reading == reading
            if firstExact != secondExact { return firstExact }
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return ($0.text, $0.reading) < ($1.text, $1.reading)
        }
        for word in personal.prefix(20) { append(word.text, word.reading, "自定义") }
        let chinese = language == .chinese && isPinyin(reading)
        // Decoding also weighs the whole input as one word, so its order is the best order.
        var decoded = Decoded(sentences: [], asTyped: nil, fallback: false, repaired: false)
        if chinese {
            decoded = decodeSentences(reading, custom: Array(custom.prefix(ProfileStore.maximumEntries)),
                                      supplemental: supplemental, slips: slips)
        }
        let sentences = decoded.sentences
        // Input that only decodes after repair may be a foreign word. Keep it in easy reach.
        let foreignWord = decoded.fallback && raw.count >= 3
            && !lookup(raw.lowercased(), language: .english, prefix: false, limit: 1).isEmpty
        if foreignWord { append(raw, raw, "原文") }
        // Input of one syllable or less is most likely aiming at one character.
        if chinese { for word in singleCharacters(reading) { append(word.text, word.reading, "词库") } }
        if let best = sentences.first { append(best, reading, Self.sentenceSource) }
        // What was actually typed stays one tap away from any correction.
        if decoded.repaired, let typed = decoded.asTyped { append(typed, reading, Self.sentenceSource) }
        // A touch between keys leaves two readings in play, whichever came first.
        if !slips.isEmpty, sentences.count > 1 { append(sentences[1], reading, Self.sentenceSource) }
        if decoded.repaired { append(raw, raw, "原文") }
        // Abbreviated words sit above the weaker readings of the same letters.
        if chinese {
            for word in abbreviationMatches(reading, limit: 20) { append(word.text, word.reading, "简拼") }
        }
        let exact = lookup(reading, language: language, prefix: false, limit: 20)
        // Rare single characters wait until the words are listed.
        var rare: [UserWord] = []
        func appendUnlessRare(_ word: UserWord) {
            if chinese, word.text.count == 1, word.weight < Self.commonCharacterWeight { rare.append(word) }
            else { append(word.text, word.reading, "词库") }
        }
        // Reserve room for a literal fallback, even when prefix lookup finds many words.
        let prefixLimit = min(chinese ? 8 : 16, max(0, Self.maximumCandidates - results.count - exact.count - 2))
        let completions = prefixLimit > 0 ? lookup(reading, language: language, prefix: true, limit: prefixLimit) : []
        if chinese {
            // Homophones and longer words compete on frequency, after the best exact match.
            if let top = exact.first { appendUnlessRare(top) }
            for word in nasalMatches(Array(reading)) { append(word.text, word.reading, "前后鼻音") }
            (exact.dropFirst() + completions).sorted { $0.weight > $1.weight }.forEach(appendUnlessRare)
        } else {
            let nearby = language == .english
                ? gapSpellings(Array(reading), slips).flatMap { lookup($0, language: .english, prefix: false, limit: 2) } : []
            (exact + nearby + completions).forEach(appendUnlessRare)
        }
        for sentence in sentences.dropFirst() { append(sentence, reading, Self.sentenceSource) }
        // Picking a word for the start keeps the rest of the input composing.
        if chinese, raw.count == reading.count {
            for (length, word) in leadingWords(reading) where results.count < candidateLimit {
                if word.text.count == 1, word.weight < Self.commonCharacterWeight { continue }
                guard seen.insert(word.text).inserted else { continue }
                results.append(LexiconCandidate(text: word.text, reading: word.reading, source: "词库", consumed: length))
            }
        }
        for word in rare { append(word.text, word.reading, "词库") }
        candidateLimit = Self.maximumCandidates
        // The user's own entries follow the best match, whatever else that input finds.
        let insertion = min(1, results.count)
        let entries = matchedPhrases.filter { phrase in !results.prefix(insertion).contains { $0.text == phrase.text } }
        results.removeAll { candidate in entries.contains { $0.text == candidate.text } }
        results.insert(contentsOf: entries.map { LexiconCandidate(text: $0.text, reading: raw, source: Self.phraseSource) },
                       at: min(insertion, results.count))
        if language == .japanese {
            append(Romaji.hiragana(raw), reading, "かな")
        }
        append(raw, raw, "原文")
        return mergeRanked(results, reading: reading, language: language, memory: memory,
                           memoryMatches: memoryMatches, dialectMatches: dialectMatches,
                           dialectBoost: dialectBoost, now: now)
    }

    /// Learning and dialects adjust the established order and nothing else, so with
    /// neither in play the order stands. A learned word can reach the first row and, once
    /// adopted again, the front. Quick phrases keep second place whatever else moves.
    private func mergeRanked(_ base: [LexiconCandidate], reading: String, language: KeyboardLanguage,
                             memory: InputMemory, memoryMatches: [InputMemoryMatch],
                             dialectMatches: [DialectMatch],
                             dialectBoost: (String) -> Double, now: Int64) -> [LexiconCandidate] {
        guard memory.count > 0 || !dialectMatches.isEmpty || base.contains(where: { dialectBoost($0.text) > 0 }) else { return base }
        var items: [(candidate: LexiconCandidate, priority: Double)] = []
        var seen = Set<String>()
        let learned = Dictionary(grouping: memory.entries.filter { $0.language == language }, by: \.text)
        let dialectSurfaces = Set(dialectMatches.map { $0.entry.text })
        for (index, original) in base.enumerated() where seen.insert(original.text).inserted {
            // If the sentence decoder already assembled the regional surface,
            // keep its established position but label the source truthfully.
            let candidate = dialectSurfaces.contains(original.text)
                ? LexiconCandidate(text: original.text, reading: original.reading,
                                   source: Self.dialectSource, consumed: original.consumed)
                : original
            var priority = Double(Self.maximumCandidates - index) + dialectBoost(candidate.text)
            // A word for the start of the input can't overtake one covering all of it,
            // or Space would commit only part of what was typed.
            if candidate.consumed == nil, let entries = learned[candidate.text] {
                let entry = entries.first { $0.reading == reading } ?? entries[0]
                let match = InputMemoryMatch(entry: entry, exact: entry.reading == reading)
                priority += min(match.boost(now: now), 7.5)
                priority = max(priority, Self.reservedPriority(match, now: now))
            }
            items.append((candidate, priority))
        }
        // Learned entries that are not in the dictionary are offered as real
        // candidates. Prefix matches are completions, never first-row leaders.
        for match in memoryMatches.prefix(6) where seen.insert(match.text).inserted {
            let priority = max(14 + min(match.boost(now: now), 10), Self.reservedPriority(match, now: now))
            items.append((LexiconCandidate(text: match.text, reading: match.reading, source: Self.memorySource), priority))
        }
        for match in dialectMatches.prefix(6) where seen.insert(match.entry.text).inserted {
            let priority = (match.kind == .exact ? 18.0 : 13.0) + match.rankingBoost
            items.append((LexiconCandidate(text: match.entry.text, reading: match.reading, source: Self.dialectSource), priority))
        }
        // A stable sort, so equal priorities keep the order they came in.
        let ranked = items.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }.map(\.element.candidate)
        var merged = ranked.filter { $0.source != Self.phraseSource }
        merged.insert(contentsOf: ranked.filter { $0.source == Self.phraseSource }, at: min(1, merged.count))
        guard merged.count > Self.maximumCandidates else { return merged }
        // The letters as typed always stay on the list.
        let literal = merged.last { $0.source == "原文" }
        var kept = Array(merged.prefix(Self.maximumCandidates))
        if let literal, !kept.contains(literal) { kept[kept.count - 1] = literal }
        return kept
    }

    /// Emoji for the likeliest words go just behind them, where a phrase's place is safe.
    private func withEmoji(_ candidates: [LexiconCandidate], input: String, language: KeyboardLanguage) -> [LexiconCandidate] {
        guard let catalog = EmojiCatalog.bundled() else { return candidates }
        let words = language == .english ? [input] : candidates.prefix(2).filter { $0.consumed == nil }.map(\.text)
        var seen = Set<String>()
        let found = words.flatMap { catalog.emoji(for: $0, language: language) }.filter { seen.insert($0).inserted }
        var result = candidates
        let suggestions = found.prefix(Self.emojiSuggestions).map { LexiconCandidate(text: $0, reading: input, source: Self.emojiSource) }
        result.insert(contentsOf: suggestions, at: min(2, result.count))
        return Array(result.prefix(Self.maximumCandidates))
    }

    /// Spellings a slide across `trace` may mean, likeliest first.
    public func glideSpellings(_ trace: GlideTrace, language: KeyboardLanguage, limit: Int = 5) -> [String] {
        guard trace.keys.count >= 2 else { return [] }
        mutex.lock(); defer { mutex.unlock() }
        let scored = language == .chinese ? pinyinGlides(trace) : wordGlides(trace, language: language)
        return Array(scored.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key))
    }

    /// Walks the pinyin a slide can spell, so only real syllables are ever looked up.
    private func pinyinGlides(_ trace: GlideTrace) -> [String: Double] {
        let keys = trace.keys
        var found: [String: Double] = [:]
        var visited = 0
        func extendable(_ text: String) -> Bool { syllablePrefixes.contains(text) || syllables.contains(text) }
        func walk(_ index: Int, _ code: [Character], _ syllableStart: Int) {
            visited += 1
            guard visited < Self.glideSearchLimit else { return }
            let current = String(code[syllableStart...])
            let whole = syllables.contains(current)
            if index == keys.count - 1 {
                if whole, let word = homophones(String(code)).first {
                    found[String(code)] = glideScore(word.weight, letters: code.count, keys: keys.count)
                }
                return
            }
            for next in (index + 1)...trace.reach(from: index) {
                let letter = keys[next]
                if extendable(current + String(letter)) { walk(next, code + [letter], syllableStart) }
                if whole, extendable(String(letter)) { walk(next, code + [letter], code.count) }
            }
        }
        if let first = keys.first, extendable(String(first)) { walk(0, [first], 0) }
        return found
    }

    private func wordGlides(_ trace: GlideTrace, language: KeyboardLanguage) -> [String: Double] {
        guard let first = trace.keys.first else { return [:] }
        var found: [String: Double] = [:]
        for word in lookup(String(first), language: language, prefix: true, limit: Self.glideWordScan) {
            let letters = Array(word.reading)
            if letters.allSatisfy({ $0.isASCII }), trace.allows(letters) {
                found[word.reading] = max(found[word.reading] ?? -.infinity,
                                          glideScore(word.weight, letters: letters.count, keys: trace.keys.count))
            }
        }
        return found
    }

    /// Frequency, plus credit for explaining more of the keys the finger crossed.
    private func glideScore(_ weight: Int, letters: Int, keys: Int) -> Double {
        log(Double(max(weight, 1))) + Self.glideCoverage * Double(letters) / Double(max(keys, 1))
    }

    /// Above everything for a word adopted repeatedly; just below the best match, which
    /// puts it in the first row, for one the user went looking for once.
    private static func reservedPriority(_ match: InputMemoryMatch, now: Int64) -> Double {
        if match.shouldLead(now: now) { return 500 }
        return match.shouldSurface(now: now) ? Double(maximumCandidates) - 1.5 : 0
    }

    private func lookup(_ code: String, language: KeyboardLanguage, prefix: Bool, limit: Int) -> [UserWord] {
        guard let database, limit > 0 else { return [] }
        let sql = prefix
            ? "SELECT code, surface, weight FROM entries WHERE language = ? AND code >= ? AND code < ? AND code != ? ORDER BY weight DESC, surface ASC LIMIT ?"
            : "SELECT code, surface, weight FROM entries WHERE language = ? AND code = ? ORDER BY weight DESC, surface ASC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, language.rawValue, -1, Self.transient)
        sqlite3_bind_text(statement, 2, code, -1, Self.transient)
        if prefix {
            sqlite3_bind_text(statement, 3, code + "\u{10FFFF}", -1, Self.transient)
            sqlite3_bind_text(statement, 4, code, -1, Self.transient)
            sqlite3_bind_int(statement, 5, Int32(limit))
        } else { sqlite3_bind_int(statement, 3, Int32(limit)) }
        var words: [UserWord] = []
        while words.count < limit, sqlite3_step(statement) == SQLITE_ROW {
            guard let reading = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { continue }
            words.append(UserWord(reading: String(cString: reading), text: String(cString: text), language: language,
                                  weight: Int(sqlite3_column_int(statement, 2))))
        }
        return words
    }

    private func isPinyin(_ reading: String) -> Bool {
        !syllables.isEmpty && reading.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
    }

    private func loadSyllables() {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT syllable FROM zh_syllables", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            let syllable = String(cString: value)
            // Vowelless interjections would turn abbreviations into "whole" pinyin.
            guard syllable.contains(where: { "aeiouv".contains($0) }) else { continue }
            syllables.insert(syllable)
            longestSyllable = max(longestSyllable, syllable.count)
            for length in 1..<max(syllable.count, 1) { syllablePrefixes.insert(String(syllable.prefix(length))) }
        }
    }

    /// Positions where a complete syllable starting at `start` can end.
    private func syllableEnds(_ letters: [Character], from start: Int) -> [Int] {
        guard start < letters.count else { return [] }
        return (1...min(longestSyllable, letters.count - start)).compactMap {
            syllables.contains(String(letters[start..<(start + $0)])) ? start + $0 : nil
        }
    }

    /// Ends of the runs of one to `maximum` whole syllables, starting at `start`.
    private func wordEnds(_ letters: [Character], from start: Int, maximum: Int) -> Set<Int> {
        var ends = Set<Int>(), frontier: Set<Int> = [start]
        for _ in 0..<maximum where !frontier.isEmpty {
            frontier = Set(frontier.flatMap { syllableEnds(letters, from: $0) })
            ends.formUnion(frontier)
        }
        return ends
    }

    private func homophones(_ code: String) -> [UserWord] {
        if let cached = wordCache[code] { return cached }
        if wordCache.count > 8192 { wordCache.removeAll(keepingCapacity: true) }
        // Repair probes thousands of spellings that are not words, so reuse one statement.
        if homophoneStatement == nil, let database {
            let sql = "SELECT surface, weight FROM entries WHERE language = 'zh' AND code = ? ORDER BY weight DESC, surface ASC LIMIT \(Self.homophoneLimit)"
            sqlite3_prepare_v2(database, sql, -1, &homophoneStatement, nil)
        }
        guard let statement = homophoneStatement else { return [] }
        sqlite3_reset(statement)
        sqlite3_bind_text(statement, 1, code, -1, Self.transient)
        var words: [UserWord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            words.append(UserWord(reading: code, text: String(cString: text), language: .chinese,
                                  weight: Int(sqlite3_column_int(statement, 1))))
        }
        wordCache[code] = words
        return words
    }

    /// Counts of the words seen after `word`. The empty key holds the total.
    private func followers(_ word: String) -> [String: Int] {
        if let cached = followerCache[word] { return cached }
        if followerCache.count > 4096 { followerCache.removeAll(keepingCapacity: true) }
        var counts: [String: Int] = [:]
        var statement: OpaquePointer?
        if let database, sqlite3_prepare_v2(database, "SELECT right_word, count FROM zh_bigrams WHERE left_word = ?", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, word, -1, Self.transient)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let right = sqlite3_column_text(statement, 0) else { continue }
                counts[String(cString: right)] = Int(sqlite3_column_int(statement, 1))
            }
        }
        sqlite3_finalize(statement)
        followerCache[word] = counts
        return counts
    }

    /// Log probability of `word` after `previous`, backing off to its own frequency.
    private func logProbability(_ word: UserWord, after previous: String?) -> Double {
        let unigram = Double(max(word.weight, 1)) / Self.corpusSize
        guard let previous else { return log(unigram) }
        let counts = followers(previous)
        guard let total = counts[""], total > 0 else { return log(unigram) }
        let bigram = Double(counts[word.text] ?? 0) / Double(total)
        return log(Self.bigramShare * bigram + (1 - Self.bigramShare) * unigram)
    }

    /// `fallback` means the input isn't whole pinyin; `repaired` means the best
    /// sentence also had to change what was typed.
    private struct Decoded { let sentences: [String]; let asTyped: String?; let fallback: Bool; let repaired: Bool }

    /// Whole pinyin always decodes as typed, so valid input can never be "repaired".
    /// Anything else may be unfinished, abbreviated or mistyped, and those compete
    /// in one search, because only the score can tell them apart.
    private func decodeSentences(_ reading: String, custom: [UserWord], supplemental: [UserWord] = [],
                                 slips: [Int: [Character]]) -> Decoded {
        let letters = Array(reading)
        guard letters.count >= 2 else { return Decoded(sentences: [], asTyped: nil, fallback: false, repaired: false) }
        var personal: [String: UserWord] = [:]
        for word in custom where word.language == .chinese {
            if personal[word.reading] == nil || word.weight > personal[word.reading]!.weight { personal[word.reading] = word }
        }
        // Learned and dialect words fill only readings that no explicit custom
        // entry already owns. They compete in the same beam as dictionary words.
        for word in supplemental where word.language == .chinese && personal[word.reading] == nil {
            personal[word.reading] = word
        }
        func decoded(_ found: [(text: String, repaired: Bool)], fallback: Bool) -> Decoded {
            Decoded(sentences: found.map(\.text), asTyped: found.first { !$0.repaired }?.text, fallback: fallback,
                    repaired: found.first?.repaired ?? false)
        }
        let clean = searchSentences(letters, personal: personal, fallback: false, slips: slips)
        if !clean.isEmpty { return decoded(clean, fallback: false) }
        return decoded(searchSentences(letters, personal: personal, fallback: true, slips: slips), fallback: true)
    }

    /// Finds the likeliest word sequences over every way of splitting the pinyin,
    /// keeping a beam of paths per position because the next word depends on the last.
    private func searchSentences(_ letters: [Character], personal: [String: UserWord], fallback: Bool,
                                 slips: [Int: [Character]]) -> [(text: String, repaired: Bool)] {
        struct Path { let text: String; let score: Double; let last: String?; let repaired: Bool }
        var beams: [Int: [String: Path]] = [0: ["": Path(text: "", score: 0, last: nil, repaired: false)]]
        func extend(_ end: Int, from path: Path, _ word: UserWord, penalty: Double = 0, repair: Bool = false) {
            let score = path.score + logProbability(word, after: path.last) - penalty
            if beams[end]?[word.text].map({ score > $0.score }) ?? true {
                beams[end, default: [:]][word.text] = Path(text: path.text + word.text, score: score, last: word.text,
                                                           repaired: path.repaired || repair)
            }
        }
        let repairable = fallback && letters.count <= Self.longestRepair
        // A typo sits at or just before the point where whole pinyin stops parsing.
        let parsed = furthestParse(letters)
        let deadline = Date().addingTimeInterval(Self.repairBudget)
        for start in 0..<letters.count {
            guard let beam = beams[start] else { continue }
            let paths = beam.values.sorted { $0.score > $1.score }.prefix(Self.beamWidth)
            let ends = wordEnds(letters, from: start, maximum: Self.longestSentenceWord)
            let nasal = nasalEdges(letters, from: start)
            let gaps = gapEdges(letters, from: start, slips)
            var completion: UserWord?
            if fallback, letters.count - start <= Self.longestCompletion {
                let tail = String(letters[start...])
                completion = (abbreviationMatches(tail, limit: 1) + lookup(tail, language: .chinese, prefix: true, limit: 1))
                    .max { $0.weight < $1.weight }
            }
            // Past the budget the search still finishes, with fewer repairs.
            let inBudget = repairable && Date() < deadline
            let abbreviated = inBudget ? abbreviationEdges(letters, from: start) : []
            let typos = inBudget && start <= parsed && parsed - start < Self.longestTypoWord
                ? typoEdges(letters, from: start) : []
            for path in paths {
                for end in ends {
                    let code = String(letters[start..<end])
                    if let owned = personal[code] { extend(end, from: path, owned) }
                    for word in homophones(code) { extend(end, from: path, word) }
                }
                for edge in nasal { extend(edge.end, from: path, edge.word, penalty: edge.penalty) }
                for edge in gaps { extend(edge.end, from: path, edge.word, penalty: edge.penalty, repair: true) }
                if let completion { extend(letters.count, from: path, completion, penalty: Self.completionPenalty) }
                for edge in abbreviated { extend(edge.end, from: path, edge.word, penalty: Self.abbreviationPenalty) }
                for edge in typos { extend(edge.end, from: path, edge.word, penalty: Self.typoPenalty, repair: true) }
                if repairable {
                    // A letter nothing explains stays as typed, so the rest still decodes.
                    let letter = String(letters[start])
                    let score = path.score - Self.strayLetterPenalty
                    if beams[start + 1]?[letter].map({ score > $0.score }) ?? true {
                        beams[start + 1, default: [:]][letter] = Path(text: path.text + letter, score: score, last: nil, repaired: true)
                    }
                }
            }
        }
        var seen = Set<String>()
        let ranked = (beams[letters.count]?.values.sorted { $0.score > $1.score } ?? [])
            .filter { seen.insert($0.text).inserted }.map { (text: $0.text, repaired: $0.repaired) }
        var best = Array(ranked.prefix(Self.sentenceCandidates))
        if !best.contains(where: { !$0.repaired }), let typed = ranked.first(where: { !$0.repaired }) { best.append(typed) }
        return best
    }

    /// Every way of reading up to `maximum` whole syllables from `start`.
    private func syllableRuns(_ letters: [Character], from start: Int, maximum: Int) -> [(end: Int, syllables: [String])] {
        var runs: [(end: Int, syllables: [String])] = []
        func walk(_ position: Int, _ syllables: [String]) {
            guard syllables.count < maximum, runs.count < 32 else { return }
            for end in syllableEnds(letters, from: position) {
                let next = syllables + [String(letters[position..<end])]
                runs.append((end, next))
                walk(end, next)
            }
        }
        walk(start, [])
        return runs
    }

    /// The same syllable with its nasal final swapped, when that syllable exists.
    private func nasalPartner(_ syllable: String) -> String? {
        let partner: String
        if syllable.hasSuffix("ng") { partner = String(syllable.dropLast()) }
        else if syllable.hasSuffix("n") { partner = syllable + "g" }
        else { return nil }
        return syllables.contains(partner) ? partner : nil
    }

    /// Words reached by swapping -n and -ng, the commonest pinyin slip. Each swap
    /// costs enough that a word spelled as typed wins unless it is far less likely.
    private func nasalEdges(_ letters: [Character], from start: Int) -> [(end: Int, word: UserWord, penalty: Double)] {
        var edges: [(end: Int, word: UserWord, penalty: Double)] = []
        for run in syllableRuns(letters, from: start, maximum: Self.longestNasalWord) {
            let swappable = run.syllables.indices.filter { nasalPartner(run.syllables[$0]) != nil }
            guard !swappable.isEmpty else { continue }
            var choices: [[Int]] = swappable.map { [$0] }
            for (offset, first) in swappable.enumerated() {
                choices += swappable[(offset + 1)...].map { [first, $0] }
            }
            for choice in choices {
                var spelled = run.syllables
                for index in choice { spelled[index] = nasalPartner(spelled[index]) ?? spelled[index] }
                let penalty = Self.nasalPenalty * Double(choice.count)
                for word in homophones(spelled.joined()) where run.syllables.count > 1 || word.text.count == 1 {
                    edges.append((run.end, word, penalty))
                }
            }
        }
        return edges
    }

    /// Words covering the whole input after a nasal swap, likeliest first.
    private func nasalMatches(_ letters: [Character]) -> [UserWord] {
        let words = nasalEdges(letters, from: 0).filter { $0.end == letters.count && $0.word.text.count > 1 }
            .map(\.word).sorted { $0.weight > $1.weight }
        return Array(words.prefix(Self.nasalCandidates))
    }

    private func furthestParse(_ letters: [Character]) -> Int {
        var reached: Set<Int> = [0], furthest = 0
        for start in 0..<letters.count where reached.contains(start) {
            for end in syllableEnds(letters, from: start) {
                reached.insert(end)
                furthest = max(furthest, end)
            }
        }
        return furthest
    }

    /// Words whose syllables start with the letters at `start`.
    private func abbreviationEdges(_ letters: [Character], from start: Int) -> [(end: Int, word: UserWord)] {
        var edges: [(end: Int, word: UserWord)] = []
        for length in 1...min(Self.longestAbbreviatedRun, letters.count - start) {
            let piece = String(letters[start..<(start + length)])
            if length >= 2 {
                edges += abbreviationMatches(piece, limit: Self.homophoneLimit).map { (start + length, $0) }
            }
            // One abbreviated syllable stands for its commonest characters.
            if syllablePrefixes.contains(piece), !syllables.contains(piece) {
                edges += lookup(piece, language: .chinese, prefix: true, limit: Self.homophoneLimit * 2)
                    .filter { $0.text.count == 1 }.map { (start + length, $0) }
            }
        }
        return edges
    }

    /// Common characters for input no longer than one syllable, likeliest first.
    private func singleCharacters(_ reading: String) -> [UserWord] {
        let whole = syllables.contains(reading)
        guard whole || syllablePrefixes.contains(reading) else { return [] }
        let words = lookup(reading, language: .chinese, prefix: !whole, limit: Self.singleCharacterScan)
        return Array(words.filter { $0.text.count == 1 && $0.weight >= Self.commonCharacterWeight }.prefix(Self.singleCharacters))
    }

    /// Whole words one typo away from the letters at `start`. Fixing the word rather
    /// than one syllable keeps the word's frequency, which is what outranks noise.
    private func typoEdges(_ letters: [Character], from start: Int) -> [(end: Int, word: UserWord)] {
        var edges: [(end: Int, word: UserWord)] = []
        let longest = min(Self.longestTypoWord, letters.count - start)
        guard longest >= 2 else { return [] }
        for length in 2...longest {
            // Most spellings aren't pinyin at all; rule those out before touching the database.
            for fixed in Set(typoFixes(Array(letters[start..<(start + length)]))) where isWholePinyin(fixed) {
                edges += homophones(fixed).map { (start + length, $0) }
            }
        }
        return edges
    }

    /// Words reached by reading a touch between two keys as the other key. Unlike a typo
    /// this is known to be in doubt, so it is cheap and applies even to valid pinyin.
    private func gapEdges(_ letters: [Character], from start: Int, _ slips: [Int: [Character]]) -> [(end: Int, word: UserWord, penalty: Double)] {
        guard !slips.isEmpty else { return [] }
        var edges: [(end: Int, word: UserWord, penalty: Double)] = []
        for length in 1...min(Self.longestTypoWord, letters.count - start) {
            let end = start + length
            guard slips.keys.contains(where: { (start..<end).contains($0) }) else { continue }
            for (spelling, changes) in respellings(letters, in: start..<end, slips) where isWholePinyin(spelling) {
                edges += homophones(spelling).map { (end, $0, Self.gapPenalty * Double(changes)) }
            }
        }
        return edges
    }

    /// The letters in `range` with up to two doubtful touches read as another key.
    private func respellings(_ letters: [Character], in range: Range<Int>, _ slips: [Int: [Character]]) -> [(String, Int)] {
        var spellings: [(letters: [Character], changes: Int)] = [(Array(letters[range]), 0)]
        for position in slips.keys.filter(range.contains).sorted().suffix(Self.gapPositions) {
            for (letters, changes) in spellings where changes < Self.gapChanges {
                for other in slips[position] ?? [] {
                    var changed = letters
                    changed[position - range.lowerBound] = other
                    spellings.append((changed, changes + 1))
                }
            }
        }
        return spellings.dropFirst().map { (String($0.letters), $0.changes) }
    }

    private func gapSpellings(_ letters: [Character], _ slips: [Int: [Character]]) -> [String] {
        respellings(letters, in: letters.indices, slips).map(\.0)
    }

    private func isWholePinyin(_ text: String) -> Bool {
        let letters = Array(text)
        guard !letters.isEmpty else { return false }
        var reachable = Array(repeating: false, count: letters.count + 1)
        reachable[0] = true
        for start in letters.indices where reachable[start] {
            for end in syllableEnds(letters, from: start) { reachable[end] = true }
        }
        return reachable[letters.count]
    }

    /// Keys touching each key on a QWERTY layout, from each row's offset.
    public static let adjacentKeys: [Character: [Character]] = {
        let rows: [(keys: [Character], offset: Double)] = [
            (Array("qwertyuiop"), 0), (Array("asdfghjkl"), 0.5), (Array("zxcvbnm"), 1.5)
        ]
        var adjacent: [Character: [Character]] = [:]
        for (row, line) in rows.enumerated() {
            for (column, key) in line.keys.enumerated() {
                for (otherRow, other) in rows.enumerated() where abs(otherRow - row) <= 1 {
                    for (otherColumn, neighbor) in other.keys.enumerated() where neighbor != key {
                        let distance = abs(Double(column) + line.offset - Double(otherColumn) - other.offset)
                        if distance <= (otherRow == row ? 1 : 0.5) { adjacent[key, default: []].append(neighbor) }
                    }
                }
            }
        }
        return adjacent
    }()

    /// The spellings one slip away from `piece`: an extra letter, a swapped pair,
    /// or a neighbouring key hit by mistake.
    private func typoFixes(_ piece: [Character]) -> [String] {
        var fixes: [String] = []
        for index in piece.indices {
            for neighbor in Self.adjacentKeys[piece[index]] ?? [] {
                var replaced = piece
                replaced[index] = neighbor
                fixes.append(String(replaced))
            }
            var shorter = piece
            shorter.remove(at: index)
            fixes.append(String(shorter))
            if index + 1 < piece.count {
                var swapped = piece
                swapped.swapAt(index, index + 1)
                fixes.append(String(swapped))
            }
        }
        return fixes
    }

    private static let longestRepair = 40
    private static let longestAbbreviatedRun = 6
    private static let repairBudget = 0.03
    private static let longestTypoWord = 13
    private static let abbreviationPenalty = 3.0
    private static let typoPenalty = 8.0
    private static let gapPenalty = 1.0
    private static let emojiSuggestions = 2
    private static let glideSearchLimit = 20_000
    private static let glideWordScan = 6_000
    private static let glideCoverage = 12.0
    private static let gapPositions = 3
    private static let gapChanges = 2
    private static let strayLetterPenalty = 16.0
    private static let longestSentenceWord = 7
    private static let longestCompletion = 12
    private static let completionPenalty = 2.0
    private static let homophoneLimit = 8
    private static let beamWidth = 6
    private static let sentenceCandidates = 3
    private static let leadingCandidates = 10
    private static let commonCharacterWeight = 1000
    private static let singleCharacters = 12
    private static let singleCharacterScan = 64
    private static let longestNasalWord = 4
    private static let nasalPenalty = 5.0
    private static let nasalCandidates = 4
    private static let bigramShare = 0.7

    /// Words matching the input when each typed piece is the start of a syllable,
    /// so "zg", "zhg" and "zhongg" all reach a two-syllable word.
    private func abbreviationMatches(_ input: String, limit: Int) -> [UserWord] {
        if let cached = abbreviationCache[input] { return Array(cached.prefix(limit)) }
        if abbreviationCache.count > 8192 { abbreviationCache.removeAll(keepingCapacity: true) }
        let matches = findAbbreviations(input)
        abbreviationCache[input] = matches
        return Array(matches.prefix(limit))
    }

    private func findAbbreviations(_ input: String) -> [UserWord] {
        let letters = Array(input)
        guard (2...Self.longestAbbreviation).contains(letters.count) else { return [] }
        var splits: [[String]] = []
        var budget = 96
        func split(from start: Int, _ pieces: [String]) {
            guard budget > 0, pieces.count <= Self.longestAbbreviation else { return }
            budget -= 1
            if start == letters.count {
                if pieces.count >= 2 { splits.append(pieces) }
                return
            }
            for length in 1...min(longestSyllable, letters.count - start) {
                let piece = String(letters[start..<(start + length)])
                if syllables.contains(piece) || syllablePrefixes.contains(piece) { split(from: start + length, pieces + [piece]) }
            }
        }
        split(from: 0, [])
        var byInitials: [String: [[String]]] = [:]
        for pieces in splits { byInitials[pieces.map { String($0.prefix(1)) }.joined(), default: []].append(pieces) }
        var matches: [String: UserWord] = [:]
        for (initials, options) in byInitials {
            for row in abbreviationRows(initials) {
                let parts = row.syllables
                let fits = options.contains { pieces in zip(pieces, parts).allSatisfy { $1.hasPrefix($0) } }
                if fits, (matches[row.word.text]?.weight ?? -1) < row.word.weight { matches[row.word.text] = row.word }
            }
        }
        return Array(matches.values.sorted {
            $0.weight != $1.weight ? $0.weight > $1.weight : $0.text < $1.text
        }.prefix(32))
    }

    private static let longestAbbreviation = 16

    private func abbreviationRows(_ initials: String) -> [(word: UserWord, syllables: [Substring])] {
        guard let database else { return [] }
        let sql = "SELECT syllables, surface, weight FROM zh_abbreviations WHERE initials = ? ORDER BY weight DESC LIMIT 200"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, initials, -1, Self.transient)
        var rows: [(word: UserWord, syllables: [Substring])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let parts = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { continue }
            let spaced = String(cString: parts)
            rows.append((UserWord(reading: spaced.replacingOccurrences(of: " ", with: ""), text: String(cString: text),
                                  language: .chinese, weight: Int(sqlite3_column_int(statement, 2))),
                         spaced.split(separator: " ")))
        }
        return rows
    }

    /// Words for the start of the input, longest first, with the letters each consumes.
    private func leadingWords(_ reading: String) -> [(Int, UserWord)] {
        let letters = Array(reading)
        let ends = wordEnds(letters, from: 0, maximum: Self.longestSentenceWord).filter { $0 < letters.count }
        return Array(ends.sorted(by: >).flatMap { end in
            lookup(String(letters[..<end]), language: .chinese, prefix: false, limit: 4).map { (end, $0) }
        }.prefix(Self.leadingCandidates))
    }
}
