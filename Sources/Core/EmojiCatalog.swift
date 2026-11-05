// SPDX-License-Identifier: MIT
import Foundation

/// Emoji for a word, from Unicode CLDR annotations. See scripts/build_emoji.py.
public struct EmojiCatalog: Sendable {
    private let chinese: [String: [String]]
    private let english: [String: [String]]

    public init(data: Data) throws {
        let table = try JSONDecoder().decode([String: [String: [String]]].self, from: data)
        chinese = table["zh"] ?? [:]
        english = table["en"] ?? [:]
    }

    public func emoji(for word: String, language: KeyboardLanguage) -> [String] {
        switch language {
        case .chinese: return chinese[word] ?? []
        case .english: return english[word.lowercased()] ?? []
        case .japanese: return []
        }
    }

    public static func bundled() -> EmojiCatalog? { shared }

    private static let shared: EmojiCatalog? = {
        var bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: "emoji", withExtension: "json"),
               let data = try? Data(contentsOf: url), let catalog = try? EmojiCatalog(data: data) { return catalog }
        }
        return nil
    }()

    private final class BundleToken {}
}
