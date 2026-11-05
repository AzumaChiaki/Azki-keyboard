// SPDX-License-Identifier: MIT
// Original regional dialect catalog and ranking hints for the offline keyboard.
import Foundation

/// One dialect-flavoured word or habitual phrase. Readings are compact lowercase
/// ASCII so they can be typed on the same keyboard as standard pinyin.
public struct DialectEntry: Codable, Hashable, Sendable, Identifiable {
    public var text: String
    public var readings: [String]
    /// Editorial relevance inside the region: 1 is a light local colouring,
    /// 5 marks a widely recognised regional shibboleth.
    public var boost: Int
    public var kind: String
    public var note: String?

    public var id: String { text + "\u{1F}" + readings.joined(separator: ",") }

    public init(text: String, readings: [String], boost: Int, kind: String,
                note: String? = nil) {
        self.text = text
        self.readings = readings
        self.boost = boost
        self.kind = kind
        self.note = note
    }
}

/// How a region ends its sentences, as opposed to the words it uses.
public struct DialectEnding: Codable, Hashable, Sendable {
    public var text: String
    public var reading: String
    /// 3 is measured in that region's own writing, 1 only described in the literature.
    public var tier: Int

    public init(text: String, reading: String, tier: Int) {
        self.text = text
        self.reading = reading
        self.tier = tier
    }
}

/// A region pack. Families are deliberately broad (for example 西南官话) because
/// the same habitual word can be used across several provinces.
public struct DialectRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var family: String
    public var provinces: [String]
    public var summary: String
    public var entries: [DialectEntry]
    public var endings: [DialectEnding]?

    public init(id: String, name: String, family: String, provinces: [String],
                summary: String, entries: [DialectEntry], endings: [DialectEnding]? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.provinces = provinces
        self.summary = summary
        self.entries = entries
        self.endings = endings
    }
}

public struct DialectMatch: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// The typed code equals the complete reading.
        case exact
        /// The typed code is the beginning of a longer reading.
        case completion
    }

    public let entry: DialectEntry
    public let reading: String
    public let kind: Kind

    public init(entry: DialectEntry, reading: String, kind: Kind) {
        self.entry = entry
        self.reading = reading
        self.kind = kind
    }

    /// A bounded contribution used by the candidate ranker. Exact readings must
    /// stay visible among dictionary candidates; completions are deliberately
    /// cheaper so they do not displace what the user actually typed.
    public var rankingBoost: Double {
        switch kind {
        case .exact: return 4.0 + Double(entry.boost) * 1.6
        case .completion: return 1.0 + Double(entry.boost) * 0.9
        }
    }
}

public enum DialectCatalogError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case malformed(String)
    case noRegions

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "不支持的方言数据版本：\(version)"
        case .malformed(let reason): return "方言数据无效：\(reason)"
        case .noRegions: return "方言数据没有地区。"
        }
    }
}

/// Immutable, indexed dialect data. Loading is done once per engine; candidate
/// lookup only scans a handful of matching entries.
public struct DialectCatalog: Sendable {
    public static let currentVersion = 1
    public static let maximumEntriesPerRegion = 200
    public static let maximumTextCharacters = 64
    public static let maximumReadingCharacters = 128

    public let regions: [DialectRegion]
    private let indexes: [String: RegionIndex]

    private struct RegionFile: Codable {
        var formatVersion: Int
        var revision: String?
        var regions: [DialectRegion]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case revision
            case regions
        }
    }

    private struct RegionIndex: Sendable {
        var byReading: [String: [DialectEntry]]
        var boostByText: [String: Int]
        /// Every reading/text pair in the region, used by the sentence decoder.
        var words: [UserWord]
        var entries: [DialectEntry]
    }

    public init(data: Data) throws {
        let file: RegionFile
        do {
            file = try JSONDecoder().decode(RegionFile.self, from: data)
        } catch {
            throw DialectCatalogError.malformed("无法解析 JSON")
        }
        guard file.formatVersion == Self.currentVersion else {
            throw DialectCatalogError.unsupportedVersion(file.formatVersion)
        }
        try self.init(validating: file.regions)
    }

    /// Used by tests and by callers that build a catalog in memory. Invalid
    /// records throw rather than silently changing what appears on the keyboard.
    public init(regions: [DialectRegion]) throws {
        try self.init(validating: regions)
    }

    private init(validating input: [DialectRegion]) throws {
        guard !input.isEmpty else { throw DialectCatalogError.noRegions }
        var identifiers = Set<String>()
        var normalizedRegions: [DialectRegion] = []
        var indexes: [String: RegionIndex] = [:]

        for region in input {
            guard Self.isValidIdentifier(region.id), identifiers.insert(region.id).inserted else {
                throw DialectCatalogError.malformed("地区标识重复或无效：\(region.id)")
            }
            guard !region.name.isEmpty, region.name.count <= 32,
                  !region.family.isEmpty, region.family.count <= 32,
                  region.summary.count <= 240, region.provinces.count <= 8 else {
                throw DialectCatalogError.malformed("地区字段无效：\(region.id)")
            }
            guard region.entries.count <= Self.maximumEntriesPerRegion else {
                throw DialectCatalogError.malformed("地区词条过多：\(region.id)")
            }

            var byReading: [String: [DialectEntry]] = [:]
            var boostByText: [String: Int] = [:]
            var words: [String: UserWord] = [:]
            var seenKeys = Set<String>()
            var entries: [DialectEntry] = []

            for entry in region.entries {
                let text = entry.text.precomposedStringWithCanonicalMapping
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= Self.maximumTextCharacters,
                      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw DialectCatalogError.malformed("词条文本无效：\(region.id)")
                }
                guard (1...5).contains(entry.boost) else {
                    throw DialectCatalogError.malformed("词条权重应为 1 至 5：\(text)")
                }
                guard !entry.kind.isEmpty, entry.kind.count <= 16,
                      (entry.note?.count ?? 0) <= 80 else {
                    throw DialectCatalogError.malformed("词条说明无效：\(text)")
                }
                let readings = entry.readings.map { Reading.canonical($0, language: .chinese) }
                guard !readings.isEmpty, readings.count <= 6,
                      readings.allSatisfy(Self.isValidReading) else {
                    throw DialectCatalogError.malformed("词条读音无效：\(text)")
                }
                let uniqueReadings = Array(Set(readings)).sorted()
                let normalized = DialectEntry(text: text, readings: uniqueReadings,
                                              boost: entry.boost, kind: entry.kind, note: entry.note)
                for reading in uniqueReadings {
                    let key = text + "\u{1F}" + reading
                    guard seenKeys.insert(key).inserted else { continue }
                    byReading[reading, default: []].append(normalized)
                    let weight = 800 + entry.boost * 400
                    if words[reading] == nil || (words[reading]?.weight ?? 0) < weight {
                        words[reading] = UserWord(reading: reading, text: text,
                                                  language: .chinese, weight: weight)
                    }
                }
                boostByText[text] = max(boostByText[text] ?? 0, entry.boost)
                entries.append(normalized)
            }

            for reading in byReading.keys {
                byReading[reading]?.sort {
                    $0.boost != $1.boost ? $0.boost > $1.boost : $0.text < $1.text
                }
            }
            let sortedEntries = entries.sorted {
                $0.boost != $1.boost ? $0.boost > $1.boost : $0.text < $1.text
            }
            normalizedRegions.append(DialectRegion(id: region.id, name: region.name,
                                                   family: region.family, provinces: region.provinces,
                                                   summary: region.summary, entries: sortedEntries,
                                                   endings: region.endings))
            indexes[region.id] = RegionIndex(byReading: byReading, boostByText: boostByText,
                                             words: words.values.sorted {
                                                 ($0.reading, $0.text) < ($1.reading, $1.text)
                                             }, entries: sortedEntries)
        }
        self.regions = normalizedRegions
        self.indexes = indexes
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func region(id: String?) -> DialectRegion? {
        guard let id else { return nil }
        return regions.first { $0.id == id }
    }

    /// Exact readings first, then completions. The typed code must be at least
    /// two letters for a completion, because one letter would flood the bar.
    public func matches(input: String, regionID: String?, limit: Int = 6) -> [DialectMatch] {
        guard let regionID, let index = indexes[regionID], limit > 0 else { return [] }
        let reading = Reading.canonical(input, language: .chinese)
        guard !reading.isEmpty, Self.isValidReading(reading) else { return [] }
        var matches: [DialectMatch] = []
        if let exact = index.byReading[reading] {
            matches += exact.map { DialectMatch(entry: $0, reading: reading, kind: .exact) }
        }
        if reading.count >= 2 {
            for entry in index.entries {
                guard matches.count < limit * 2 else { break }
                for alternative in entry.readings where alternative.count > reading.count
                    && alternative.hasPrefix(reading) {
                    matches.append(DialectMatch(entry: entry, reading: alternative, kind: .completion))
                }
            }
        }
        var seen = Set<String>()
        return matches.sorted {
            if $0.kind != $1.kind { return $0.kind == .exact }
            if $0.entry.boost != $1.entry.boost { return $0.entry.boost > $1.entry.boost }
            if $0.reading.count != $1.reading.count { return $0.reading.count < $1.reading.count }
            return $0.entry.text < $1.entry.text
        }.filter { seen.insert($0.entry.text).inserted }.prefix(limit).map { $0 }
    }

    /// The strongest regional association already known for this surface. Used
    /// to lift an ordinary dictionary candidate without inventing new text.
    public func boost(forText text: String, regionID: String?) -> Int {
        guard let regionID, let index = indexes[regionID] else { return 0 }
        return index.boostByText[text] ?? 0
    }

    /// Supplemental words handed to the Chinese sentence decoder. We only add
    /// one surface per reading; custom user entries still take precedence.
    public func words(regionID: String?) -> [UserWord] {
        guard let regionID, let index = indexes[regionID] else { return [] }
        return index.words
    }

    public func endings(regionID: String?) -> [DialectEnding] {
        region(id: regionID)?.endings ?? []
    }

    /// Endings `reading` may finish on, the strongest evidence first. Something has to
    /// come before them: a sentence can't start on one.
    public func endings(of reading: String, regionID: String?) -> [DialectEnding] {
        endings(regionID: regionID)
            .filter { $0.reading.count < reading.count && reading.hasSuffix($0.reading) }
            .sorted { ($0.tier, $0.reading.count, $1.text) > ($1.tier, $1.reading.count, $0.text) }
    }

    public func contains(regionID: String?) -> Bool {
        guard let regionID else { return false }
        return indexes[regionID] != nil
    }

    public static func bundled() -> DialectCatalog? { sharedBundled }

    private static let sharedBundled: DialectCatalog? = {
        guard let data = bundledData() else { return nil }
        return try? DialectCatalog(data: data)
    }()

    private static func bundledData() -> Data? {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        bundles.append(Bundle.main)
        let resources = Bundle(for: BundleToken.self)
        if resources.bundleURL != Bundle.main.bundleURL { bundles.append(resources) }
        for bundle in bundles {
            guard let url = bundle.url(forResource: "dialects", withExtension: "json") else { continue }
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    private final class BundleToken: NSObject {}

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45
        }
    }

    private static func isValidReading(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumReadingCharacters
            && value.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
    }
}
