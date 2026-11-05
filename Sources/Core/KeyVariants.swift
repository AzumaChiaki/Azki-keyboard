// SPDX-License-Identifier: MIT

/// What a key offers when held. The key's own character comes first, so a slow
/// press with no slide still types what the key shows.
public enum KeyVariants {
    private static let pinyin: [Character: String] = [
        "a": "āáǎà", "e": "ēéěèê", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔùü",
        "v": "üǖǘǚǜ", "n": "ńňǹ", "m": "ḿ"
    ]
    private static let romaji: [Character: String] = ["a": "ā", "e": "ē", "i": "ī", "o": "ō", "u": "ū"]
    private static let latin: [Character: String] = [
        "a": "àáâäæãåā", "c": "çćč", "e": "èéêëēėę", "i": "îïíīįì", "l": "ł", "n": "ñń",
        "o": "ôöòóœøōõ", "s": "ßśš", "u": "ûüùúū", "y": "ÿ", "z": "žźż"
    ]
    private static let symbols: [String: String] = [
        "1": "¹①½", "2": "²②", "3": "³③¾", "4": "⁴④¼", "5": "⁵⑤", "6": "⁶⑥", "7": "⁷⑦", "8": "⁸⑧", "9": "⁹⑨", "0": "°⁰⓪",
        "-": "–—·", "/": "÷＼", ":": "：", ";": "；", "(": "（【「《", ")": "）】」》",
        "$": "¥€£₩", "&": "§", "@": "＠", "\"": "“”«»", ".": "。…", ",": "，、",
        "?": "？¿", "!": "！¡", "'": "‘’`", "[": "【〔", "]": "】〕", "{": "『｛", "}": "』｝",
        "#": "＃", "%": "‰％", "^": "ˆ＾", "*": "×※", "+": "±", "=": "≠≈", "_": "—＿",
        "\\": "、＼", "|": "｜¦", "~": "～≈", "<": "≤《", ">": "≥》",
        "€": "$£¥", "£": "$€¥", "¥": "$€£", "•": "·○●"
    ]

    /// The letter in both cases, then the marked forms the language writes with.
    public static func letter(_ letter: String, language: KeyboardLanguage, uppercase: Bool) -> [String] {
        guard let key = letter.lowercased().first else { return [] }
        let marks: String?
        switch language {
        case .chinese: marks = pinyin[key]
        case .english: marks = latin[key]
        case .japanese: marks = romaji[key]
        }
        let lower = String(key), upper = lower.uppercased()
        let marked = (marks ?? "").map { mark -> String in
            let text = String(mark)
            // Some have no one-letter capital, such as ß.
            return uppercase && text.uppercased().count == 1 ? text.uppercased() : text
        }
        return (uppercase ? [upper, lower] : [lower, upper]) + marked
    }

    public static func symbol(_ symbol: String) -> [String] {
        [symbol] + (symbols[symbol] ?? "").map(String.init)
    }

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let flicks: [KeyboardLanguage: [String]] = [
        .chinese: ["1234567890", "—、：；（）¥&@", "。，？！‘“～"],
        .english: ["1234567890", "-/:;()$&@", ".,?!'\"~"],
        .japanese: ["1234567890", "ー・：；（）¥&@", "。、？！「」～"]
    ]

    /// What flicking up on a letter key types, shown small on the key.
    public static func flick(_ letter: String, language: KeyboardLanguage) -> String? {
        for (row, keys) in rows.enumerated() {
            guard let column = keys.firstIndex(where: { String($0) == letter }), let marks = flicks[language]?[row] else { continue }
            let offset = keys.distance(from: keys.startIndex, to: column)
            return String(marks[marks.index(marks.startIndex, offsetBy: offset)])
        }
        return nil
    }

    /// The punctuation key's tap is the comma. Holding it offers the rest, full stop first.
    public static func punctuation(language: KeyboardLanguage) -> [String] {
        switch language {
        case .chinese: return ["。", "？", "！", "；", "：", "、", "…"]
        case .english: return [".", "?", "!", ";", ":", "'", "…"]
        case .japanese: return ["。", "？", "！", "・", "：", "…"]
        }
    }
}
