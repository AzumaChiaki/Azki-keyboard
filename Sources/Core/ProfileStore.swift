// SPDX-License-Identifier: MIT
// Original transactional local profile implementation; Foundation and Darwin only.
import Foundation
import Darwin

public final class ProfileStore: @unchecked Sendable {
    public static let maximumTSVBytes = 4 * 1024 * 1024
    public static let maximumEntries = 20_000
    public static let maximumBackupBytes = 32 * 1024 * 1024
    public let directory: URL
    private let mutex = NSLock()
    private var profileURL: URL { directory.appendingPathComponent("profile-v1.json") }

    private struct Snapshot: Codable, Equatable {
        var preferences: AzkiPreferences
        var entries: [UserWord]
        static var empty: Snapshot { Snapshot(preferences: AzkiPreferences(), entries: []) }
    }
    private struct Envelope: Codable {
        var version = 1
        var current: Snapshot
        var previous: Snapshot?
        static var empty: Envelope { Envelope(current: .empty, previous: nil) }
    }
    private struct Key: Hashable {
        let language: KeyboardLanguage
        let reading: String
        let text: String
        init(_ word: UserWord) { language = word.language; reading = word.reading; text = word.text }
    }

    public init(directory: URL) { self.directory = directory }

    public func loadPreferences() throws -> AzkiPreferences { try locked { try read().current.preferences } }
    public func loadEntries() throws -> [UserWord] { try locked { try read().current.entries } }
    public func hasPreviousSnapshot() throws -> Bool { try locked { try read().previous != nil } }

    public func savePreferences(_ preferences: AzkiPreferences) throws {
        try Self.validate(preferences)
        try locked {
            var envelope = try read()
            guard envelope.current.preferences != preferences else { return }
            envelope.current.preferences = preferences
            // Appearance changes must not consume the previous dictionary revision.
            try write(envelope)
        }
    }

    @discardableResult public func importTSV(data: Data) throws -> ImportReport { try importTSV(data) }

    @discardableResult public func importTSV(_ data: Data) throws -> ImportReport {
        let parsed = try Self.parseTSV(data)
        return try locked {
            var envelope = try read()
            var entries = Dictionary(uniqueKeysWithValues: envelope.current.entries.map { (Key($0), $0) })
            var duplicates = parsed.duplicates
            for word in parsed.words {
                if entries[Key(word)] == word { duplicates += 1 }
                entries[Key(word)] = word
            }
            guard entries.count <= Self.maximumEntries else { throw ProfileError.tooManyRows }
            let merged = Self.sorted(Array(entries.values))
            guard Self.tsvData(merged).count <= Self.maximumTSVBytes else { throw ProfileError.tooLarge }
            guard merged != envelope.current.entries else {
                return ImportReport(count: merged.count, duplicates: duplicates, changed: false)
            }
            envelope.previous = envelope.current
            envelope.current.entries = merged
            try write(envelope)
            return ImportReport(count: merged.count, duplicates: duplicates, changed: true)
        }
    }

    /// Swap the previous and current complete profiles. Calling again reverses this restore.
    @discardableResult public func restorePrevious() throws -> Int {
        try locked {
            var envelope = try read()
            guard let previous = envelope.previous else { throw ProfileError.noPreviousSnapshot }
            envelope.previous = envelope.current
            envelope.current = previous
            try write(envelope)
            return previous.entries.count
        }
    }

    public func exportTSV() throws -> Data {
        try locked { Self.tsvData(try read().current.entries) }
    }

    /// Export includes appearance, phrases and the previous revision as well as dictionary entries.
    public func exportBackup() throws -> Data { try locked { try Self.encode(read()) } }

    /// Restore a validated external backup; retain the local current profile for undo.
    @discardableResult public func restoreBackup(_ data: Data) throws -> ImportReport {
        let incoming = try Self.decode(data)
        return try locked {
            var envelope: Envelope
            do { envelope = try read() }
            catch let error as ProfileError {
                switch error {
                case .invalidSnapshot, .invalidPreferences, .invalidRow, .tooManyRows:
                    // An explicit valid backup restore can repair a damaged profile. Keep the
                    // exact damaged bytes for recovery; normal imports never take this path.
                    let preserved = directory.appendingPathComponent("damaged-profile-" + UUID().uuidString + ".json")
                    try FileManager.default.copyItem(at: profileURL, to: preserved)
                    try write(incoming)
                    return ImportReport(count: incoming.current.entries.count, duplicates: 0, changed: true)
                default: throw error
                }
            }
            let changed = envelope.current != incoming.current
            if changed {
                envelope.previous = envelope.current
                envelope.current = incoming.current
                try write(envelope)
            }
            return ImportReport(count: incoming.current.entries.count, duplicates: 0, changed: changed)
        }
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent("profile.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProfileError.storageUnavailable(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ProfileError.storageUnavailable(String(cString: strerror(errno))) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func read() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return .empty }
        let size = (try FileManager.default.attributesOfItem(atPath: profileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumBackupBytes else { throw ProfileError.tooLarge }
        return try Self.decode(Data(contentsOf: profileURL, options: .mappedIfSafe))
    }

    private func write(_ envelope: Envelope) throws {
        let data = try Self.encode(envelope)
        guard data.count <= Self.maximumBackupBytes else { throw ProfileError.tooLarge }
        // The current and previous snapshots share one atomic filesystem replacement.
        try data.write(to: profileURL, options: .atomic)
    }

    private static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func decode(_ data: Data) throws -> Envelope {
        guard data.count <= maximumBackupBytes else { throw ProfileError.tooLarge }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ProfileError.invalidSnapshot("文件结构或字段不正确") }
        guard envelope.version == 1 else { throw ProfileError.invalidSnapshot("不支持此格式版本") }
        try validate(envelope.current)
        if let previous = envelope.previous { try validate(previous) }
        return envelope
    }

    private static func validate(_ snapshot: Snapshot) throws {
        try validate(snapshot.preferences)
        guard snapshot.entries.count <= maximumEntries else { throw ProfileError.tooManyRows }
        var seen = Set<Key>()
        for (index, word) in snapshot.entries.enumerated() {
            let normalized = try validate(word, row: index + 1)
            guard normalized == word, seen.insert(Key(word)).inserted else {
                throw ProfileError.invalidSnapshot("词条包含未规范化或重复的记录")
            }
        }
        guard sorted(snapshot.entries) == snapshot.entries else { throw ProfileError.invalidSnapshot("词条顺序无效") }
        guard tsvData(snapshot.entries).count <= maximumTSVBytes else { throw ProfileError.tooLarge }
    }

    private static func validate(_ preferences: AzkiPreferences) throws {
        guard preferences.cornerRadius.isFinite, (0...40).contains(preferences.cornerRadius) else {
            throw ProfileError.invalidPreferences("圆角必须介于 0 与 40 之间")
        }
        func validColor(_ value: String) -> Bool {
            let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
            return digits.count == 6 && digits.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
            }
        }
        guard validColor(preferences.pressedBackground), validColor(preferences.pressedForeground), preferences.keyOverrides.count <= 256 else {
            throw ProfileError.invalidPreferences("颜色应为六位十六进制值")
        }
        for (key, colors) in preferences.keyOverrides {
            guard !key.isEmpty, key.count <= 80,
                  [colors.lightBackground, colors.darkBackground, colors.foreground, colors.pressedBackground, colors.pressedForeground]
                    .compactMap({ $0 }).allSatisfy(validColor) else { throw ProfileError.invalidPreferences("单键配色无效") }
        }
        guard preferences.phrases.count <= 128 else { throw ProfileError.invalidPreferences("快捷短语最多 128 条") }
        if let region = preferences.dialectRegionID {
            guard !region.isEmpty, region.count <= 64, region.unicodeScalars.allSatisfy({
                (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45
            }) else { throw ProfileError.invalidPreferences("方言地区标识无效") }
        }
        var ids = Set<String>()
        for phrase in preferences.phrases {
            guard !phrase.id.isEmpty, phrase.id.count <= 128, ids.insert(phrase.id).inserted,
                  !phrase.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, phrase.title.count <= 64,
                  !phrase.text.isEmpty, phrase.text.count <= 2000,
                  !phrase.id.contains("\0"), !phrase.title.contains("\0"), !phrase.text.contains("\0"),
                  phrase.abbreviation == nil || phrase.abbreviation == phrase.abbreviation.flatMap(QuickPhrase.normalizedAbbreviation) else {
                throw ProfileError.invalidPreferences("快捷短语标题、内容或标识无效")
            }
        }
    }

    private static func sorted(_ words: [UserWord]) -> [UserWord] {
        words.sorted { ($0.language.rawValue, $0.reading, $0.text) < ($1.language.rawValue, $1.reading, $1.text) }
    }

    private static func tsvData(_ words: [UserWord]) -> Data {
        let body = words.map { "\($0.reading)\t\($0.text)\t\($0.language.rawValue)\t\($0.weight)" }.joined(separator: "\n")
        return Data(("code\ttext\tlang\tweight\n" + body + (body.isEmpty ? "" : "\n")).utf8)
    }

    private static func validate(_ word: UserWord, row: Int) throws -> UserWord {
        let normalized = UserWord(reading: Reading.canonical(word.reading, language: word.language),
                                  text: word.text.precomposedStringWithCanonicalMapping, language: word.language, weight: word.weight)
        guard !normalized.reading.isEmpty, normalized.reading.count <= 128, normalized.reading.utf8.count <= 512 else {
            throw ProfileError.invalidRow(row, "编码长度必须介于 1 与 128 个字符之间")
        }
        guard !normalized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.text.count <= 256, normalized.text.utf8.count <= 1024,
              !normalized.text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalidRow(row, "词语不能为空、超过 256 字或包含控制字符")
        }
        guard (0...1_000_000).contains(normalized.weight) else { throw ProfileError.invalidRow(row, "权重应为 0 至 1000000 的整数") }
        let validReading: Bool
        switch word.language {
        case .chinese:
            validReading = normalized.reading.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
        case .english:
            validReading = normalized.reading.unicodeScalars.allSatisfy {
                (97...122).contains($0.value) || (48...57).contains($0.value) || [32, 39, 45].contains($0.value)
            }
        case .japanese:
            validReading = normalized.reading.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
        }
        guard validReading else { throw ProfileError.invalidRow(row, "编码不符合所选语言（中文为无声调拼音，日文为假名或罗马字）") }
        return normalized
    }

    private static func parseTSV(_ data: Data) throws -> (words: [UserWord], duplicates: Int) {
        guard data.count <= maximumTSVBytes else { throw ProfileError.tooLarge }
        guard var source = String(data: data, encoding: .utf8) else { throw ProfileError.invalidUTF8 }
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var values: [Key: UserWord] = [:], duplicates = 0, rowCount = 0, firstContent = true
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let columns = line.components(separatedBy: "\t")
            if firstContent {
                firstContent = false
                let header = columns.map { $0.lowercased() }
                if header == ["code","text","lang"] || header == ["code","text","lang","weight"] ||
                   header == ["reading","text","language"] || header == ["reading","text","language","weight"] { continue }
            }
            rowCount += 1
            guard rowCount <= maximumEntries else { throw ProfileError.tooManyRows }
            guard columns.count == 3 || columns.count == 4 else { throw ProfileError.invalidRow(index + 1, "需要 code、text、lang 与可选 weight 三或四列") }
            let languageTag = columns[2].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
            let baseTag = languageTag.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let language = KeyboardLanguage(rawValue: baseTag),
                  !languageTag.hasSuffix("-"), languageTag.unicodeScalars.allSatisfy({
                      (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45
                  }) else {
                throw ProfileError.invalidRow(index + 1, "语言必须是 zh、en、ja 或其区域标签（如 zh-Hans）")
            }
            let weight: Int
            if columns.count == 4 {
                guard let parsed = Int(columns[3].trimmingCharacters(in: .whitespaces)) else { throw ProfileError.invalidRow(index + 1, "权重不是整数") }
                weight = parsed
            } else { weight = 100 }
            let word = try validate(UserWord(reading: columns[0], text: columns[1], language: language, weight: weight), row: index + 1)
            if values.updateValue(word, forKey: Key(word)) != nil { duplicates += 1 }
        }
        return (sorted(Array(values.values)), duplicates)
    }
}
