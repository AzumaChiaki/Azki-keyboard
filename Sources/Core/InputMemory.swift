// SPDX-License-Identifier: MIT
// Original, bounded on-device candidate memory. Only adopted text is stored;
// unfinished drafts and surrounding document context are never recorded.
import Foundation

public enum InputMemoryKind: String, Codable, Hashable, Sendable {
    /// The user tapped this candidate.
    case candidate
    /// The user committed the composition as a whole (space, punctuation or return).
    case committed
    /// Several tapped pieces were joined into one phrase in a single composition.
    case composed
}

public struct InputMemoryEntry: Codable, Hashable, Sendable {
    public var language: KeyboardLanguage
    public var reading: String
    public var text: String
    public var kind: InputMemoryKind
    public var selections: Int
    public var exposures: Int
    public var recentSelections: Double
    public var recentExposures: Double
    /// A bounded score that a deep-rank adoption pushes up. Ignored exposures
    /// pull it back down, so a once-useful word does not stay pinned forever.
    public var promotion: Double
    public var bestRank: Int?
    public var lastRank: Int?
    public var created: Int64
    public var lastUsed: Int64
    /// Not present in the bundled dictionary when first learned. These are the
    /// user's own coinages and receive a small head start as they prove useful.
    public var userCreated: Bool

    public init(language: KeyboardLanguage, reading: String, text: String,
                kind: InputMemoryKind = .candidate, selections: Int = 0,
                exposures: Int = 0, recentSelections: Double = 0,
                recentExposures: Double = 0, promotion: Double = 0,
                bestRank: Int? = nil, lastRank: Int? = nil,
                created: Int64 = 0, lastUsed: Int64 = 0, userCreated: Bool = false) {
        self.language = language
        self.reading = reading
        self.text = text
        self.kind = kind
        self.selections = selections
        self.exposures = exposures
        self.recentSelections = recentSelections
        self.recentExposures = recentExposures
        self.promotion = promotion
        self.bestRank = bestRank
        self.lastRank = lastRank
        self.created = created
        self.lastUsed = lastUsed
        self.userCreated = userCreated
    }

    public var adoptionRate: Double {
        guard recentExposures > 0 else { return 0 }
        return min(1, max(0, recentSelections / recentExposures))
    }

    /// The small, continuous part of the score. The discrete promotion value
    /// carries the "appeared after several rounds" signal; this carries
    /// familiarity and recent adoption. Both are damped by time.
    public func rankingBoost(now: Int64) -> Double {
        guard selections > 0 else { return 0 }
        let age = max(0, Double(now - lastUsed)) / 86_400
        let recency = exp(-age / 45.0)
        guard recency > 0.02 else { return 0 }
        let familiarity = log1p(Double(selections))
        let rate = adoptionRate
        let base = (userCreated ? 1.5 : 0.4) + familiarity * 2.2 + rate * 1.4
        return (promotion * 0.65 + base) * recency * (0.45 + 0.55 * rate)
    }

    /// A high-promotion entry earns a place in the first row. This is deliberately
    /// gated by recent adoption: a word that is shown repeatedly and skipped
    /// loses its reservation within a few compositions.
    public func shouldSurface(now: Int64) -> Bool {
        guard selections > 0, promotion >= 9 else { return false }
        guard adoptionRate >= 0.2 else { return false }
        let age = max(0, Double(now - lastUsed)) / 86_400
        return exp(-age / 60.0) >= 0.25
    }

    /// Opening the bar means Space commits it, so one adoption is not enough.
    public func shouldLead(now: Int64) -> Bool {
        selections >= 2 && shouldSurface(now: now)
    }

    fileprivate var key: String { language.rawValue + "\u{1F}" + reading + "\u{1F}" + text }
}

public struct InputMemoryMatch: Hashable, Sendable {
    public let entry: InputMemoryEntry
    public let exact: Bool

    public var reading: String { entry.reading }
    public var text: String { entry.text }
    public var language: KeyboardLanguage { entry.language }
    public var userCreated: Bool { entry.userCreated }

    public func boost(now: Int64) -> Double {
        let value = entry.rankingBoost(now: now)
        return exact ? value : value * 0.55
    }

    public func shouldSurface(now: Int64) -> Bool {
        exact && entry.shouldSurface(now: now)
    }

    public func shouldLead(now: Int64) -> Bool {
        exact && entry.shouldLead(now: now)
    }
}

public enum InputMemoryEvent: Sendable {
    case exposure(language: KeyboardLanguage, reading: String, text: String)
    case selection(language: KeyboardLanguage, reading: String, text: String,
                   rank: Int, userCreated: Bool)
    case composition(language: KeyboardLanguage, reading: String, text: String,
                     rank: Int, userCreated: Bool)
}

/// A value snapshot. The controller builds a snapshot, passes it to the engine,
/// and writes the next snapshot after a selection or exposure batch.
public struct InputMemory: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEntries = 3_000
    /// Words and phrases, not sentences: memory must not become a record of what was written.
    public static let maximumTextCharacters = 12
    public static let maximumReadingCharacters = 128

    private static let eventDecay = 0.90
    private static let maximumPromotion = 30.0

    public var version: Int
    public private(set) var entries: [InputMemoryEntry]

    public init(version: Int = InputMemory.currentVersion, entries: [InputMemoryEntry] = []) {
        self.version = version
        self.entries = entries
    }

    public static let empty = InputMemory()

    public var count: Int { entries.count }

    public func entry(text: String, reading: String, language: KeyboardLanguage) -> InputMemoryEntry? {
        let surface = text.precomposedStringWithCanonicalMapping
        let code = Reading.canonical(reading, language: language)
        if let exact = entries.first(where: {
            $0.language == language && $0.text == surface && $0.reading == code
        }) { return exact }
        return entries.first { $0.language == language && $0.text == surface }
    }

    public func contains(text: String, language: KeyboardLanguage) -> Bool {
        let surface = text.precomposedStringWithCanonicalMapping
        return entries.contains { $0.language == language && $0.text == surface }
    }

    /// Exact code matches can lead the bar. Prefix matches are offered as
    /// completions but never receive the first-row reservation.
    public func matches(reading: String, language: KeyboardLanguage, now: Int64,
                        limit: Int = 8) -> [InputMemoryMatch] {
        guard limit > 0 else { return [] }
        let code = Reading.canonical(reading, language: language)
        guard !code.isEmpty else { return [] }
        var exact: [InputMemoryMatch] = []
        var completions: [InputMemoryMatch] = []
        for entry in entries where entry.language == language {
            if entry.reading == code {
                exact.append(InputMemoryMatch(entry: entry, exact: true))
            } else if code.count >= 2, entry.reading.hasPrefix(code),
                      entry.reading.count <= code.count + 12 {
                completions.append(InputMemoryMatch(entry: entry, exact: false))
            }
        }
        exact.sort { $0.boost(now: now) > $1.boost(now: now) }
        completions.sort { $0.boost(now: now) > $1.boost(now: now) }
        return Array((exact + completions).prefix(limit))
    }

    /// Words supplied to the Chinese sentence decoder. They are ranked below
    /// explicit custom words by the engine but can still carry a whole learned
    /// phrase when the user types its reading.
    public func supplementalWords(language: KeyboardLanguage, now: Int64) -> [UserWord] {
        var best: [String: UserWord] = [:]
        for entry in entries where entry.language == language && entry.selections > 0 {
            let age = max(0, Double(now - entry.lastUsed)) / 86_400
            let recency = exp(-age / 60.0)
            guard recency > 0.05 else { continue }
            let raw = 5_000 + entry.promotion * 1_500
                + Double(min(entry.selections, 20)) * 300
                + (entry.userCreated ? 800 : 0)
            let weight = max(1, min(120_000, Int((raw * recency).rounded())))
            let word = UserWord(reading: entry.reading, text: entry.text,
                                language: language, weight: weight)
            if let current = best[entry.reading], current.weight >= weight { continue }
            best[entry.reading] = word
        }
        return best.values.sorted { ($0.reading, $0.text) < ($1.reading, $1.text) }
    }

    public func record(events: [InputMemoryEvent],
                       now: Int64 = Int64(Date().timeIntervalSince1970)) -> InputMemory {
        var updated = self
        updated.apply(events, now: now)
        return updated
    }

    public func pruned(now: Int64 = Int64(Date().timeIntervalSince1970)) -> InputMemory {
        var memory = normalized()
        // A word that has never been adopted again for over a year, or that has
        // only one old use, stops consuming the fixed storage budget.
        memory.entries.removeAll {
            $0.selections < 2 && now - $0.lastUsed > 400 * 86_400
        }
        if memory.entries.count > Self.maximumEntries {
            let ranked = memory.entries.enumerated().sorted {
                let left = $0.element.rankingBoost(now: now)
                let right = $1.element.rankingBoost(now: now)
                if left != right { return left > right }
                if $0.element.lastUsed != $1.element.lastUsed { return $0.element.lastUsed > $1.element.lastUsed }
                return $0.offset < $1.offset
            }.prefix(Self.maximumEntries)
            memory.entries = ranked.map { $0.element }
        }
        memory.sortEntries()
        return memory
    }

    public mutating func clear() {
        entries = []
    }

    private mutating func apply(_ events: [InputMemoryEvent], now: Int64) {
        // An exposure for a word adopted in the same batch must not be counted
        // twice. The selection itself records one exposure.
        var selectedKeys = Set<String>()
        for event in events {
            switch event {
            case .selection(let language, let reading, let text, _, _),
                 .composition(let language, let reading, let text, _, _):
                selectedKeys.insert(key(language: language, reading: reading, text: text))
            case .exposure:
                break
            }
        }
        for event in events {
            switch event {
            case .exposure(let language, let reading, let text):
                let eventKey = key(language: language, reading: reading, text: text)
                guard !selectedKeys.contains(eventKey) else { continue }
                guard let index = index(of: eventKey) else { continue }
                var entry = entries[index]
                applyExposure(&entry)
                entries[index] = entry
            case .selection(let language, let reading, let text, let rank, let userCreated):
                applyAdoption(language: language, reading: reading, text: text, rank: rank,
                              userCreated: userCreated, kind: .candidate, now: now)
            case .composition(let language, let reading, let text, let rank, let userCreated):
                applyAdoption(language: language, reading: reading, text: text, rank: rank,
                              userCreated: userCreated, kind: .composed, now: now)
            }
        }
    }

    private mutating func applyExposure(_ entry: inout InputMemoryEntry) {
        let priorRate = entry.adoptionRate
        entry.exposures = min(1_000_000, entry.exposures + 1)
        entry.recentExposures = min(1_000, entry.recentExposures * Self.eventDecay + 1)
        // Ignored exposures drain promotion faster than adopted ones. The word
        // remains available and keeps its history, but loses its reserved slot.
        entry.promotion = max(0, entry.promotion * (0.72 + 0.23 * priorRate))
    }

    private mutating func applyAdoption(language: KeyboardLanguage, reading: String, text: String,
                                       rank: Int, userCreated: Bool, kind: InputMemoryKind,
                                       now: Int64) {
        let normalizedReading = Reading.canonical(reading, language: language)
        let normalizedText = text.precomposedStringWithCanonicalMapping
        guard !normalizedReading.isEmpty, !normalizedText.isEmpty,
              normalizedText.count <= Self.maximumTextCharacters else { return }
        let eventKey = key(language: language, reading: normalizedReading, text: normalizedText)
        let boundedRank = max(0, min(rank, 32))
        var entry: InputMemoryEntry
        if let index = index(of: eventKey) {
            entry = entries[index]
        } else {
            entry = InputMemoryEntry(language: language, reading: normalizedReading,
                                     text: normalizedText, kind: kind,
                                     created: now, lastUsed: now, userCreated: userCreated)
        }
        entry.kind = kind
        entry.userCreated = entry.userCreated || userCreated
        entry.selections = min(1_000_000, entry.selections + 1)
        entry.exposures = min(1_000_000, entry.exposures + 1)
        entry.recentSelections = min(1_000, entry.recentSelections * Self.eventDecay + 1)
        entry.recentExposures = min(1_000, entry.recentExposures * Self.eventDecay + 1)
        entry.bestRank = min(entry.bestRank ?? boundedRank, boundedRank)
        entry.lastRank = boundedRank
        entry.lastUsed = now
        // A deep-rank adoption is the strongest signal: next time this input
        // should open the bar. A rank-zero adoption grows steadily instead.
        let depth = Double(min(boundedRank, 12))
        let gain = 2.0 + depth * 1.6 + (boundedRank >= 5 ? 5.0 : 0.0)
        let scaled = kind == .composed ? gain * 0.6 : gain
        entry.promotion = min(Self.maximumPromotion, entry.promotion * 0.90 + scaled)
        if let index = index(of: eventKey) { entries[index] = entry }
        else { entries.append(entry) }
    }

    private func key(language: KeyboardLanguage, reading: String, text: String) -> String {
        language.rawValue + "\u{1F}" + Reading.canonical(reading, language: language)
            + "\u{1F}" + text.precomposedStringWithCanonicalMapping
    }

    private func index(of key: String) -> Int? {
        entries.firstIndex { $0.key == key }
    }

    private func normalized() -> InputMemory {
        var seen = Set<String>()
        var valid: [InputMemoryEntry] = []
        for var entry in entries {
            entry.reading = Reading.canonical(entry.reading, language: entry.language)
            entry.text = entry.text.precomposedStringWithCanonicalMapping
            guard !entry.reading.isEmpty, entry.reading.count <= Self.maximumReadingCharacters,
                  !entry.text.isEmpty, entry.text.count <= Self.maximumTextCharacters,
                  !entry.text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  entry.selections >= 0, entry.exposures >= 0,
                  entry.promotion.isFinite, entry.recentSelections.isFinite,
                  entry.recentExposures.isFinite,
                  seen.insert(entry.key).inserted else { continue }
            entry.selections = min(max(0, entry.selections), 1_000_000)
            entry.exposures = min(max(0, entry.exposures), 1_000_000)
            entry.promotion = min(max(0, entry.promotion), Self.maximumPromotion)
            entry.recentSelections = min(max(0, entry.recentSelections), 1_000)
            entry.recentExposures = min(max(0, entry.recentExposures), 1_000)
            if entry.lastUsed <= 0 { entry.lastUsed = entry.created }
            if entry.created <= 0 { entry.created = entry.lastUsed }
            valid.append(entry)
        }
        return InputMemory(entries: valid)
    }

    private mutating func sortEntries() {
        entries.sort { ($0.language.rawValue, $0.reading, $0.text) < ($1.language.rawValue, $1.reading, $1.text) }
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        entries = try values.decodeIfPresent([InputMemoryEntry].self, forKey: .entries) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(entries, forKey: .entries)
    }
}

public enum InputMemoryStoreError: LocalizedError, Equatable {
    case storageUnavailable(String)
    case unsupportedVersion(Int)
    case tooLarge
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let reason): return "无法访问输入记忆：\(reason)"
        case .unsupportedVersion(let version): return "不支持的输入记忆版本：\(version)"
        case .tooLarge: return "输入记忆文件超过大小限制。"
        case .invalidData: return "输入记忆文件结构无效。"
        }
    }
}

/// Atomic file-backed memory in the same App Group directory as the profile.
/// Writes are serialized with a file lock so the app and keyboard extension
/// cannot silently overwrite one another.
public final class InputMemoryStore: @unchecked Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public let directory: URL
    private let mutex = NSLock()
    private var memoryURL: URL { directory.appendingPathComponent("input-memory-v1.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> InputMemory {
        try locked { try read() }
    }

    public func loadOrEmpty() -> InputMemory {
        (try? load()) ?? .empty
    }

    public func count() -> Int { loadOrEmpty().entries.count }

    @discardableResult
    public func record(_ events: [InputMemoryEvent],
                       now: Int64 = Int64(Date().timeIntervalSince1970)) -> InputMemory? {
        guard !events.isEmpty else { return loadOrEmpty() }
        return try? locked {
            var memory = try readRecoveringIfNeeded()
            memory = memory.record(events: events, now: now).pruned(now: now)
            try write(memory)
            return memory
        }
    }

    public func clear() throws {
        try locked {
            try write(.empty)
        }
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent("input-memory.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InputMemoryStoreError.storageUnavailable(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw InputMemoryStoreError.storageUnavailable(String(cString: strerror(errno)))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func read() throws -> InputMemory {
        guard FileManager.default.fileExists(atPath: memoryURL.path) else { return .empty }
        let size = (try FileManager.default.attributesOfItem(atPath: memoryURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumBytes else { throw InputMemoryStoreError.tooLarge }
        let memory: InputMemory
        do { memory = try JSONDecoder().decode(InputMemory.self, from: Data(contentsOf: memoryURL, options: .mappedIfSafe)) }
        catch { throw InputMemoryStoreError.invalidData }
        guard memory.version == InputMemory.currentVersion else {
            throw InputMemoryStoreError.unsupportedVersion(memory.version)
        }
        return memory.pruned()
    }

    private func readRecoveringIfNeeded() throws -> InputMemory {
        do { return try read() }
        catch InputMemoryStoreError.invalidData, InputMemoryStoreError.unsupportedVersion,
              InputMemoryStoreError.tooLarge {
            // Preserve unexpected bytes for inspection, then start from an empty
            // memory so a corrupt file cannot permanently disable learning.
            let preserved = directory.appendingPathComponent("input-memory-damaged-" + UUID().uuidString + ".json")
            if FileManager.default.fileExists(atPath: memoryURL.path) {
                try? FileManager.default.copyItem(at: memoryURL, to: preserved)
            }
            return .empty
        }
    }

    private func write(_ memory: InputMemory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(memory)
        guard data.count <= Self.maximumBytes else { throw InputMemoryStoreError.tooLarge }
        try data.write(to: memoryURL, options: .atomic)
    }
}
