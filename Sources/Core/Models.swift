// SPDX-License-Identifier: MIT
// Original implementation for Azki Native. No third-party implementation code.
import Foundation

public enum KeyboardLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case chinese = "zh", english = "en", japanese = "ja"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .chinese: return "中文"; case .english: return "English"; case .japanese: return "日本語" }
    }
}

/// How Chinese is written. The lexicon is simplified, so the others are converted from it.
public enum ChineseScript: String, Codable, CaseIterable, Sendable, Identifiable {
    case simplified, traditional, taiwan, hongkong
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .simplified: return "简体"
        case .traditional: return "繁體"
        case .taiwan: return "台灣"
        case .hongkong: return "香港"
        }
    }
    /// The letter on the language key.
    public var shortTitle: String {
        switch self {
        case .simplified: return "中"
        case .traditional: return "繁"
        case .taiwan: return "台"
        case .hongkong: return "港"
        }
    }
    public var speechLocale: String {
        switch self {
        case .simplified: return "zh-CN"
        case .traditional, .taiwan: return "zh-TW"
        case .hongkong: return "zh-HK"
        }
    }
}

public enum AppearanceTheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// Automatic is a persisted default, not a fourth user-facing material.
public enum ButtonMaterialPreference: String, Codable, CaseIterable, Sendable {
    case automatic, frosted, liquidGlass, solid

    public func resolved(supportsLiquidGlass: Bool, reduceTransparency: Bool = false,
                         increasedContrast: Bool = false) -> ButtonMaterialPreference {
        if reduceTransparency || increasedContrast { return .solid }
        switch self {
        case .automatic, .liquidGlass: return supportsLiquidGlass ? .liquidGlass : .frosted
        case .frosted, .solid: return self
        }
    }
}

public struct UserWord: Codable, Hashable, Sendable {
    public var reading: String
    public var text: String
    public var language: KeyboardLanguage
    public var weight: Int
    public init(reading: String, text: String, language: KeyboardLanguage, weight: Int = 100) {
        self.reading = reading; self.text = text; self.language = language; self.weight = weight
    }
}

public struct LexiconCandidate: Hashable, Sendable, Identifiable {
    public let text: String
    public let reading: String
    public let source: String
    /// Input letters this candidate covers, when it covers only the start of the input.
    public let consumed: Int?
    public var id: String { text }
    public init(text: String, reading: String, source: String, consumed: Int? = nil) {
        self.text = text; self.reading = reading; self.source = source; self.consumed = consumed
    }
}

public struct QuickPhrase: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    /// Typing exactly this code offers `text` as a candidate. Absent in older profiles.
    public var abbreviation: String?
    public init(id: String = UUID().uuidString, title: String, text: String, abbreviation: String? = nil) {
        self.id = id; self.title = title; self.text = text; self.abbreviation = abbreviation
    }

    public static let maximumAbbreviationLength = 32

    /// Keyboard input is ASCII letters and digits, so anything else could never match.
    public static func normalizedAbbreviation(_ value: String) -> String? {
        let code = String(value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(maximumAbbreviationLength))
        return code.isEmpty ? nil : code
    }
}

public struct ButtonColors: Codable, Equatable, Sendable {
    public var lightBackground: String?
    public var darkBackground: String?
    public var foreground: String?
    public var pressedBackground: String?
    public var pressedForeground: String?
    public init(lightBackground: String? = nil, darkBackground: String? = nil, foreground: String? = nil,
                pressedBackground: String? = nil, pressedForeground: String? = nil) {
        self.lightBackground = lightBackground; self.darkBackground = darkBackground; self.foreground = foreground
        self.pressedBackground = pressedBackground; self.pressedForeground = pressedForeground
    }
}

public struct AzkiPreferences: Codable, Equatable, Sendable {
    public static let defaultPressedBackground = "#F6D6DF"
    public var buttonMaterial: ButtonMaterialPreference
    /// Legacy API retained for existing callers; new rendering uses buttonMaterial.
    public var liquidGlass: Bool {
        get { buttonMaterial == .automatic || buttonMaterial == .liquidGlass }
        set { buttonMaterial = newValue ? .automatic : .solid }
    }
    public var cornerRadius: Double
    public var pressedBackground: String
    public var pressedForeground: String
    public var keyOverrides: [String: ButtonColors]
    public var phrases: [QuickPhrase]
    public var language: KeyboardLanguage
    public var theme: AppearanceTheme
    public var keyHaptics = true
    /// Optional regional candidate hints. The stored region remains even while
    /// the feature is switched off, so re-enabling it restores the last choice.
    public var dialectEnabled = false
    public var dialectRegionID: String?
    /// Optional local candidate memory. When false, the keyboard neither reads
    /// nor writes learned words, but existing memory is kept until cleared.
    public var learningEnabled = true
    public var glideTyping = true
    public var flickInput = true
    public var emojiSuggestions = true
    public var chineseScript = ChineseScript.simplified
    public init(liquidGlass: Bool? = nil, cornerRadius: Double = 14,
                pressedBackground: String = AzkiPreferences.defaultPressedBackground, pressedForeground: String = "#292327",
                keyOverrides: [String: ButtonColors] = [:],
                phrases: [QuickPhrase] = AzkiPreferences.defaultPhrases,
                language: KeyboardLanguage = .chinese, theme: AppearanceTheme = .system,
                buttonMaterial: ButtonMaterialPreference? = nil,
                dialectEnabled: Bool = false, dialectRegionID: String? = nil,
                learningEnabled: Bool = true) {
        self.buttonMaterial = buttonMaterial ?? liquidGlass.map { $0 ? .automatic : .solid } ?? .automatic; self.cornerRadius = cornerRadius
        self.pressedBackground = pressedBackground; self.pressedForeground = pressedForeground
        self.keyOverrides = keyOverrides; self.phrases = phrases; self.language = language; self.theme = theme
        self.dialectEnabled = dialectEnabled; self.dialectRegionID = dialectRegionID
        self.learningEnabled = learningEnabled
    }
    public static let defaultPhrases: [QuickPhrase] = [
        QuickPhrase(id: "thanks-zh", title: "谢谢", text: "谢谢！"),
        QuickPhrase(id: "thanks-en", title: "Thanks", text: "Thank you!"),
        QuickPhrase(id: "thanks-ja", title: "ありがとう", text: "ありがとうございます。")
    ]
    private enum CodingKeys: String, CodingKey {
        case buttonMaterial, liquidGlass, cornerRadius, pressedBackground, pressedForeground, keyOverrides, phrases, language, theme, keyHaptics
        case dialectEnabled, dialectRegionID, learningEnabled, glideTyping, flickInput, emojiSuggestions, chineseScript, traditionalChinese
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AzkiPreferences()
        // Explicit modern selection wins. Historical false meant a solid button;
        // true means the best available system glass. Missing preferences use automatic.
        let legacyGlass = try values.decodeIfPresent(Bool.self, forKey: .liquidGlass)
        // Not `try`: a value from another version must not lose the whole profile.
        buttonMaterial = (try? values.decodeIfPresent(ButtonMaterialPreference.self, forKey: .buttonMaterial))
            ?? legacyGlass.map { $0 ? .automatic : .solid } ?? .automatic
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        pressedBackground = try values.decodeIfPresent(String.self, forKey: .pressedBackground) ?? defaults.pressedBackground
        pressedForeground = try values.decodeIfPresent(String.self, forKey: .pressedForeground) ?? defaults.pressedForeground
        keyOverrides = try values.decodeIfPresent([String: ButtonColors].self, forKey: .keyOverrides) ?? [:]
        phrases = try values.decodeIfPresent([QuickPhrase].self, forKey: .phrases) ?? defaults.phrases
        language = try values.decodeIfPresent(KeyboardLanguage.self, forKey: .language) ?? defaults.language
        theme = try values.decodeIfPresent(AppearanceTheme.self, forKey: .theme) ?? .system
        keyHaptics = try values.decodeIfPresent(Bool.self, forKey: .keyHaptics) ?? true
        dialectEnabled = try values.decodeIfPresent(Bool.self, forKey: .dialectEnabled) ?? false
        dialectRegionID = try values.decodeIfPresent(String.self, forKey: .dialectRegionID)
        learningEnabled = try values.decodeIfPresent(Bool.self, forKey: .learningEnabled) ?? true
        glideTyping = try values.decodeIfPresent(Bool.self, forKey: .glideTyping) ?? true
        flickInput = try values.decodeIfPresent(Bool.self, forKey: .flickInput) ?? true
        emojiSuggestions = try values.decodeIfPresent(Bool.self, forKey: .emojiSuggestions) ?? true
        chineseScript = (try? values.decodeIfPresent(ChineseScript.self, forKey: .chineseScript))
            ?? (try? values.decodeIfPresent(Bool.self, forKey: .traditionalChinese)).flatMap { $0 == true ? .traditional : nil }
            ?? .simplified
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(buttonMaterial, forKey: .buttonMaterial)
        // Older app versions can still read exported preferences.
        try values.encode(liquidGlass, forKey: .liquidGlass)
        try values.encode(cornerRadius, forKey: .cornerRadius)
        try values.encode(pressedBackground, forKey: .pressedBackground)
        try values.encode(pressedForeground, forKey: .pressedForeground)
        try values.encode(keyOverrides, forKey: .keyOverrides)
        try values.encode(phrases, forKey: .phrases)
        try values.encode(language, forKey: .language)
        try values.encode(theme, forKey: .theme)
        try values.encode(keyHaptics, forKey: .keyHaptics)
        try values.encode(dialectEnabled, forKey: .dialectEnabled)
        try values.encodeIfPresent(dialectRegionID, forKey: .dialectRegionID)
        try values.encode(learningEnabled, forKey: .learningEnabled)
        try values.encode(glideTyping, forKey: .glideTyping)
        try values.encode(flickInput, forKey: .flickInput)
        try values.encode(emojiSuggestions, forKey: .emojiSuggestions)
        try values.encode(chineseScript, forKey: .chineseScript)
    }

}

public struct ImportReport: Equatable, Sendable {
    /// Number of unique entries in the resulting profile, not only added rows.
    public let count: Int
    /// Duplicate keys in the file and exact unchanged entries already in the profile.
    public let duplicates: Int
    public let changed: Bool
    public init(count: Int, duplicates: Int, changed: Bool) {
        self.count = count; self.duplicates = duplicates; self.changed = changed
    }
}

public enum ProfileError: LocalizedError, Equatable {
    case invalidUTF8, tooLarge, tooManyRows, invalidRow(Int, String), invalidPreferences(String)
    case invalidSnapshot(String), noPreviousSnapshot, storageUnavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "文件必须使用 UTF-8 编码。"
        case .tooLarge: return "词库文件超过 4 MiB，或备份超过允许大小。"
        case .tooManyRows: return "自定义词库最多保存 20,000 条词条。"
        case let .invalidRow(line, reason): return "第 \(line) 行无效：\(reason)"
        case let .invalidPreferences(reason): return "配置无效：\(reason)"
        case let .invalidSnapshot(reason): return "备份无效：\(reason)"
        case .noPreviousSnapshot: return "还没有可恢复的上一份词库。"
        case let .storageUnavailable(reason): return "无法访问本地数据：\(reason)"
        }
    }
}
