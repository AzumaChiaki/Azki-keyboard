// SPDX-License-Identifier: MIT
import Foundation

/// Turns simplified Chinese into traditional. Characters alone can't do it, since one
/// simplified character can stand for several, so the longest known phrase goes first.
/// Tables are built by `scripts/build_traditional.py` from OpenCC.
public struct TraditionalConverter: Sendable {
    private var characters: [Character: String] = [:]
    private var phrases: [String: String] = [:]
    private var longestPhrase = 0

    public init(table: String) {
        for line in table.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count == 2 else { continue }
            if columns[0].count == 1, let character = columns[0].first {
                characters[character] = String(columns[1])
            } else {
                phrases[String(columns[0])] = String(columns[1])
                longestPhrase = max(longestPhrase, columns[0].count)
            }
        }
    }

    public func convert(_ text: String) -> String {
        let letters = Array(text)
        var result = ""
        var index = 0
        while index < letters.count {
            let longest = min(longestPhrase, letters.count - index)
            let match = longest < 2 ? nil : stride(from: longest, through: 2, by: -1).lazy.compactMap { length in
                phrases[String(letters[index..<(index + length)])].map { (length, $0) }
            }.first
            if let (length, phrase) = match {
                result += phrase
                index += length
            } else {
                result += characters[letters[index]] ?? String(letters[index])
                index += 1
            }
        }
        return result
    }

    /// Writes simplified `text` in `script`: traditional first, then a region's own words.
    public static func convert(_ text: String, to script: ChineseScript) -> String {
        let traditional = script == .simplified ? text : base?.convert(text) ?? text
        switch script {
        case .simplified, .traditional: return traditional
        case .taiwan: return taiwan?.convert(traditional) ?? traditional
        case .hongkong: return hongKong?.convert(traditional) ?? traditional
        }
    }

    // Loaded on first use, so only someone writing traditional pays for them.
    private static let base = bundled("traditional")
    private static let taiwan = bundled("traditional-tw")
    private static let hongKong = bundled("traditional-hk")

    private static func bundled(_ name: String) -> TraditionalConverter? {
        var bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "tsv"),
               let table = try? String(contentsOf: url, encoding: .utf8) { return TraditionalConverter(table: table) }
        }
        return nil
    }

    private final class BundleToken {}
}
